#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# ERC20 Benchmark Campaign
#
# Runs 3 ERC20 benchmarks × 10 runs × N configs.
# Configs run sequentially; cold cache between every run.
#
# Prerequisites:
#   - DBs generated via generate_dbs.sh (symlinks at $DB_BASE/bt-gd{N})
#   - stubs.json in $RESULTS_BASE/bt-gd{N}/
#   - geth built with binary trie support (--override.verkle=0)
#   - execution-specs with benchmark tests
#
# Usage: GROUP_DEPTHS="1 2 4 8" bash run_erc20_benchmarks.sh
#        GROUP_DEPTHS="3 5 6" bash run_erc20_benchmarks.sh
#
# All paths below must be edited for your environment.
# =============================================================================

GETH_BIN="/home/CPerezz/go-ethereum/build/bin/geth"
EXEC_SPECS="/home/CPerezz/execution-specs"
UV="/home/CPerezz/.local/bin/uv"
RESULTS_BASE="/home/CPerezz/results"
DB_BASE="/home/CPerezz/dbs"
SCRIPTS_DIR="/home/CPerezz/bintrie_results"
NUM_RUNS=${NUM_RUNS:-10}

# Anvil's default account (pre-funded via state-actor --inject-accounts).
# IMPORTANT: The private key here MUST correspond to the account passed to
# state-actor's -inject-accounts flag. We use Anvil's default key because
# state-actor pre-funds it during DB generation, and spamoor needs it to
# deploy the ERC20 contract.
SEED_ACCOUNT="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
SEED_KEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

export RPC_ENDPOINT="http://localhost:8545"
export RPC_SEED_KEY="0x${SEED_KEY}"
export RPC_CHAIN_ID="1337"

# Build CONFIGS array from GROUP_DEPTHS env var
read -ra _GD_ARRAY <<< "${GROUP_DEPTHS:-1 2 4 8}"
CONFIGS=()
for gd in "${_GD_ARRAY[@]}"; do
  CONFIGS+=("bt-gd${gd}|${gd}")
done

