#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Generate MPT + Binary Trie 1TB DBs + Deploy 5GB ERC20 on each
#
# Phase 1: Generate DBs sequentially (state-actor, --seed 25519, 1TB each)
# Phase 2: For each DB: start geth → spamoor erc20_bloater → stubs.json → stop
#
# Usage: bash generate_db.sh
#        CONFIGS="bt-gd5" bash generate_db.sh   # single config
#        CONFIGS="mpt" bash generate_db.sh       # single config
#
# NOTE: Uses per-config state-actor binaries (state-actor-mpt / state-actor-bintrie)
# linked to different go-ethereum branches. Run from terminal, not sandbox.
# =============================================================================

CAMPAIGN_DIR="/home/CPerezz/bintrie-benchmarks/mpt-vs-bintrie"

STATE_ACTOR_BINTRIE="${CAMPAIGN_DIR}/bin/state-actor-bintrie"
STATE_ACTOR_MPT="${CAMPAIGN_DIR}/bin/state-actor-mpt"
GETH_BINTRIE="${CAMPAIGN_DIR}/bin/geth-bintrie"
GETH_MPT="${CAMPAIGN_DIR}/bin/geth-mpt"
SPAMOOR_BIN="/home/CPerezz/spamoor/bin/spamoor"
GENESIS="/home/CPerezz/state-actor/genesis.json"

DB_BASE="${CAMPAIGN_DIR}/dbs"
RESULTS_BASE="${CAMPAIGN_DIR}/results"
LOGS_BASE="${CAMPAIGN_DIR}/logs"

# Anvil's default account (pre-funded via state-actor --inject-accounts).
SEED_ACCOUNT="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
SEED_KEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
PRIVKEY="0x${SEED_KEY}"

TARGET_SIZE="1200GB"
# 100K contracts keeps per-contract slot counts manageable (~45K-458K each)
# instead of the default 100 contracts which auto-scales to ~45M-458M slots
# per contract and OOMs during generation.
NUM_CONTRACTS=100000
STATE_ACTOR_SEED=25519
SPAMOOR_SEED="mpt-vs-bt"
SPAMOOR_TARGET_GB="5"

# Configurable via env var
read -ra CONFIGS <<< "${CONFIGS:-bt-gd5 mpt}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# =============================================================================
# get_geth_bin / get_state_actor_bin: return the correct binary for a config
# =============================================================================
get_geth_bin() {
  local config="$1"
  if [ "$config" = "mpt" ]; then
    echo "$GETH_MPT"
  else
    echo "$GETH_BINTRIE"
  fi
}

get_state_actor_bin() {
  local config="$1"
  if [ "$config" = "mpt" ]; then
    echo "$STATE_ACTOR_MPT"
  else
    echo "$STATE_ACTOR_BINTRIE"
  fi
}

