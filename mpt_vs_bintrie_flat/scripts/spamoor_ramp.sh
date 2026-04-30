#!/bin/bash
# Monitors gas limit ramp and restarts spamoor to scale tx count.
# Spamoor auto-detects gas limit on startup but doesn't adjust mid-run.
# This script restarts it at each 100M milestone so it sends more txs.

set -e

SPAMOOR="/home/CPerezz/spamoor/bin/spamoor"
SEED_KEY="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RPC="http://localhost:8545"
LOG="/home/CPerezz/bintrie-benchmarks/mpt-vs-bintrie/results/bt-gd5-flat/spamoor_deploy.log"

get_gas_limit() {
  curl -s "$RPC" -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d['result']['gasLimit'],16))"
}

get_block() {
  curl -s "$RPC" -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d['result']['number'],16))"
}

restart_spamoor() {
  echo "[$(date)] Killing spamoor..."
  pkill -f "spamoor erc20_bloater" 2>/dev/null || true
  sleep 2
  echo "[$(date)] Starting spamoor (gas limit: $(get_gas_limit))..."
  nohup "$SPAMOOR" erc20_bloater \
    --rpchost="$RPC" \
    --privkey="0x${SEED_KEY}" \
    --seed=mpt-vs-bt \
    --target-gb=5 \
    --target-gas-ratio=0.8 \
    --wallet-count=200 \
    -v \
    >> "$LOG" 2>&1 &
  echo "[$(date)] Spamoor PID=$!"
}

# Milestones: restart at 300M, 500M, 700M, 900M
# (already running at ~170M, next restart at 300M)
MILESTONES=(300000000 500000000 700000000 900000000)
MILESTONE_IDX=0

echo "[$(date)] Spamoor ramp monitor started"
echo "[$(date)] Current gas limit: $(get_gas_limit)"

while [ $MILESTONE_IDX -lt ${#MILESTONES[@]} ]; do
  TARGET=${MILESTONES[$MILESTONE_IDX]}
  GAS=$(get_gas_limit)
  BLOCK=$(get_block)

  if [ "$GAS" -ge "$TARGET" ]; then
    echo "[$(date)] Gas limit $GAS >= milestone $TARGET at block $BLOCK — restarting spamoor"
    restart_spamoor
    MILESTONE_IDX=$((MILESTONE_IDX + 1))
  fi

  # Check every 30 seconds
  sleep 30
done

echo "[$(date)] All milestones reached. Gas limit: $(get_gas_limit). Spamoor running at full capacity."
echo "[$(date)] Ramp monitor exiting. Spamoor will continue until target-gb reached."
