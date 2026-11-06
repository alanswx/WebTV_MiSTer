# Deploying the WebTV core and its network

## Today: MiSTer + a LAN server

```
 WebTV core ── 16550 UART ── /dev/ttyS1 ── webtv_modem.py ──TCP──▶ lineserver.mjs ──▶ WebTV service (built in)
   (FPGA)                      (MiSTer Linux)                       (LAN machine, Node)   └▶ web pages (fetch) / relay
```

* **MiSTer**: `webtv_modem.py` is the modem (AT commands, TellyScript's firmware download, DTR/DCD).
  On a dial it opens a TCP connection to the line server and relays the PPP bytes. It runs as a
  service (`webtv_modem.sh`), started at boot, that only opens the UART while the WebTV core is
  loaded (`/tmp/CORENAME`), so it doesn't disturb other cores' serial use.
* **LAN server**: `lineserver.mjs` answers each call with webtv-bridge's PPP server, user-space
  TCP/IP gateway and WebTV service. It fetches the web pages the box asks the service for, and keeps
  registrations in `~/.webtv-lineserver.json`. `start_net.sh` runs it (and webtv-bridge's relay)
  under restart loops.

### Install

On the LAN server (any machine with Node 18+ and a webtv-bridge checkout):

    linux/start_net.sh /path/to/webtv-bridge        # starts relay + line server, restarts them if they exit

To start them at boot without root: `crontab -e` and add
`@reboot /path/to/WebTV_MiSTer/linux/start_net.sh /path/to/webtv-bridge`. (A systemd unit works too.)

On the MiSTer, from this repository:

    RBF=path/to/WebTV.rbf linux/install_mister.sh MISTER_HOST LINESERVER_HOST:2323

This copies the core to `_Computer/WebTV.rbf`, the modem service to `/media/fat/linux/webtv/`
(with `webtv.cfg`, which holds the line server's address), adds one line to
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

## Next: everything on the MiSTer

The goal is a MiSTer that needs nothing else on the LAN. What the MiSTer's Linux offers
(checked on a current MiSTer image):

| | |
|---|---|
| CPU / RAM | ARMv7 (Cortex-A9), ~490 MB, ~400 MB available |
| Python | 3.9, standard library only |
| Node | none |
| PPP | `pppd`, `/dev/ppp`, `CONFIG_PPP_ASYNC` |
| NAT | **none** (`CONFIG_IP_NF_NAT` not set); `CONFIG_TUN=y` |
| SD space | whatever the user has left (332 MB on the test card) |

The missing NAT matters: a WebTV box first connects to WebTV's own addresses from its NVRAM and ROM
(e.g. `207.79.34.4:1601`, `10.0.128.1:1615`). webtv-bridge's gateway sends **every** connection to a
WTVP port (1600-1699) to the service, whatever the address. With `pppd` and the kernel's TCP/IP that
would need a NAT redirect, which this kernel can't do. So `pppd` alone isn't enough: the user-space
gateway (PPP + IP/TCP + the service) has to move too. That is webtv-bridge's `src/net/ppp.js`
(370 lines), `ip.js` (387), `line.js` (164) and `src/wtvsrv/` (~900, with its own DES, RC4 and MD5).

### Option A: port to Python (fold into webtv_modem.py)

* One file, no dependencies, the same daemon that already owns the UART: on a dial it answers the
  call itself instead of opening a socket.
* ~1,800 lines of JS to port; the user-space TCP needs care (windows, retransmit, MSS 536).
  Web pages via `urllib`, DNS via `socket.getaddrinfo`.
* Speed is not a concern: the line is ~57,600 bit/s.
* A second copy of webtv-bridge's network and service logic to keep in step. Testable against
  the JS one: the same PPP byte stream in, the same responses out.

### Option B: port to C

* Smallest and fastest; a static ARM binary, cross-compiled (MiSTer's own toolchain is
  arm-linux-gnueabihf). Could later also take over the modem from Python.
* The most work, and HTTP(S) fetching needs a TLS library (or a small helper).
* webtv-bridge's `pico/` firmware (`modem.c`, `ppp.c`, `gw.c`, for the Raspberry Pi Pico bridge)
  is C already and covers modem + PPP + gateway; the service would still need porting.

### Option C: Node on the MiSTer

* Copy an armv7l Node build (Node 22 needs glibc ≥ 2.28; MiSTer has 2.31) and webtv-bridge's
  `src/` to the SD card and run `lineserver.mjs` locally against `127.0.0.1`. The modem stays as is.
* No port, the exact tested code. Costs ~100 MB of SD space and ~50 MB of RAM while running.

### Recommendation

Get it solid with the LAN server first (now). Then **A** (Python): it removes the dependency
without adding a runtime, keeps one daemon, and the line speed makes Python's speed irrelevant.
**C** is the fallback if the port drags on; **B** only if Python turns out too slow or heavy, which
is unlikely at 57,600 bit/s.