# =============================================================================
# kill_geth: SIGTERM first (flush), SIGKILL fallback
# =============================================================================
kill_geth() {
  local pids
  pids=$(pgrep -f "geth.*--dev" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    log "  Killing geth (SIGTERM): $pids"
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
        log "  Geth stopped gracefully after ${i}s"
        break
      fi
      sleep 1
      if [ "$i" -eq 60 ]; then
        for pid in $pids; do
          if kill -0 "$pid" 2>/dev/null; then
            log "  Force killing geth PID $pid (60s timeout)"
            kill -9 "$pid" 2>/dev/null || true
          fi
        done
        sleep 2
      fi
    done
  fi
  # Drop OS page cache
  sync
  sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
}

# =============================================================================
# start_geth: start geth dev node with cache for deployment
# =============================================================================
start_geth() {
  local datadir="$1"
  local config_id="$2"
  local log_file="$3"
  local geth_bin
  geth_bin=$(get_geth_bin "$config_id")

  kill_geth

  # Remove stale LOCK files
  rm -f "$datadir/geth/chaindata/LOCK" 2>/dev/null || true

  # Import seed key (idempotent)
  echo "$SEED_KEY" > /tmp/seed_key.hex
  echo "" | "$geth_bin" --datadir "$datadir" account import --password /dev/stdin /tmp/seed_key.hex 2>/dev/null || true
  rm -f /tmp/seed_key.hex

  log "  Starting geth ($config_id, cache=4096 for deployment)..."

  local geth_args=(
    --datadir "$datadir"
    --dev --dev.period 1 --dev.gaslimit 100000000
    --miner.etherbase "$SEED_ACCOUNT"
    --cache 4096
    --debug.logslowblock=0
    --http --http.addr 0.0.0.0 --http.port 8545
    --http.api eth,net,web3,debug,miner,txpool,admin,personal
    --ws --ws.addr 0.0.0.0 --ws.port 8546
    --ws.api eth,net,web3,debug,miner,txpool
    --nodiscover --maxpeers 0
    --rpc.allow-unprotected-txs --rpc.txfeecap 0
    --verbosity 3
  )

  # Add bintrie-specific flags
  if [ "$config_id" != "mpt" ]; then
    geth_args+=(--override.verkle=0 --bintrie.groupdepth 5)
  fi

  "$geth_bin" "${geth_args[@]}" > "$log_file" 2>&1 &

  log "  Waiting for RPC..."
  for i in $(seq 1 120); do
    if curl -s http://localhost:8545 -H "Content-Type: application/json" \
       -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' 2>/dev/null | grep -q "result"; then
      log "  RPC ready after ${i}s"
      return 0
    fi
    sleep 1
    if [ "$i" -eq 120 ]; then
      log "  ERROR: RPC not ready after 120s"
      tail -20 "$log_file"
      return 1
    fi
  done
}

# =============================================================================
# Preflight checks
# =============================================================================
log "╔══════════════════════════════════════════════════════════════╗"
log "║  MPT vs Binary Trie — DB Generation                         ║"
log "║  Configs: ${CONFIGS[*]}"
log "╚══════════════════════════════════════════════════════════════╝"

for bin in "$STATE_ACTOR_MPT" "$STATE_ACTOR_BINTRIE" "$SPAMOOR_BIN"; do
  if [ ! -x "$bin" ]; then
    log "ERROR: $bin not found or not executable"
    exit 1
  fi
done

for config in "${CONFIGS[@]}"; do
  geth_bin=$(get_geth_bin "$config")
  if [ ! -x "$geth_bin" ]; then
    log "ERROR: $geth_bin not found or not executable"
    log "  Build geth binaries first (see README.md)"
    exit 1
  fi
done

if [ ! -f "$GENESIS" ]; then
  log "ERROR: genesis.json not found at $GENESIS"
  exit 1
fi

AVAIL_TB=$(df --output=avail -BG /home/CPerezz | tail -1 | tr -d ' G')
NEEDED_GB=$((1024 * ${#CONFIGS[@]}))
log "  Disk available: ${AVAIL_TB}G | Needed (est): ${NEEDED_GB}G"
if [ "$AVAIL_TB" -lt "$NEEDED_GB" ]; then
  log "ERROR: Not enough disk space"
  exit 1
fi
log "  Disk check: OK"

kill_geth
log "  All preflight checks passed"

# =============================================================================
# PHASE 1: Generate DBs sequentially
# =============================================================================
log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║  Phase 1: Generate DBs sequentially (~22h each)              ║"
log "╚══════════════════════════════════════════════════════════════╝"

for config in "${CONFIGS[@]}"; do
  db_path="${DB_BASE}/${config}"
  gen_log="${LOGS_BASE}/${config}/state_actor_gen.log"

  mkdir -p "${LOGS_BASE}/${config}"

  log ""
  log "================================================================"
  log "  Generating: $config"
  log "  DB path:    $db_path"
  log "  Started:    $(date '+%Y-%m-%d %H:%M:%S')"
  log "================================================================"

  # Skip if DB already exists and looks complete
  if [ -f "$gen_log" ] && grep -q "Generation Complete" "$gen_log" 2>/dev/null; then
    log "  DB already generated (found completion marker in log). Skipping."
    continue
  fi

  # Clean up partial previous run
  if [ -d "$db_path/geth/chaindata" ] && [ "$(du -sm "$db_path/geth/chaindata" 2>/dev/null | cut -f1)" -gt 100 ]; then
    log "  WARNING: $db_path/geth/chaindata exists ($(du -sh "$db_path/geth/chaindata" | cut -f1)). Remove manually to regenerate."
    continue
  fi

  mkdir -p "$db_path"

  sa_bin=$(get_state_actor_bin "$config")

  # Build state-actor args
  sa_args=(
    -db "$db_path/geth/chaindata"
    -genesis "$GENESIS"
    -target-size "$TARGET_SIZE"
    -contracts "$NUM_CONTRACTS"
    -inject-accounts "$SEED_ACCOUNT"
    -seed "$STATE_ACTOR_SEED"
    -benchmark
    -verbose
  )

  # Add bintrie-specific flags
  if [ "$config" != "mpt" ]; then
    sa_args+=(-binary-trie -group-depth 5)
  fi

  log "  Using state-actor: $sa_bin"
  "$sa_bin" "${sa_args[@]}" 2>&1 | tee "$gen_log"

  DB_SIZE=$(du -sh "$db_path/geth/chaindata" 2>/dev/null | cut -f1 || echo "N/A")
  log "  $config generated: $DB_SIZE"
done

log ""
log "  All DBs generated."

# =============================================================================
# PHASE 2: Deploy 5GB ERC20 on each DB via spamoor
# =============================================================================
log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║  Phase 2: Deploy 5GB ERC20 on each config                   ║"
log "╚══════════════════════════════════════════════════════════════╝"

for config in "${CONFIGS[@]}"; do
  db_path="${DB_BASE}/${config}"
  results_dir="${RESULTS_BASE}/${config}"
  spamoor_log="${results_dir}/spamoor_5gb.log"
  stubs_file="${results_dir}/stubs.json"

  log ""
  log "================================================================"
  log "  Deploying 5GB ERC20 on $config"
  log "================================================================"

  mkdir -p "$results_dir"

  # Skip if stubs.json already exists
  if [ -f "$stubs_file" ]; then
    log "  stubs.json already exists at $stubs_file. Skipping."
    cat "$stubs_file"
    continue
  fi

  # Start geth with cache=4096 for faster deployment
  start_geth "$db_path" "$config" "$results_dir/geth_deploy.log"

  # Set gas limit
  curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"miner_setGasLimit","params":["0x5F5E100"],"id":1}' > /dev/null

  # Verify seed account has funds — for MPT, fund from dev account if needed
  BALANCE=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$SEED_ACCOUNT\",\"latest\"],\"id\":1}" \
    | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "0")
  log "  Seed balance: $(python3 -c "print($BALANCE / 1e18)") ETH"

  if [ "$BALANCE" -eq 0 ] 2>/dev/null || [ "$BALANCE" = "0" ]; then
    if [ "$config" = "mpt" ]; then
      log "  Seed account has no funds — funding from geth dev account..."

      # Get the dev account (first account in eth_accounts)
      DEV_ACCOUNT=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_accounts","params":[],"id":1}' \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0])")
      log "  Dev account: $DEV_ACCOUNT"

      # Send 1M ETH from dev account to seed account (dev account is auto-unlocked)
      # 1M ETH = 0xD3C21BCECCEDA1000000 (1e24 wei)
      TX_HASH=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$DEV_ACCOUNT\",\"to\":\"$SEED_ACCOUNT\",\"value\":\"0xD3C21BCECCEDA1000000\"}],\"id\":1}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['result'])")
      log "  Funding tx: $TX_HASH"

      # Wait for tx to be mined (dev.period=3, so ~3-6 seconds)
      log "  Waiting for funding tx to be mined..."
      for attempt in $(seq 1 30); do
        RECEIPT=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
          -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$TX_HASH\"],\"id\":1}" \
          | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print('mined' if r else 'pending')" 2>/dev/null || echo "pending")
        if [ "$RECEIPT" = "mined" ]; then
          log "  Funding tx mined after ${attempt}s"
          break
        fi
        sleep 1
        if [ "$attempt" -eq 30 ]; then
          log "  ERROR: Funding tx not mined after 30s"
          kill_geth
          exit 1
        fi
      done

      # Re-check balance
      BALANCE=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$SEED_ACCOUNT\",\"latest\"],\"id\":1}" \
        | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "0")
      log "  Seed balance after funding: $(python3 -c "print($BALANCE / 1e18)") ETH"
    else
      log "  ERROR: Seed account has no funds on $config"
      kill_geth
      exit 1
    fi
  fi

  # Deploy 5GB ERC20 via spamoor
  log "  Running spamoor erc20_bloater (${SPAMOOR_TARGET_GB}GB, seed=$SPAMOOR_SEED)..."
  "$SPAMOOR_BIN" erc20_bloater \
    --rpchost="http://localhost:8545" \
    --privkey="$PRIVKEY" \
    --seed="$SPAMOOR_SEED" \
    --target-gb="$SPAMOOR_TARGET_GB" \
    --target-gas-ratio=0.8 \
    --wallet-count=200 \
    -v > "$spamoor_log" 2>&1

  # Extract contract address
  CONTRACT_ADDR=$(grep -oP 'contract: \K0x[0-9a-fA-F]+' "$spamoor_log" | tail -1)

  if [ -z "$CONTRACT_ADDR" ]; then
    # Try alternate pattern
    CONTRACT_ADDR=$(grep -oP 'contract \K0x[0-9a-fA-F]+' "$spamoor_log" | tail -1)
  fi

  if [ -z "$CONTRACT_ADDR" ]; then
    log "  ERROR: Could not extract contract address from spamoor log"
    tail -20 "$spamoor_log"
    kill_geth
    exit 1
  fi

  log "  ERC20 deployed at: $CONTRACT_ADDR"

  # Verify contract has code
  CODE_LEN=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$CONTRACT_ADDR\",\"latest\"],\"id\":1}" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(len(r)//2-1 if len(r)>2 else 0)")

  if [ "$CODE_LEN" -eq 0 ] 2>/dev/null; then
    log "  ERROR: Contract has no code after deployment!"
    kill_geth
    exit 1
  fi
  log "  Contract verified: ${CODE_LEN} bytes"

  # Write stubs.json
  cat > "$stubs_file" << STUBS_EOF
{
  "test_sload_empty_erc20_balanceof_SMALL": "$CONTRACT_ADDR",
  "test_sstore_erc20_approve_SMALL": "$CONTRACT_ADDR",
  "test_mixed_sload_sstore_SMALL": "$CONTRACT_ADDR"
}
STUBS_EOF
  log "  stubs.json written to $stubs_file"
  cat "$stubs_file"

  # Also copy stubs into the DB directory
  cp "$stubs_file" "$db_path/stubs.json"
  cp "$spamoor_log" "$db_path/spamoor-5gb.log"

  # Graceful shutdown to persist blocks
  kill_geth
  log "  $config ERC20 deployment complete"
done

# =============================================================================
# Summary
# =============================================================================
log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║  All done!                                                   ║"
log "╚══════════════════════════════════════════════════════════════╝"
log ""
log "  DB sizes:"
for config in "${CONFIGS[@]}"; do
  DB_SIZE=$(du -sh "${DB_BASE}/${config}/geth/chaindata" 2>/dev/null | cut -f1 || echo "N/A")
  log "    $config: $DB_SIZE"
done
log ""
log "  Stubs:"
for config in "${CONFIGS[@]}"; do
  if [ -f "${RESULTS_BASE}/${config}/stubs.json" ]; then
    ADDR=$(python3 -c "import json; d=json.load(open('${RESULTS_BASE}/${config}/stubs.json')); print(list(d.values())[0])")
    log "    $config: $ADDR"
  else
    log "    $config: MISSING"
  fi
done
log ""
log "  Ready for benchmarks!  Run: bash run_benchmarks.sh"
