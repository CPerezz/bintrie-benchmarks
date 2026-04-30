#!/bin/bash
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

restart_spamoor() {
  echo "[$(date +%H:%M:%S)] Killing spamoor..."
  pkill -f "spamoor erc20_bloater" 2>/dev/null || true
  sleep 2
  local gl=$(get_gas_limit)
  echo "[$(date +%H:%M:%S)] Starting spamoor (gas limit: $gl)..."
  nohup "$SPAMOOR" erc20_bloater \
    --rpchost="$RPC" \
    --privkey="0x${SEED_KEY}" \
    --seed=mpt-vs-bt \
    --target-gb=5 \
    --target-gas-ratio=0.8 \
    --wallet-count=200 \
    --existing-contract=0xF852dB3A94Ee27370B47011eBD1610e7718802Bd \
    -v \
    >> "$LOG" 2>&1 &
  echo "[$(date +%H:%M:%S)] Spamoor PID=$!"
}

MILESTONES=(100000000 200000000 300000000 400000000 500000000 600000000 700000000 800000000 900000000)
MILESTONE_IDX=0

echo "[$(date +%H:%M:%S)] Ramp monitor started. Gas limit: $(get_gas_limit)"

while [ $MILESTONE_IDX -lt ${#MILESTONES[@]} ]; do
  TARGET=${MILESTONES[$MILESTONE_IDX]}
  GAS=$(get_gas_limit)

  if [ "$GAS" -ge "$TARGET" ]; then
    echo "[$(date +%H:%M:%S)] Gas limit $GAS >= milestone $TARGET — restarting spamoor"
    restart_spamoor
    MILESTONE_IDX=$((MILESTONE_IDX + 1))
  fi
  sleep 30
done

echo "[$(date +%H:%M:%S)] All milestones reached. Gas limit: $(get_gas_limit). Ramp complete."
