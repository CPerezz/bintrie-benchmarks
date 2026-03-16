#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Generate binary trie DBs + Deploy SMALL ERC20 on each
#
# Phase 1: Generate DBs sequentially (state-actor, --seed 25519, 400GB each)
# Phase 2: For each DB: start geth → spamoor erc20_bloater → stubs.json → stop
#
# Usage: GROUP_DEPTHS="1 2 4 8" bash generate_dbs.sh
#        GROUP_DEPTHS="3 5 6" bash generate_dbs.sh
#
# All paths below must be edited for your environment.
# =============================================================================

STATE_ACTOR="/home/CPerezz/state-actor/state-actor"
GETH_BIN="/home/CPerezz/go-ethereum/build/bin/geth"
SPAMOOR_BIN="/home/CPerezz/spamoor-statebloat/bin/spamoor"
GENESIS="/home/CPerezz/state-actor/genesis.json"

DB_BASE="/home/CPerezz/bintrie_results"
SYMLINK_BASE="/home/CPerezz/dbs"
RESULTS_BASE="/home/CPerezz/results"

# Anvil's default account (pre-funded via state-actor --inject-accounts).
# IMPORTANT: The private key here MUST correspond to the account passed to
# state-actor's -inject-accounts flag. We use Anvil's default key because
# state-actor pre-funds it during DB generation, and spamoor needs it to
# deploy the ERC20 contract.
SEED_ACCOUNT="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
SEED_KEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
PRIVKEY="0x${SEED_KEY}"

TARGET_SIZE="400GB"
STATE_ACTOR_SEED=25519
SPAMOOR_SEED="bintrie-small"
SPAMOOR_TARGET_GB="0.01"

