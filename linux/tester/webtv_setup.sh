#!/bin/sh
# WebTV core: one-time setup. Run it from the MiSTer's Scripts menu (or over ssh).
# Makes the WebTV modem service start whenever the MiSTer boots, and starts it now.
D=/media/fat/linux/webtv
U=/media/fat/linux/user-startup.sh
if [ ! -f $D/webtv_modem.py ]; then echo "$D/webtv_modem.py is missing: copy the linux folder from the zip first"; exit 1; fi
chmod +x $D/webtv_modem.sh
[ -f $U ] || printf '#!/bin/sh\n' > $U
if ! grep -q webtv_modem.sh $U; then
  printf '\n# WebTV core: modem service (only active while the WebTV core is loaded)\n[ -e %s/webtv_modem.sh ] && %s/webtv_modem.sh $1\n' $D $D >> $U
  echo "Added the WebTV service to $U"
fi
$D/webtv_modem.sh restart
sleep 1
echo "WebTV service: $($D/webtv_modem.sh status)"
echo "Done. Load 'WebTV Plus' from the Computer menu, then press F1 to turn the box on."
