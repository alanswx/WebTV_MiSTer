#!/bin/sh
# Build the tester zip: make_zip.sh CORE.rbf BOOT_ROM DISK_IMAGE OUT.zip
# The ROM and disk image are WebTV's own software: they are not in this repository, and the zip is
# for testers only.
set -e
[ $# -eq 4 ] || { echo "usage: make_zip.sh CORE.rbf BOOT_ROM DISK_IMAGE OUT.zip"; exit 1; }
H=$(cd "$(dirname "$0")" && pwd); L=$H/..
OUT=$(cd "$(dirname "$4")" && pwd)/$(basename "$4")
T=$(mktemp -d); mkdir -p $T/_Computer $T/games/WebTV $T/linux/webtv $T/Scripts
cp "$1" $T/_Computer/WebTV_$(date +%Y%m%d).rbf
cp "$H/WebTV Plus.mgl" $T/_Computer/
cp "$2" $T/games/WebTV/boot.rom
cp "$3" $T/games/WebTV/webtv_disk.img
cp $L/webtv_modem.py $L/webtv_modem.sh $L/webtv.cfg $L/pcsample.py $T/linux/webtv/
cp $H/webtv_setup.sh $H/webtv_uninstall.sh $T/Scripts/
cp $H/README.txt $T/
chmod +x $T/Scripts/*.sh $T/linux/webtv/*.sh $T/linux/webtv/*.py
rm -f "$OUT"; (cd $T && zip -q -r -9 -X "$OUT" README.txt _Computer games linux Scripts)
rm -rf $T; ls -la "$OUT"