# Configurable via env var, e.g.: GROUP_DEPTHS="1 2 4 8" bash generate_dbs.sh
read -ra GROUP_DEPTHS <<< "${GROUP_DEPTHS:-1 2 4 8}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# =============================================================================
# kill_geth: SIGTERM first (flush), SIGKILL fallback
# =============================================================================
kill_geth() {
  local pids
  pids=$(pgrep -f "geth.*--dev" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    log "  Killing geth (SIGTERM): $pids"
    echo "$pids" | xargs kill -TERM 2>/dev/null || true
    sleep 8
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then
        log "  Force killing geth PID $pid"
        kill -9 "$pid" 2>/dev/null || true
      fi
    done
    sleep 2
  fi
  # Drop OS page cache
  sync
  log "  [cache] Dropping OS page cache..."
  if sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'; then
    log "  [cache] Page cache dropped successfully"
  else
    log "  [cache] ERROR: Failed to drop page cache (sudo). Aborting."
    log "  [cache] Fix: run 'sudo -v' before starting, or add NOPASSWD for drop_caches"
    exit 1
  fi
}

# =============================================================================
# start_geth: start geth dev node with cache for deployment
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
  local log_file="$4"

  kill_geth

  # Remove stale LOCK files
  rm -f "$datadir/geth/chaindata/LOCK" 2>/dev/null || true

  # Import seed key (idempotent)
  echo "$SEED_KEY" > /tmp/seed_key.hex
  echo "" | "$GETH_BIN" --datadir "$datadir" account import --password /dev/stdin /tmp/seed_key.hex 2>/dev/null || true
  rm -f /tmp/seed_key.hex

  log "  Starting geth ($config_id, gd=$group_depth, cache=4096 for deployment)..."
  "$GETH_BIN" \
    --datadir "$datadir" \
    --dev --dev.period 3 --dev.gaslimit 100000000 \
    --miner.etherbase "$SEED_ACCOUNT" \
    --cache 4096 \
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
    > "$log_file" 2>&1 &

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
log "║  Preflight checks                                           ║"
log "╚══════════════════════════════════════════════════════════════╝"

for bin in "$STATE_ACTOR" "$GETH_BIN" "$SPAMOOR_BIN"; do
  if [ ! -x "$bin" ]; then
    log "ERROR: $bin not found or not executable"
    exit 1
  fi
done

if [ ! -f "$GENESIS" ]; then
  log "ERROR: genesis.json not found at $GENESIS"
  exit 1
fi

AVAIL_TB=$(df --output=avail -BG /home/CPerezz | tail -1 | tr -d ' G')
NEEDED_GB=$((350 * ${#GROUP_DEPTHS[@]}))
log "  Disk available: ${AVAIL_TB}G | Needed (est): ${NEEDED_GB}G"
if [ "$AVAIL_TB" -lt "$NEEDED_GB" ]; then
  log "ERROR: Not enough disk space"
  exit 1
fi
log "  Disk check: OK"

# Kill any running geth before we start
kill_geth
log "  All preflight checks passed"

# =============================================================================
# PHASE 1: Generate DBs sequentially
# =============================================================================
log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║  Phase 1: Generate 3 DBs sequentially (GD-3, GD-5, GD-6)   ║"
log "║  Each: ~350GB, ~8h. Total: ~24h.                            ║"
log "╚══════════════════════════════════════════════════════════════╝"

for gd in "${GROUP_DEPTHS[@]}"; do
  config_id="bt-gd${gd}"
  db_path="${DB_BASE}/${config_id}-400g"
  symlink="${SYMLINK_BASE}/${config_id}"
  gen_log="${DB_BASE}/${config_id}-400g_gen.log"

  log ""
  log "================================================================"
  log "  Generating: $config_id (group-depth=$gd)"
  log "  DB path:    $db_path"
  log "  Started:    $(date '+%Y-%m-%d %H:%M:%S')"
  log "================================================================"

  # Skip if DB already exists and looks complete
  if [ -f "$gen_log" ] && grep -qi "generation complete" "$gen_log" 2>/dev/null; then
    log "  DB already generated (found completion marker in log). Skipping."
  else
    # Clean up partial previous run
    if [ -d "$db_path" ]; then
      log "  WARNING: $db_path exists (partial?), removing..."
      rm -rf "$db_path"
    fi

    mkdir -p "$db_path"

    "$STATE_ACTOR" \
      -db "$db_path/geth/chaindata" \
      -genesis "$GENESIS" \
      -binary-trie \
      -group-depth "$gd" \
      -target-size "$TARGET_SIZE" \
      -inject-accounts "$SEED_ACCOUNT" \
      -seed "$STATE_ACTOR_SEED" \
      -benchmark \
      -verbose \
      2>&1 | tee "$gen_log"
  fi

  DB_SIZE=$(du -sh "$db_path/geth/chaindata" 2>/dev/null | cut -f1 || echo "N/A")
  log "  $config_id generated: $DB_SIZE"

  # Create symlink in /home/CPerezz/dbs/
  if [ -L "$symlink" ] || [ -e "$symlink" ]; then
    rm -f "$symlink"
  fi
  ln -s "$db_path" "$symlink"
  log "  Symlink: $symlink -> $db_path"
done

log ""
log "  All 3 DBs generated."

# =============================================================================
# PHASE 2: Deploy SMALL ERC20 on each DB via spamoor
# =============================================================================
log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║  Phase 2: Deploy SMALL ERC20 on GD-3, GD-5, GD-6           ║"
log "╚══════════════════════════════════════════════════════════════╝"

for gd in "${GROUP_DEPTHS[@]}"; do
  config_id="bt-gd${gd}"
  db_path="${DB_BASE}/${config_id}-400g"
  results_dir="${RESULTS_BASE}/${config_id}"
  spamoor_log="${results_dir}/spamoor_small.log"
  stubs_file="${results_dir}/stubs.json"

  log ""
  log "================================================================"
  log "  Deploying SMALL ERC20 on $config_id (gd=$gd)"
  log "================================================================"

  mkdir -p "$results_dir"

  # Skip if stubs.json already exists
  if [ -f "$stubs_file" ]; then
    log "  stubs.json already exists at $stubs_file. Skipping."
    cat "$stubs_file"
    continue
  fi

  # Start geth with cache=4096 for faster deployment
  start_geth "$db_path" "$gd" "$config_id" "$results_dir/geth_deploy.log"

  # Set gas limit
  curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"miner_setGasLimit","params":["0x5F5E100"],"id":1}' > /dev/null

  # Verify seed account has funds
  BALANCE=$(curl -s http://localhost:8545 -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$SEED_ACCOUNT\",\"latest\"],\"id\":1}" \
    | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "0")
  log "  Seed balance: $(python3 -c "print($BALANCE / 1e18)") ETH"

  if [ "$BALANCE" -eq 0 ] 2>/dev/null; then
    log "  ERROR: Seed account has no funds on $config_id"
    kill_geth
    exit 1
  fi

  # Deploy SMALL ERC20 via spamoor
  log "  Running spamoor erc20_bloater (SMALL, ${SPAMOOR_TARGET_GB}GB, seed=$SPAMOOR_SEED)..."
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

  # Also copy stubs into the DB directory (mirrors bt-gd1-400g structure)
  cp "$stubs_file" "$db_path/stubs.json"
  cp "$spamoor_log" "$db_path/spamoor-small.log"

  # Graceful shutdown to persist blocks
  kill_geth
  log "  $config_id ERC20 deployment complete"
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
for gd in "${GROUP_DEPTHS[@]}"; do
  config_id="bt-gd${gd}"
  DB_SIZE=$(du -sh "${DB_BASE}/${config_id}-400g/geth/chaindata" 2>/dev/null | cut -f1 || echo "N/A")
  log "    $config_id: $DB_SIZE"
done
log ""
log "  Stubs:"
for gd in "${GROUP_DEPTHS[@]}"; do
  config_id="bt-gd${gd}"
  if [ -f "${RESULTS_BASE}/${config_id}/stubs.json" ]; then
    ADDR=$(python3 -c "import json; d=json.load(open('${RESULTS_BASE}/${config_id}/stubs.json')); print(list(d.values())[0])")
    log "    $config_id: $ADDR"
  else
    log "    $config_id: MISSING"
  fi
done
log ""
log "  Symlinks:"
for gd in "${GROUP_DEPTHS[@]}"; do
  ls -la "${SYMLINK_BASE}/bt-gd${gd}" 2>/dev/null | sed 's/^/    /'
done
log ""
log "  Ready for benchmarks!  Run: GROUP_DEPTHS=\"${GROUP_DEPTHS[*]}\" bash run_erc20_benchmarks.sh"
