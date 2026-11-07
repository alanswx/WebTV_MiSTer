# Deploying the WebTV core and its network

## Everything on the MiSTer (the default)

```
 WebTV core ── 16550 UART ── /dev/ttyS1 ── webtv_modem.py ──▶ web pages (fetched by the MiSTer)
   (FPGA)                      (MiSTer Linux: modem + PPP + IP/TCP gateway + WebTV service)
```

`webtv_modem.py` is one Python file using only the standard library of the MiSTer's Python 3.9
(there is no pip on a MiSTer, so nothing can be pulled in). It answers the box's call itself
(`connect=local`): the modem, PPP, a user-space TCP/IP gateway, the WebTV service, and web fetching
with page slimming, image conversion (via the MiSTer's own Imlib2) and built-in root certificates.
See [README.md](README.md). It runs as a service (`webtv_modem.sh`), started at boot, that only opens
the UART while the WebTV core is loaded (`/tmp/CORENAME`), so it doesn't disturb other cores.

Optionally the modem relays calls to a line server on the LAN instead (`connect=HOST:PORT`):
`webtv_modem.py --listen 2323` on any machine with Python 3, or the original Node `lineserver.mjs`.

### Install

On the MiSTer, from this repository:

    RBF=path/to/WebTV.rbf linux/install_mister.sh MISTER_HOST

This copies the core to `_Computer/WebTV.rbf`, the modem service to `/media/fat/linux/webtv/`
(with `webtv.cfg`, its settings), adds one line to
`/media/fat/linux/user-startup.sh` so the service starts at boot, writes `_Computer/WebTV.mgl` (core
+ the disk image in `games/WebTV`), and starts the service. Put the boot ROM in
`games/WebTV/boot.rom` and a disk image in `games/WebTV/` yourself.

On the MiSTer: `/media/fat/linux/webtv/webtv_modem.sh status|restart|log`.

### What made it fragile, and what fixed it

| Problem | Fix |
|---|---|
| The box hangs up / powers off / reboots by dropping DTR; the modem stayed online to the old call, the next `AT**` firmware download went down the line, and the box's watchdog fired (purple screen) | The modem watches the box's DTR (it reaches the HPS UART as DSR) and hangs up on the drop (`&D2`) |
| Restarting the line server lost every registration | File-backed store |
| One bad request could kill the line server; a killed program stayed dead | Exception guards; restart loops on both sides |
| The modem script had to be started by hand, and would hold `/dev/ttyS1` for other cores | Boot service that follows `/tmp/CORENAME` |
| Unbounded debug log in `/tmp` (RAM) | `--logfile` keeps 4 MB + one old copy |
| A LAN machine running Node was needed for the line and service | Ported to Python into `webtv_modem.py` (`connect=local`) |
| Modern pages (megabytes of script) ran the box out of memory | Scripts, styles and unused attributes stripped; 384 KB cap after that |
| HTTPS failed for sites with roots newer than the MiSTer's 2020 bundle | Mozilla's roots built into the script |

## Why Python, and not C or Node

What the MiSTer's Linux offers (checked on a current MiSTer image): ARMv7 (Cortex-A9, 2 cores), ~490 MB
RAM, Python 3.9 with its full standard library (ssl/OpenSSL 1.1.1, hashlib, urllib, ctypes, zlib), no
pip, no compiler, no Node; Imlib2, libjpeg-turbo, libpng and libgif are installed (the menu uses them);
the kernel has `pppd` but no NAT.

The missing NAT is why `pppd` alone isn't enough: a WebTV box first connects to WebTV's own addresses
from its NVRAM and ROM (e.g. `207.79.34.4:1601`, `10.0.128.1:1615`), and every connection to a WTVP
port has to reach the service whatever the address. So the user-space gateway moves too.

* **Python** (done): one file, no dependencies, the daemon that already owns the UART. The line is
  57,600 bit/s, so speed doesn't matter; DES and RC4 are small pure-Python functions, and image work
  goes to Imlib2 (native) through ctypes.
* **C** would be a static binary needing nothing, but there's no compiler on the MiSTer (every change
  means cross-compiling) and HTTPS means linking OpenSSL. The Python file is a clean spec to port from
  if it's ever needed.
* **Node** would run the original code unchanged, at ~100 MB of SD space and an unusual runtime.
