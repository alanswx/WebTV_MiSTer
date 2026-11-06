#!/bin/sh
# Install the WebTV core and its modem service on a MiSTer over ssh.
#   [RBF=path/to/WebTV.rbf] linux/install_mister.sh MISTER_HOST [LINESERVER_HOST:PORT]
# Copies the core (output_files/WebTV.rbf -> _Computer/WebTV.rbf), the modem service
# (/media/fat/linux/webtv/), and a webtv.cfg if there is none yet; adds the service to
# /media/fat/linux/user-startup.sh (once); writes _Computer/WebTV.mgl if a disk image is in
# games/WebTV; then (re)starts the service. The boot ROM (games/WebTV/boot.rom) and disk images are
# not copied: they aren't part of this repository.
set -e
H=${1:?usage: install_mister.sh MISTER_HOST [LINESERVER_HOST:PORT]}
LINE=$2
cd "$(dirname "$0")/.."
D=/media/fat/linux/webtv
ssh root@$H "mkdir -p $D /media/fat/_Computer /media/fat/games/WebTV"
scp -q linux/webtv_modem.py linux/webtv_modem.sh root@$H:$D/
ssh root@$H "chmod +x $D/webtv_modem.sh; [ -f $D/webtv.cfg ] || cat > $D/webtv.cfg" < linux/webtv.cfg
[ -n "$LINE" ] && ssh root@$H "sed -i 's/^connect=.*/connect=$LINE/' $D/webtv.cfg"
RBF=${RBF:-output_files/WebTV.rbf}
if [ -f "$RBF" ]; then scp -q "$RBF" root@$H:/media/fat/_Computer/WebTV.rbf; fi
ssh root@$H 'sh -s' <<'EOS'
U=/media/fat/linux/user-startup.sh
[ -f $U ] || printf '#!/bin/sh\n' > $U
grep -q webtv_modem.sh $U || printf '\n# WebTV core: modem service (only active while the WebTV core is loaded)\n[ -e /media/fat/linux/webtv/webtv_modem.sh ] && /media/fat/linux/webtv/webtv_modem.sh $1\n' >> $U
IMG=$(ls /media/fat/games/WebTV/*.img 2>/dev/null | head -1)
if [ -n "$IMG" ] && [ ! -f /media/fat/_Computer/WebTV.mgl ]; then
  cat > /media/fat/_Computer/WebTV.mgl <<EOM
<mistergamedescription>
  <rbf>_Computer/WebTV</rbf>
  <file delay="0" type="s" index="0" path="$IMG"/>
</mistergamedescription>
EOM
fi
[ -f /media/fat/games/WebTV/boot.rom ] || echo "note: put the boot ROM in /media/fat/games/WebTV/boot.rom"
/media/fat/linux/webtv/webtv_modem.sh restart
/media/fat/linux/webtv/webtv_modem.sh status
EOS
