#!/bin/sh
# WebTV core: remove everything the tester zip and webtv_setup installed. Run it from the MiSTer's
# Scripts menu (or over ssh). Your registration and the box's disk image are deleted too.
F=/media/fat
D=$F/linux/webtv
U=$F/linux/user-startup.sh

# stop the service (and its supervisor) if it's running
[ -x $D/webtv_modem.sh ] && $D/webtv_modem.sh stop
for p in /tmp/webtv_modem.pid /tmp/webtv_modem.pid.py; do
  [ -f $p ] && kill $(cat $p) 2>/dev/null
  rm -f $p
done

# take the service out of the boot script (the comment line and the line after it)
if [ -f $U ] && grep -q webtv_modem.sh $U; then
  grep -v -e 'webtv_modem.sh' -e '^# WebTV core: modem service' $U > $U.webtv-tmp && cat $U.webtv-tmp > $U
  rm -f $U.webtv-tmp
  echo "Removed the WebTV service from $U"
fi

rm -f $F/_Computer/WebTV_*.rbf "$F/_Computer/WebTV Plus.mgl"
rm -f $F/games/WebTV/boot.rom $F/games/WebTV/webtv_disk.img
rmdir $F/games/WebTV 2>/dev/null
rm -f $D/webtv_modem.py $D/webtv_modem.sh $D/webtv.cfg $D/pcsample.py $D/webtv-accounts.json $D/webtv-accounts.json.tmp
rm -rf $D/__pycache__
rmdir $D 2>/dev/null
rm -f /tmp/webtv_modem.log /tmp/webtv_modem.log.1 /tmp/webtv-img-*
rm -f $F/Scripts/webtv_setup.sh
rm -f "$0" $F/Scripts/webtv_uninstall.sh
echo "WebTV removed."
