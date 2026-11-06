# Linux side (MiSTer HPS) for the WebTV core

The core's hardware-modem UART (16550) is wired to the MiSTer's UART (/dev/ttyS1) when the OSD
"Serial port" is "Modem" (the default). Two small programs give the box a modem and a network:

* `webtv_modem.py` (runs on the MiSTer): the Rockwell modem behind the UART, ported from the
  webtv-bridge JS model -- AT commands, TellyScript's `AT**` firmware download, dialing, carrier
  detect (HPS DTR -> the core's DCD). On ATD it opens a TCP connection to the line server and relays
  the online (PPP) data. `--log` also prints the core's debug console, which the core writes into a
  DDR3 ring (read through /dev/mem at 0x30FB0000).

      python3 webtv_modem.py --log --connect LINESERVER_HOST:2323

  `webtv_modem.sh [HOST:PORT]` runs it under a supervisor that restarts it if it exits (log in
  /tmp/modem.log; running it again replaces the running one). It isn't started at boot, since other
  cores use the same UART.

  The box drops DTR when it hangs up, powers off or reboots; the modem then hangs up and returns to
  command mode. (Before this the modem stayed "online" to the old call, the box's next `AT**`
  firmware download went down the line, and the box's watchdog fired: the purple screen.)

  Without `--connect`, dialing answers NO DIALTONE (the box shows "The phone line seems to be in use").

* `lineserver.mjs` (Node, any machine on the LAN): answers each call with the webtv-bridge network
  line (PPP server + IP gateway + the built-in WebTV service). Needs a webtv-bridge checkout:

      node lineserver.mjs --bridge /path/to/webtv-bridge [--port 2323] [--relay ws://host:8081]

  `--relay` points at webtv-bridge's `tools/relay.mjs` for the box's own Internet connections; web
  pages the box requests through the service (http/https) are fetched by the line server itself
  (`--no-web` turns that off). Registrations are kept in `~/.webtv-lineserver.json` (`--store`), so a
  restart doesn't make the box register again.

  `start_net.sh [BRIDGE_DIR]` starts (or restarts) the relay and the line server next to it, each
  restarted if it exits (logs: relay.log, lineserver.log).

Start the core with an MGL that loads it and mounts the disk image in one step, e.g.

    <mistergamedescription>
      <rbf>_Development/WebTV</rbf>
      <file delay="0" type="s" index="0" path="/media/fat/games/WebTV/debug_webtv_w200_7.img"/>
    </mistergamedescription>

The boot ROM goes to games/WebTV/boot.rom. Power button: F1 on the keyboard (or the joystick's Power).

Screens: black = the box is on standby, waiting for Power. Purple = the OS crashed (its watchdog
fired); the debug log (`--log`) shows the registers and what it was doing. Reload the MGL to restart.
