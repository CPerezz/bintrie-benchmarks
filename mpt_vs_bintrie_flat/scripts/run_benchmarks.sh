#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# MPT vs Binary Trie — ERC20 Benchmark Campaign
#
# Runs 3 ERC20 benchmarks × 10 runs × 2 configs (MPT, BT-GD5).
# Configs run sequentially; cold cache between every run.
#
# Benchmark order per config: balanceof → mixed → approve
# (read-only first, writes last to minimize mutation impact)
#
# Prerequisites:
#   - DBs generated via generate_db.sh
#   - stubs.json in results/{config}/
#   - geth-mpt and geth-bintrie binaries in bin/
#   - execution-specs with benchmark tests
#
# Usage: bash run_benchmarks.sh
#        CONFIGS="mpt" bash run_benchmarks.sh     # single config
#        CONFIGS="bt-gd5" bash run_benchmarks.sh   # single config
# =============================================================================

CAMPAIGN_DIR="/home/CPerezz/bintrie-benchmarks/mpt-vs-bintrie"

GETH_BINTRIE="${CAMPAIGN_DIR}/bin/geth-bintrie"
GETH_MPT="${CAMPAIGN_DIR}/bin/geth-mpt"
EXEC_SPECS="/home/CPerezz/execution-specs"
UV="/home/CPerezz/.local/bin/uv"
RESULTS_BASE="${CAMPAIGN_DIR}/results"
DB_BASE="${CAMPAIGN_DIR}/dbs"
LOGS_BASE="${CAMPAIGN_DIR}/logs"
SCRIPTS_DIR="${CAMPAIGN_DIR}/scripts"
NUM_RUNS=${NUM_RUNS:-10}  # Override with NUM_RUNS=N env var

SEED_ACCOUNT="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
SEED_KEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

export RPC_ENDPOINT="http://localhost:8545"
export RPC_SEED_KEY="0x${SEED_KEY}"
export RPC_CHAIN_ID="1337"

# Configurable via env var
read -ra CONFIGS <<< "${CONFIGS:-bt-gd5 mpt}"

