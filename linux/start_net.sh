#!/bin/sh
# Start (or restart) the WebTV network on the server host: webtv-bridge's Internet relay and the
# line server the MiSTer's modem dials. Each is restarted if it exits. Logs: relay.log, lineserver.log.
#   start_net.sh [BRIDGE_DIR (default ~/build/webtv-bridge)]
BR=${1:-$HOME/build/webtv-bridge}
HERE=$(dirname "$(readlink -f "$0")")
cd "$HERE"
for f in .relay.pid .line.pid; do [ -f $f ] && kill -- -$(cat $f) 2>/dev/null; done
for p in $(pgrep -u $USER -f "node .*(relay|lineserver)\.mjs"); do kill $p; done
sleep 1
setsid sh -c "echo \$\$ > .relay.pid; while true; do node $BR/tools/relay.mjs --port 8081 >> relay.log 2>&1; echo restart >> relay.log; sleep 2; done" < /dev/null > /dev/null 2>&1 &
sleep 1
setsid sh -c "echo \$\$ > .line.pid; while true; do node $HERE/lineserver.mjs --bridge $BR --relay ws://127.0.0.1:8081 >> lineserver.log 2>&1; echo restart >> lineserver.log; sleep 2; done" < /dev/null > /dev/null 2>&1 &
sleep 2
tail -n 2 relay.log lineserver.log
