#!/usr/bin/env bash
# Deploys Swapline to the local mainnet fork (scripts/fork/start-fork.ps1) with the real Deploy.s.sol, then seeds
# demo activity so the frontend has something to show: LP liquidity in every market, a few trades, a vault deposit.
#
#   bash scripts/fork/deploy-fork.sh            # RPC defaults to http://127.0.0.1:18546
#
# No private keys are used anywhere: anvil impersonation + `--unlocked` for the deployer and the demo accounts.
# USDG for demo accounts is moved from Morpho Blue's balance ON THE LOCAL FORK ONLY (USDG's proxy uses a custom
# storage layout, so anvil_dealERC20 cannot locate its balance slot).
set -euo pipefail
RPC="${FORK_RPC:-http://127.0.0.1:18546}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
WHALE=0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010 # Morpho Blue (fork-only funding source)
DEPLOYER=0x5ea1000000000000000000000000000000005ea1
LP=0x5ea1000000000000000000000000000000000001
TRADER=0x5ea1000000000000000000000000000000000002
SAVER=0x5ea1000000000000000000000000000000000003
# Well-known address you can connect in a browser wallet on the fork (override with DEMO_WALLET=0x...)
DEMO_WALLET="${DEMO_WALLET:-}"

rpc() { cast rpc "$@" --rpc-url "$RPC" >/dev/null; }
send() { local from=$1; shift; cast send "$@" --from "$from" --unlocked --rpc-url "$RPC" >/dev/null; }

[ "$(cast chain-id --rpc-url "$RPC")" = "31337" ] || { echo "fork not running on $RPC"; exit 1; }

echo "== funding accounts"
for a in $DEPLOYER $LP $TRADER $SAVER $WHALE ${DEMO_WALLET}; do
  rpc anvil_setBalance "$a" 0x56BC75E2D63100000
  rpc anvil_impersonateAccount "$a"
done
for a in $LP $TRADER $SAVER ${DEMO_WALLET}; do
  send $WHALE $USDG "transfer(address,uint256)" "$a" 2000000000000 # 2,000,000 USDG
done

echo "== deploying (script/Deploy.s.sol)"
(cd "$ROOT/contracts" && forge script script/Deploy.s.sol --rpc-url "$RPC" --unlocked --sender $DEPLOYER --broadcast --slow \
  | grep -E "Deployment written|ONCHAIN EXECUTION|Error")

DEP="$ROOT/deployments/31337.json"
j() { python -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))" "$DEP" "$1"; }
ME=$(j "d['marginEngine']")
N=$(j "len(d['markets'])")

echo "== seeding liquidity in $N markets"
send $LP $USDG "approve(address,uint256)" "$ME" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
for i in $(seq 0 $((N-1))); do
  M=$(j "d['markets'][$i]['market']")
  send $LP "$ME" "deposit(address,address,uint256)" "$M" $LP 150000000000 # 150k margin
  send $LP "$M" "mint(int24,int24,uint128)" 100 900 2000000000000       # L=2e12 over 1%..9%
done

echo "== demo trades"
send $TRADER $USDG "approve(address,uint256)" "$ME" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
NOW=$(cast block latest -f timestamp --rpc-url "$RPC")
for i in 0 1 4; do
  M=$(j "d['markets'][$i]['market']")
  send $TRADER "$ME" "deposit(address,address,uint256)" "$M" $TRADER 5000000000
  send $TRADER "$M" "trade(int256,uint256,uint256)" 40000000000 1000000000000000000 $((NOW + 3600))     # pay fixed 40k
done
M=$(j "d['markets'][2]['market']")
send $TRADER "$ME" "deposit(address,address,uint256)" "$M" $TRADER 5000000000
cast send --from $TRADER --unlocked --rpc-url "$RPC" "$M" "trade(int256,uint256,uint256)" -- -25000000000 0 $((NOW + 3600)) >/dev/null # receive fixed 25k

echo "== fixed-rate vault deposit"
V=$(j "d['markets'][1]['vault']")
send $SAVER $USDG "approve(address,uint256)" "$V" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
send $SAVER "$V" "deposit(uint256,address)" 10000000000 $SAVER

echo "== done. Deployment: deployments/31337.json  (frontend config: app/src/config/deployments.31337.json)"