# Benchmark order: balanceof → mixed → approve (read-only first, writes last)
declare -a BENCH_NAMES=(
  "erc20_balanceof"
  "mixed_sload_sstore"
  "erc20_approve"
)
declare -a BENCH_TESTS=(
  "tests/benchmark/stateful/bloatnet/test_single_opcode.py::test_sload_empty_erc20_balanceof"
  "tests/benchmark/stateful/bloatnet/test_multi_opcode.py::test_mixed_sload_sstore"
  "tests/benchmark/stateful/bloatnet/test_single_opcode.py::test_sstore_erc20_approve"
)
declare -a BENCH_FILTERS=(
  "num_contracts_1 and not num_contracts_10 and not num_contracts_100"
  "50-50 and num_contracts_1 and not num_contracts_10 and not num_contracts_100"
  "num_contracts_1 and not num_contracts_10 and not num_contracts_100"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# =============================================================================
# get_geth_bin: return the correct geth binary for a config
# =============================================================================
get_geth_bin() {
  local config="$1"
  if [ "$config" = "mpt" ]; then
    echo "$GETH_MPT"
  else
    echo "$GETH_BINTRIE"
  fi
}

# =============================================================================
# kill_geth: SIGTERM first (flush), SIGKILL fallback, drop caches
# =============================================================================
kill_geth() {
  local pids
  pids=$(pgrep -f "geth.*--dev" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    log "  [geth] Stopping (SIGTERM): $pids"
    echo "$pids" | xargs kill -TERM 2>/dev/null || true
    # Wait up to 60s for graceful shutdown (large DBs need time to flush)
    for i in $(seq 1 60); do
      local still_running=false
      for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
          still_running=true
          break
        fi
      done
      if [ "$still_running" = false ]; then
        log "  [geth] Stopped gracefully after ${i}s"
        break
      fi
      sleep 1
      if [ "$i" -eq 60 ]; then
        for pid in $pids; do
          if kill -0 "$pid" 2>/dev/null; then
            log "  [geth] Force killing PID $pid (60s timeout)"
            kill -9 "$pid" 2>/dev/null || true
          fi
        done
        sleep 2
      fi
    done
  fi
  # Remove stale LOCK files
  for config in "${CONFIGS[@]}"; do
    rm -f "$DB_BASE/$config/geth/chaindata/LOCK" 2>/dev/null || true
  done
  # Drop OS page cache for truly cold benchmarks
  sync
  sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
}

# =============================================================================
# start_geth: cold cache, dev.period=10 for benchmarks
# =============================================================================
start_geth() {
  local datadir="$1"
  local config_id="$2"
  local results_dir="$RESULTS_BASE/$config_id"
  local geth_bin
  geth_bin=$(get_geth_bin "$config_id")

  kill_geth

  # Reset SnapshotRoot + SnapshotGenerator to the disk layer root before each
  # geth start. With cache=0 (benchmark config), pathdb never caps diff layers
  # to disk, so the disk layer root stays at the genesis root forever. On
  # graceful shutdown geth persists the HEAD root as SnapshotRoot, causing a
  # mismatch on next start and triggering 24h+ snapshot regeneration. fix_snap
  # resets SnapshotRoot back to the disk layer root so the snapshot stays
  # consistent across restarts.
  if [ "$config_id" != "mpt" ]; then
    local fix_snap_bin="${CAMPAIGN_DIR}/bin/fix_snap"
    local genesis_root="0xcc802d03e8fdd13339d515f801b3f88b23cd7782aa59ac62feab348d9c713c5f"
    if [ -x "$fix_snap_bin" ]; then
      "$fix_snap_bin" "$datadir/geth/chaindata" "$genesis_root" 2>/dev/null || true
    fi
  fi

  # Import seed key (idempotent)
  echo "$SEED_KEY" > /tmp/seed_key.hex
  echo "" | "$geth_bin" --datadir "$datadir" account import --password /dev/stdin /tmp/seed_key.hex 2>/dev/null || true
  rm -f /tmp/seed_key.hex

  log "  [geth] Starting ($config_id, cache=0, dev.period=10)..."

  local geth_args=(
    --datadir "$datadir"
    --dev --dev.period 10 --dev.gaslimit 110000000
    --miner.etherbase "$SEED_ACCOUNT"
    --cache 0
    --debug.logslowblock=0
    --http --http.addr 0.0.0.0 --http.port 8545
    --http.api eth,net,web3,debug,miner,txpool,admin,personal
    --ws --ws.addr 0.0.0.0 --ws.port 8546
    --ws.api eth,net,web3,debug,miner,txpool
    --nodiscover --maxpeers 0
    --rpc.allow-unprotected-txs --rpc.txfeecap 0 --rpc.gascap 0
    --verbosity 3
  )

  # Add config-specific flags
  if [ "$config_id" != "mpt" ]; then
    geth_args+=(--override.verkle=0 --bintrie.groupdepth 5)
  else
    geth_args+=(--override.osaka=4294967295)
  fi

  "$geth_bin" "${geth_args[@]}" > "$results_dir/geth_current.log" 2>&1 &

  log "  [geth] Waiting for RPC..."
  for i in $(seq 1 120); do
    if curl -s -X POST http://localhost:8545 \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
      2>/dev/null | grep -q "result"; then
      log "  [geth] RPC ready after ${i}s"
      break
    fi
    sleep 1
    if [ "$i" -eq 120 ]; then
      log "  [geth] ERROR: RPC not ready after 120s"
      tail -20 "$results_dir/geth_current.log"
      return 1
    fi
  done

  # Set gas limit target to 110M
  curl -s -X POST http://localhost:8545 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"miner_setGasLimit","params":["0x68E7780"],"id":1}' \
    > /dev/null

  # Wait for gas limit to reach at least 105M (needed for 100M benchmark txs)
  # Gas limit adjusts ~1/1024 per block; with dev.period=10 this can take a few minutes
  local gas_limit
  local min_gas=101000000
  log "  [geth] Waiting for gas limit to reach ${min_gas}..."
  for attempt in $(seq 1 600); do
    gas_limit=$(curl -s -X POST http://localhost:8545 \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
      | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result']['gasLimit'],16))")
    if [ "$gas_limit" -ge "$min_gas" ] 2>/dev/null; then
      log "  [geth] Gas limit reached: $gas_limit (after ${attempt}s)"
      break
    fi
    if [ "$((attempt % 30))" -eq 0 ]; then
      log "  [geth] Gas limit: $gas_limit (waiting for $min_gas)..."
    fi
    sleep 1
    if [ "$attempt" -eq 600 ]; then
      log "  [geth] WARNING: Gas limit only $gas_limit after 600s, proceeding anyway"
    fi
  done

  # Verify seed balance
  local seed_balance
  seed_balance=$(curl -s -X POST http://localhost:8545 \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$SEED_ACCOUNT\",\"latest\"],\"id\":1}" \
    | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))")
  log "  [geth] Seed balance: $(python3 -c "print($seed_balance / 1e18)") ETH"
}

# =============================================================================
# Preflight checks
# =============================================================================
log "╔══════════════════════════════════════════════════════════════════╗"
log "║  MPT vs Binary Trie — Benchmark Campaign"
log "║  Configs: ${CONFIGS[*]}"
log "║  3 benchmarks × $NUM_RUNS runs × ${#CONFIGS[@]} configs = $((3 * NUM_RUNS * ${#CONFIGS[@]})) total runs"
log "╚══════════════════════════════════════════════════════════════════╝"
log ""
log "  Preflight checks..."

ALL_OK=true
for config in "${CONFIGS[@]}"; do
  DATADIR="$DB_BASE/$config"
  STUBS_FILE="$RESULTS_BASE/$config/stubs.json"
  geth_bin=$(get_geth_bin "$config")

  # Check geth binary
  if [ ! -x "$geth_bin" ]; then
    log "  FAIL: $geth_bin not found or not executable"
    ALL_OK=false
    continue
  fi

  # Check DB exists
  if [ ! -d "$DATADIR/geth/chaindata" ]; then
    log "  FAIL: DB not found at $DATADIR/geth/chaindata"
    ALL_OK=false
    continue
  fi
  DB_SIZE=$(du -sh "$DATADIR/geth/chaindata" 2>/dev/null | cut -f1 || echo "N/A")
  log "  $config: DB=$DB_SIZE"

  # Check stubs.json exists
  if [ ! -f "$STUBS_FILE" ]; then
    log "  FAIL: stubs.json not found at $STUBS_FILE"
    ALL_OK=false
    continue
  fi
  CONTRACT=$(python3 -c "import json; d=json.load(open('$STUBS_FILE')); print(list(d.values())[0])")
  log "  $config: contract=$CONTRACT"
done

# Check uv
if [ ! -x "$UV" ]; then
  log "  FAIL: $UV not found or not executable"
  ALL_OK=false
fi

# Check execution-specs
if [ ! -d "$EXEC_SPECS/tests/benchmark/stateful/bloatnet" ]; then
  log "  FAIL: execution-specs benchmark dir not found"
  ALL_OK=false
fi

if [ "$ALL_OK" = false ]; then
  log ""
  log "  ERROR: Preflight checks failed. Aborting."
  exit 1
fi

log "  All preflight checks passed."

# Kill any running geth
kill_geth

# =============================================================================
# Benchmark Campaign
# =============================================================================
config_num=0
for config in "${CONFIGS[@]}"; do
  config_num=$((config_num + 1))

  DATADIR="$DB_BASE/$config"
  RESULTS_DIR="$RESULTS_BASE/$config"
  STUBS_FILE="$RESULTS_DIR/stubs.json"

  # Bintrie chains have Osaka active at genesis (EIP-7825 tx gas cap).
  # Use --fork Osaka so execution-specs splits txs to respect 16M cap.
  if [ "$config" != "mpt" ]; then
    BENCH_FORK="Osaka"
  else
    BENCH_FORK="Prague"
  fi

  log ""
  log "╔══════════════════════════════════════════════════════════════════╗"
  log "║  CONFIG $config_num/${#CONFIGS[@]}: $config"
  log "╚══════════════════════════════════════════════════════════════════╝"

  mkdir -p "$RESULTS_DIR"

  # Copy stubs to execution-specs
  cp "$STUBS_FILE" "$EXEC_SPECS/tests/benchmark/stateful/bloatnet/stubs_bloatnet.json"
  log "  Stubs copied to execution-specs"

  # Clear old benchmark logs for this config
  log "  Clearing old benchmark logs..."
  for bench_name in "${BENCH_NAMES[@]}"; do
    for run in $(seq 1 "$NUM_RUNS"); do
      rm -f "$RESULTS_DIR/${bench_name}_run${run}_geth.log"
      rm -f "$RESULTS_DIR/${bench_name}_run${run}_test.log"
    done
  done
  rm -rf "$RESULTS_DIR/csv"

  # Run benchmarks (order: balanceof → mixed → approve)
  for bench_idx in "${!BENCH_NAMES[@]}"; do
    bench_name="${BENCH_NAMES[$bench_idx]}"
    bench_test="${BENCH_TESTS[$bench_idx]}"
    bench_filter="${BENCH_FILTERS[$bench_idx]}"

    log ""
    log "  ── BENCHMARK: $bench_name ──"
    log "     Test: $bench_test"
    log "     Filter: $bench_filter"

    for run in $(seq 1 "$NUM_RUNS"); do
      log ""
      log "  --- $bench_name: Run $run/$NUM_RUNS ---"

      # 1. Restart geth (cold cache, dev.period=10)
      start_geth "$DATADIR" "$config"

      # 2. Run benchmark
      log "  [bench] Running..."
      cd "$EXEC_SPECS"

      set +e
      if [ -n "$bench_filter" ]; then
        "$UV" run execute remote \
          --fork "$BENCH_FORK" \
          --gas-benchmark-values 100 \
          --address-stubs "$EXEC_SPECS/tests/benchmark/stateful/bloatnet/stubs_bloatnet.json" \
          --rpc-endpoint "$RPC_ENDPOINT" \
          --rpc-seed-key "$RPC_SEED_KEY" \
          --chain-id "$RPC_CHAIN_ID" \
          -m stateful \
          "$bench_test" \
          -k "$bench_filter" \
          -v > "$RESULTS_DIR/${bench_name}_run${run}_test.log" 2>&1
        test_exit=$?
      else
        "$UV" run execute remote \
          --fork "$BENCH_FORK" \
          --gas-benchmark-values 100 \
          --address-stubs "$EXEC_SPECS/tests/benchmark/stateful/bloatnet/stubs_bloatnet.json" \
          --rpc-endpoint "$RPC_ENDPOINT" \
          --rpc-seed-key "$RPC_SEED_KEY" \
          --chain-id "$RPC_CHAIN_ID" \
          -m stateful \
          "$bench_test" \
          -v > "$RESULTS_DIR/${bench_name}_run${run}_test.log" 2>&1
        test_exit=$?
      fi
      set -e

      # 3. Save geth log (also copy to logs dir)
      cp "$RESULTS_DIR/geth_current.log" "$RESULTS_DIR/${bench_name}_run${run}_geth.log"
      cp "$RESULTS_DIR/${bench_name}_run${run}_geth.log" \
         "$LOGS_BASE/$config/${bench_name}_run${run}_geth.log" 2>/dev/null || true

      # 4. Report results
      passed=$(grep -c " PASSED" "$RESULTS_DIR/${bench_name}_run${run}_test.log" 2>/dev/null || echo "0")
      failed=$(grep -c " FAILED" "$RESULTS_DIR/${bench_name}_run${run}_test.log" 2>/dev/null || echo "0")
      errors=$(grep -c " ERROR" "$RESULTS_DIR/${bench_name}_run${run}_test.log" 2>/dev/null || echo "0")
      log "  [bench] Exit=$test_exit Passed=$passed Failed=$failed Errors=$errors"

      # 5. Quick cache + performance summary
      grep '"Slow block"' "$RESULTS_DIR/${bench_name}_run${run}_geth.log" 2>/dev/null \
        | python3 -c "
import sys, json
blocks = []
for line in sys.stdin:
    try:
        start = line.index('{')
        data = json.loads(line[start:])
        if data.get('msg') != 'Slow block':
            continue
        gas = data['block']['gas_used']
        if gas > 500000:
            blocks.append(data)
    except Exception:
        continue
if not blocks:
    print('    No benchmark blocks found')
    sys.exit(0)
ah = sum(b['cache']['account']['hits'] for b in blocks)
am = sum(b['cache']['account']['misses'] for b in blocks)
sh = sum(b['cache']['storage']['hits'] for b in blocks)
sm = sum(b['cache']['storage']['misses'] for b in blocks)
ar = 100*ah/(ah+am) if (ah+am)>0 else 0
sr = 100*sh/(sh+sm) if (sh+sm)>0 else 0
avg_ms = sum(b['timing']['total_ms'] for b in blocks)/len(blocks)
avg_mgas = sum(b['throughput']['mgas_per_sec'] for b in blocks)/len(blocks)
print(f'    Blocks: {len(blocks)} | Acct: {ar:.1f}% | Slot: {sr:.1f}% | Avg: {avg_ms:.1f}ms {avg_mgas:.2f}Mgas/s')
" 2>/dev/null || echo "    (parse error)"

    done
  done

  # Extract CSVs for this config
  log ""
  log "  [csv] Extracting CSVs for $config..."
  kill_geth

  # Determine trie type for CSV extraction
  if [ "$config" = "mpt" ]; then
    TRIE_TYPE="mpt"
    GROUP_DEPTH=0
  else
    TRIE_TYPE="bintrie"
    GROUP_DEPTH=5
  fi

  python3 "$SCRIPTS_DIR/extract_csv.py" "$RESULTS_DIR" \
    --config "$config" \
    --trie-type "$TRIE_TYPE" \
    --group-depth "$GROUP_DEPTH" \
    --pebble-block-size-kb 4

  log "  [done] $config benchmarks complete"
done

# =============================================================================
# Stop geth
# =============================================================================
log ""
log "Stopping geth..."
kill_geth

# =============================================================================
# Consolidate all CSVs
# =============================================================================
log ""
log "╔══════════════════════════════════════════════════════════════════╗"
log "║  Consolidating CSVs (all configs)                               ║"
log "╚══════════════════════════════════════════════════════════════════╝"

python3 "$SCRIPTS_DIR/extract_csv.py" \
  --consolidate \
  --consolidate-dir "$RESULTS_BASE" \
  --output-dir "$CAMPAIGN_DIR/data"

# Copy per-config CSVs to data/
for config in "${CONFIGS[@]}"; do
  cp "$RESULTS_BASE/$config/csv/"*.csv "$CAMPAIGN_DIR/data/" 2>/dev/null || true
done

# =============================================================================
# Final summary
# =============================================================================
log ""
log "╔══════════════════════════════════════════════════════════════════╗"
log "║  Campaign Complete                                              ║"
log "╚══════════════════════════════════════════════════════════════════╝"
log ""
log "  Per-config results:"
for config in "${CONFIGS[@]}"; do
  csv_file="$RESULTS_BASE/$config/csv/${config}_all_benchmarks.csv"
  if [ -f "$csv_file" ]; then
    rows=$(wc -l < "$csv_file")
    log "    $config: $rows lines in CSV"
  else
    log "    $config: CSV MISSING"
  fi
done

total_csv="$CAMPAIGN_DIR/data/mpt_vs_bintrie_consolidated.csv"
if [ -f "$total_csv" ]; then
  log "  Consolidated: $(wc -l < "$total_csv") lines"
fi

# Check for errors in geth logs
ERRORS=0
for config in "${CONFIGS[@]}"; do
  errs=$(grep -c 'missing trie\|BAD BLOCK\|exceeds block gas' "$RESULTS_BASE/$config"/*_geth.log 2>/dev/null || echo "0")
  ERRORS=$((ERRORS + errs))
done
log "  Error lines in geth logs: $ERRORS"

log ""
log "  $(date '+%Y-%m-%d %H:%M:%S') - All done!"
log "  Consolidated CSV: $total_csv"
