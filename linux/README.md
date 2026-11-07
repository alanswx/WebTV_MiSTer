# Linux side (MiSTer HPS) for the WebTV core

Installing and running it: [DEPLOY.md](DEPLOY.md).

The core's hardware-modem UART (16550) is wired to the MiSTer's UART (/dev/ttyS1) when the OSD
"Serial port" is "Modem" (the default). One program, `webtv_modem.py`, gives the box a modem, a
phone line and a WebTV service. It is a single file that needs only the Python 3 that comes with
the MiSTer:

    box -- UART -- webtv_modem.py: modem -- PPP server -- IP/TCP gateway -- WebTV service -- web
                                                                                  (fetched by the MiSTer)

* **Modem**: the Rockwell modem behind the UART, ported from the webtv-bridge JS model -- AT
  commands, TellyScript's `AT**` firmware download, dialing, carrier detect (HPS DTR -> the core's
  DCD). The box drops DTR when it hangs up, powers off or reboots; the modem then hangs up and
  returns to command mode (before this the next `AT**` went down the old call and the box's
  watchdog fired: the purple screen).
* **Line** (`connect=local`, the default): a PPP server and a user-space IP/TCP gateway, ported from
  webtv-bridge's `src/net`. Every connection to a WTVP port (1600-1699) goes to the service, whatever
  address the box dials (it starts with WebTV's own, e.g. 207.79.34.4:1601); DNS is answered here.
* **Service**: ported from webtv-bridge's `src/wtvsrv` (which follows zefie's minisrv):
  registration, login (DES challenge/response, tickets, RC4-encrypted connections), home page,
  "Go to page". Registrations are kept in `webtv-accounts.json` next to the script.
* **Web pages** the box asks the service for are fetched by the MiSTer, and made fit for a 1997 box:
  - text is converted to Latin-1 (the box's character set);
  - scripts, style sheets, comments, SVG and the attributes only modern browsers use are removed
    (YouTube 2.1 MB -> 13 KB, CNN 8.3 MB -> 340 KB); pages still over 384 KB get a "Page too large"
    page instead, since bigger ones run the 8 MB box out of memory;
  - images the box can't decode (it has GIF, baseline JPEG and XBM; no PNG) are converted, and photos
    wider than the screen are scaled down and recompressed, as WebTV's own service did. Imlib2 (the
    MiSTer's image library) does the decoding and scaling through ctypes, so this takes well under a
    second on the ARM. Transparent images become GIF (our encoder), the rest JPEG. GIFs are left alone
    unless huge;
  - HTTPS is checked against Mozilla's root certificates, built into the script (the MiSTer's own
    bundle dates from 2020). `update_ca.py` refreshes them.

`--log` also prints the core's debug console, which the core writes into a DDR3 ring (read through
/dev/mem at 0x30FB0000).

`webtv_modem.sh start|stop|restart|status|log` runs it as a service: restarted if it exits, settings
from `webtv.cfg` next to it (all the options are listed there), log in /tmp/webtv_modem.log (kept
under 4 MB). With `--core WebTV` it only opens the UART while the WebTV core is loaded, so it can
start at boot without taking the serial port from other cores. `install_mister.sh` sets it up.

### Running the line elsewhere

`connect=HOST:PORT` makes the modem relay calls to a line server instead:

    python3 webtv_modem.py --listen 2323      # the same service, on any machine with Python 3
    node lineserver.mjs --bridge /path/to/webtv-bridge [--port 2323] [--relay ws://host:8081]

`lineserver.mjs` is the JS original (webtv-bridge's network line and service, with the fixes that were
then ported); `start_net.sh [BRIDGE_DIR]` runs it and webtv-bridge's relay under restart loops.

### Starting the core

With an MGL that loads it and mounts the disk image in one step, e.g.

    <mistergamedescription>
      <rbf>_Development/WebTV</rbf>
      <file delay="0" type="s" index="0" path="/media/fat/games/WebTV/debug_webtv_w200_7.img"/>
    </mistergamedescription>

The boot ROM goes to games/WebTV/boot.rom. Power button: F1 on the keyboard (or the joystick's Power).

Screens: black = the box is on standby, waiting for Power. Purple = the OS crashed (its watchdog
fired); the debug log (`--log`) shows the registers and what it was doing. Reload the MGL to restart.
