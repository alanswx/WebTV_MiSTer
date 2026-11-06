#!/bin/sh
# Keep the WebTV modem running on the MiSTer: restarts webtv_modem.py if it exits.
#   webtv_modem.sh [HOST:PORT]     (default 10.0.2.128:2323; log in /tmp/modem.log)
# Started from /media/fat/linux/user-startup.sh; safe to run again (replaces the running one).
LINE=${1:-10.0.2.128:2323}
DIR=$(dirname "$(readlink -f "$0")")
PIDF=/tmp/webtv_modem.pid
# stop a running one (the supervisor loop, then its python)
[ -f $PIDF ] && kill $(cat $PIDF) 2>/dev/null
[ -f $PIDF.py ] && kill $(cat $PIDF.py) 2>/dev/null
sleep 1
(
  while true; do
    python3 -u $DIR/webtv_modem.py --log --connect $LINE >> /tmp/modem.log 2>&1 &
    echo $! > $PIDF.py
    wait $!
    echo "[supervisor] webtv_modem.py exited ($?), restarting" >> /tmp/modem.log
    sleep 2
  done
) < /dev/null > /dev/null 2>&1 &
echo $! > $PIDF
