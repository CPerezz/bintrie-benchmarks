#!/bin/bash
# Waits for state-actor to finish, verifies the DB, starts geth + spamoor.
set -euo pipefail

CAMPAIGN_DIR="/home/CPerezz/bintrie-benchmarks/mpt-vs-bintrie"
DATADIR="$CAMPAIGN_DIR/dbs/bt-gd5-flat"
RESULTS="$CAMPAIGN_DIR/results/bt-gd5-flat"
GETH="$CAMPAIGN_DIR/bin/geth-bintrie"
SPAMOOR="/home/CPerezz/spamoor/bin/spamoor"
SEED_KEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# 1. Wait for state-actor to finish
log "Waiting for state-actor to finish..."
while pgrep -f "state-actor-bintrie" > /dev/null 2>&1; do
    SIZE=$(du -sh "$DATADIR/geth/chaindata" 2>/dev/null | cut -f1 || echo "?")
    LAST=$(tail -1 "$RESULTS/state_actor_gen.log" 2>/dev/null | head -c120)
    log "  DB=$SIZE | $LAST"
    sleep 60
done
log "State-actor finished!"

# Check for errors
if grep -q "error\|panic\|fatal" "$RESULTS/state_actor_gen.log" 2>/dev/null; then
    log "ERROR: state-actor may have crashed. Check $RESULTS/state_actor_gen.log"
    tail -5 "$RESULTS/state_actor_gen.log"
    exit 1
fi

# 2. Verify DB
DB_SIZE=$(du -sh "$DATADIR/geth/chaindata" 2>/dev/null | cut -f1)
log "DB size: $DB_SIZE"

ROOT=$(grep "State Root:" "$RESULTS/state_actor_gen.log" | tail -1 | awk '{print $NF}')
log "State root: $ROOT"

# 3. Start geth
log "Starting geth..."
rm -f "$DATADIR/geth/chaindata/LOCK" "$DATADIR/geth/LOCK" 2>/dev/null

"$GETH" --datadir "$DATADIR" \
    --dev --dev.period 1 --dev.gaslimit 1000000000 \
    --miner.etherbase 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    --cache 4096 \
    --debug.logslowblock=0 \
    --http --http.addr 0.0.0.0 --http.port 8545 \
    --http.api eth,net,web3,debug,miner,txpool,admin \
    --nodiscover --maxpeers 0 \
    --rpc.allow-unprotected-txs --rpc.txfeecap 0 --rpc.gascap 0 \
    --verbosity 3 \
    --override.verkle=0 --bintrie.groupdepth 5 \
    > "$RESULTS/geth_deploy.log" 2>&1 &
GETH_PID=$!
log "Geth PID=$GETH_PID"

# Wait for RPC
for i in $(seq 1 120); do
    curl -s http://localhost:8545 -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' 2>/dev/null | grep -q result && break
    sleep 1
done
log "Geth RPC ready"

# Check for snapshot regen
sleep 5
if grep -q "Generating bintrie snapshot" "$RESULTS/geth_deploy.log" 2>/dev/null; then
    log "WARNING: Snapshot regeneration triggered! Flat state may not work."
else
    log "OK: No snapshot regeneration - flat state accepted"
fi

# Check seed balance
BAL=$(curl -s http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","latest"],"id":1}' \
    | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16)/1e18)")
log "Seed balance: $BAL ETH"

# 4. Start spamoor
log "Starting spamoor (5GB ERC20 bloat, target-gas-ratio=0.8, 200 wallets)..."
"$SPAMOOR" erc20_bloater \
    --rpchost=http://localhost:8545 \
    --privkey="0x${SEED_KEY}" \
    --seed=mpt-vs-bt \
    --target-gb=5 \
    --target-gas-ratio=0.8 \
    --wallet-count=200 \
    -v > "$RESULTS/spamoor_deploy.log" 2>&1 &
SPAMOOR_PID=$!
log "Spamoor PID=$SPAMOOR_PID"

# 5. Wait for spamoor to deploy contract and start bloating
sleep 30
if grep -q "deployed contract" "$RESULTS/spamoor_deploy.log" 2>/dev/null; then
    CONTRACT=$(grep "deployed contract" "$RESULTS/spamoor_deploy.log" | head -1 | grep -o '0x[0-9a-fA-F]*')
    log "ERC20 contract deployed: $CONTRACT"

    # Write stubs.json
    cat > "$RESULTS/stubs.json" << EOFSTUBS
{
  "test_sload_empty_erc20_balanceof_SMALL": "$CONTRACT",
  "test_sstore_erc20_approve_SMALL": "$CONTRACT",
  "test_mixed_sload_sstore_SMALL": "$CONTRACT"
}
EOFSTUBS
    log "stubs.json written"
else
    log "WARNING: Contract not yet deployed after 30s. Check spamoor log."
fi

log "All started. Monitor with:"
log "  tail -f $RESULTS/spamoor_deploy.log | grep progress"
log "  tail -f $RESULTS/geth_deploy.log | grep 'Slow block'"
