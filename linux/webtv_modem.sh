#!/bin/sh
# WebTV modem service for the MiSTer: keeps webtv_modem.py running (restarted if it exits). It only
# opens the UART while the WebTV core is loaded, so it can start at boot without bothering other
# cores. Settings in webtv.cfg next to this script; log in /tmp/webtv_modem.log.
#
#   webtv_modem.sh start|stop|restart|status|log
# /media/fat/linux/user-startup.sh runs "webtv_modem.sh start" at boot (install_mister.sh adds it).
DIR=$(dirname "$(readlink -f "$0")")
PIDF=/tmp/webtv_modem.pid
LOG=/tmp/webtv_modem.log

stop() {
  [ -f $PIDF ] && kill $(cat $PIDF) 2>/dev/null
  [ -f $PIDF.py ] && kill $(cat $PIDF.py) 2>/dev/null
  rm -f $PIDF $PIDF.py
}
start() {
  stop
  (
    while true; do
      python3 -u $DIR/webtv_modem.py --config $DIR/webtv.cfg --core WebTV --logfile $LOG &
      echo $! > $PIDF.py
      wait $!
      echo "[supervisor] webtv_modem.py exited ($?), restarting" >> $LOG
      sleep 2
    done
  ) < /dev/null > /dev/null 2>&1 &
  echo $! > $PIDF
}
case "$1" in
  start|restart) start ;;
  stop) stop ;;
  status) if [ -f $PIDF ] && kill -0 $(cat $PIDF) 2>/dev/null; then echo "running (core: $(cat /tmp/CORENAME 2>/dev/null))"; else echo stopped; fi ;;
  log) exec tail -f $LOG ;;
  *) echo "usage: $0 start|stop|restart|status|log"; exit 1 ;;
esac