# ERC20 benchmarks only
declare -a BENCH_NAMES=(
  "erc20_balanceof"
  "erc20_approve"
  "mixed_sload_sstore"
)
declare -a BENCH_TESTS=(
  "tests/benchmark/stateful/bloatnet/test_single_opcode.py::test_sload_empty_erc20_balanceof"
  "tests/benchmark/stateful/bloatnet/test_single_opcode.py::test_sstore_erc20_approve"
  "tests/benchmark/stateful/bloatnet/test_multi_opcode.py::test_mixed_sload_sstore"
)
# No -k filters needed for ERC20 benchmarks
declare -a BENCH_FILTERS=(
  ""
  ""
  ""
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# =============================================================================
# kill_geth: SIGTERM first (flush), SIGKILL fallback, drop caches
# =============================================================================
kill_geth() {
  local pids
  pids=$(pgrep -f "geth.*--dev" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    log "  [geth] Stopping (SIGTERM): $pids"
    echo "$pids" | xargs kill -TERM 2>/dev/null || true
    sleep 8
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then
        log "  [geth] Force killing PID $pid"
        kill -9 "$pid" 2>/dev/null || true
      fi
    done
    sleep 2
  fi
  # Remove stale LOCK files
  for gd in "${_GD_ARRAY[@]}"; do
    rm -f "$DB_BASE/bt-gd${gd}/geth/chaindata/LOCK" 2>/dev/null || true
  done
  # Drop OS page cache for truly cold benchmarks
  sync
  echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true
}

# =============================================================================
# start_geth: cold cache, dev.period=10 for benchmarks
#
# CRITICAL: --bintrie.groupdepth MUST match the group depth used by
# state-actor when the DB was generated. Using a different value will
# corrupt the database irreversibly (the trie layout on disk won't match
# what geth expects).
# =============================================================================
start_geth() {
  local datadir="$1"
  local group_depth="$2"
  local config_id="$3"
  local results_dir="$RESULTS_BASE/$config_id"

  kill_geth

  # Import seed key (idempotent)
  echo "$SEED_KEY" > /tmp/seed_key.hex
  echo "" | "$GETH_BIN" --datadir "$datadir" account import --password /dev/stdin /tmp/seed_key.hex 2>/dev/null || true
  rm -f /tmp/seed_key.hex

  log "  [geth] Starting ($config_id, gd=$group_depth, cache=0, dev.period=10)..."
  "$GETH_BIN" \
    --datadir "$datadir" \
    --dev --dev.period 10 --dev.gaslimit 110000000 \
    --miner.etherbase "$SEED_ACCOUNT" \
    --cache 0 \
    --debug.logslowblock=0 \
    --http --http.addr 0.0.0.0 --http.port 8545 \
    --http.api eth,net,web3,debug,miner,txpool,admin,personal \
    --ws --ws.addr 0.0.0.0 --ws.port 8546 \
    --ws.api eth,net,web3,debug,miner,txpool \
    --nodiscover --maxpeers 0 \
    --rpc.allow-unprotected-txs --rpc.txfeecap 0 \
    --verbosity 3 \
    --override.verkle=0 \
    --bintrie.groupdepth "$group_depth" \
    > "$results_dir/geth_current.log" 2>&1 &

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

  # Set gas limit to 100M
  curl -s -X POST http://localhost:8545 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"miner_setGasLimit","params":["0x5F5E100"],"id":1}' \
    > /dev/null

  # Verify gas limit
  local gas_limit
  gas_limit=$(curl -s -X POST http://localhost:8545 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
    | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result']['gasLimit'],16))")
  log "  [geth] Gas limit: $gas_limit"

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
log "║  ERC20 Benchmark Campaign: GD-${_GD_ARRAY[*]}"
log "║  3 benchmarks × $NUM_RUNS runs × ${#CONFIGS[@]} configs = $((3 * NUM_RUNS * ${#CONFIGS[@]})) total runs"
log "╚══════════════════════════════════════════════════════════════════╝"
log ""
log "  Preflight checks..."

ALL_OK=true
for config_line in "${CONFIGS[@]}"; do
  IFS='|' read -r CONFIG_ID GROUP_DEPTH <<< "$config_line"
  DATADIR="$DB_BASE/$CONFIG_ID"
  STUBS_FILE="$RESULTS_BASE/$CONFIG_ID/stubs.json"

  # Check DB exists
  if [ ! -d "$DATADIR/geth/chaindata" ]; then
    log "  FAIL: DB not found at $DATADIR/geth/chaindata"
    ALL_OK=false
    continue
  fi
  DB_SIZE=$(du -sh "$DATADIR/geth/chaindata" 2>/dev/null | cut -f1 || echo "N/A")
  log "  $CONFIG_ID: DB=$DB_SIZE"

  # Check stubs.json exists
  if [ ! -f "$STUBS_FILE" ]; then
    log "  FAIL: stubs.json not found at $STUBS_FILE"
    ALL_OK=false
    continue
  fi
  CONTRACT=$(python3 -c "import json; d=json.load(open('$STUBS_FILE')); print(list(d.values())[0])")
  log "  $CONFIG_ID: contract=$CONTRACT"
done

# Check binaries
for bin in "$GETH_BIN" "$UV"; do
  if [ ! -x "$bin" ]; then
    log "  FAIL: $bin not found or not executable"
    ALL_OK=false
  fi
done

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
for config_line in "${CONFIGS[@]}"; do
  config_num=$((config_num + 1))
  IFS='|' read -r CONFIG_ID GROUP_DEPTH <<< "$config_line"

  DATADIR="$DB_BASE/$CONFIG_ID"
  RESULTS_DIR="$RESULTS_BASE/$CONFIG_ID"
  STUBS_FILE="$RESULTS_DIR/stubs.json"

  log ""
  log "╔══════════════════════════════════════════════════════════════════╗"
  log "║  CONFIG $config_num/${#CONFIGS[@]}: $CONFIG_ID (gd=$GROUP_DEPTH)"
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

  # Run benchmarks
  for bench_idx in "${!BENCH_NAMES[@]}"; do
    bench_name="${BENCH_NAMES[$bench_idx]}"
    bench_test="${BENCH_TESTS[$bench_idx]}"
    bench_filter="${BENCH_FILTERS[$bench_idx]}"

    log ""
    log "  ── BENCHMARK: $bench_name ──"
    log "     Test: $bench_test"

    for run in $(seq 1 "$NUM_RUNS"); do
      log ""
      log "  --- $bench_name: Run $run/$NUM_RUNS ---"

      # 1. Restart geth (cold cache, dev.period=10)
      start_geth "$DATADIR" "$GROUP_DEPTH" "$CONFIG_ID"

      # 2. Run benchmark
      log "  [bench] Running..."
      cd "$EXEC_SPECS"

      set +e
      if [ -n "$bench_filter" ]; then
        "$UV" run execute remote \
          --fork Osaka \
          --tx-wait-timeout 600 \
          --gas-benchmark-values 100 \
          --address-stubs "$EXEC_SPECS/tests/benchmark/stateful/bloatnet/stubs_bloatnet.json" \
          -m stateful \
          "$bench_test" \
          -k "$bench_filter" \
          -v > "$RESULTS_DIR/${bench_name}_run${run}_test.log" 2>&1
        test_exit=$?
      else
        "$UV" run execute remote \
          --fork Osaka \
          --tx-wait-timeout 600 \
          --gas-benchmark-values 100 \
          --address-stubs "$EXEC_SPECS/tests/benchmark/stateful/bloatnet/stubs_bloatnet.json" \
          -m stateful \
          "$bench_test" \
          -v > "$RESULTS_DIR/${bench_name}_run${run}_test.log" 2>&1
        test_exit=$?
      fi
      set -e

      # 3. Save geth log
      cp "$RESULTS_DIR/geth_current.log" "$RESULTS_DIR/${bench_name}_run${run}_geth.log"

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
  log "  [csv] Extracting CSVs for $CONFIG_ID..."
  kill_geth
  python3 "$SCRIPTS_DIR/extract_csv.py" "$RESULTS_DIR" \
    --config "$CONFIG_ID" \
    --trie-type "bintrie" \
    --group-depth "$GROUP_DEPTH" \
    --pebble-block-size-kb 4

  log "  [done] $CONFIG_ID benchmarks complete"
done

# =============================================================================
# Stop geth
# =============================================================================
log ""
log "Stopping geth..."
kill_geth

# =============================================================================
# Consolidate all CSVs across all configs found in RESULTS_BASE
# =============================================================================
log ""
log "╔══════════════════════════════════════════════════════════════════╗"
log "║  Consolidating CSVs (all configs)                               ║"
log "╚══════════════════════════════════════════════════════════════════╝"

python3 "$SCRIPTS_DIR/extract_csv.py" \
  --consolidate \
  --consolidate-dir "$RESULTS_BASE" \
  --output-dir "$RESULTS_BASE"

# =============================================================================
# Final summary
# =============================================================================
log ""
log "╔══════════════════════════════════════════════════════════════════╗"
log "║  Campaign Complete                                              ║"
log "╚══════════════════════════════════════════════════════════════════╝"
log ""
log "  Per-config results:"
for config_line in "${CONFIGS[@]}"; do
  IFS='|' read -r CONFIG_ID _ <<< "$config_line"
  csv_file="$RESULTS_BASE/$CONFIG_ID/csv/${CONFIG_ID}_all_benchmarks.csv"
  if [ -f "$csv_file" ]; then
    rows=$(wc -l < "$csv_file")
    log "    $CONFIG_ID: $rows lines in CSV"
  else
    log "    $CONFIG_ID: CSV MISSING"
  fi
done

total_csv="$RESULTS_BASE/page_size_benchmarks_consolidated.csv"
if [ -f "$total_csv" ]; then
  log "  Consolidated: $(wc -l < "$total_csv") lines"
fi

# Check for errors in geth logs
ERRORS=0
for config_line in "${CONFIGS[@]}"; do
  IFS='|' read -r CONFIG_ID _ <<< "$config_line"
  errs=$(grep -c 'missing trie\|BAD BLOCK\|exceeds block gas' "$RESULTS_BASE/$CONFIG_ID"/*_geth.log 2>/dev/null || echo "0")
  ERRORS=$((ERRORS + errs))
done
log "  Error lines in geth logs: $ERRORS"

log ""
log "  $(date '+%Y-%m-%d %H:%M:%S') - All done!"
log "  Consolidated CSV: $RESULTS_BASE/page_size_benchmarks_consolidated.csv"
