# Linux side (MiSTer HPS) for the WebTV core

The core's hardware-modem UART (16550) is wired to the MiSTer's UART (/dev/ttyS1) when the OSD
"Serial port" is "Modem" (the default). Two small programs give the box a modem and a network:

* `webtv_modem.py` (runs on the MiSTer): the Rockwell modem behind the UART, ported from the
  webtv-bridge JS model -- AT commands, TellyScript's `AT**` firmware download, dialing, carrier
  detect (HPS DTR -> the core's DCD). On ATD it opens a TCP connection to the line server and relays
  the online (PPP) data. `--log` also prints the core's debug console, which the core writes into a
  DDR3 ring (read through /dev/mem at 0x30FB0000).

      python3 webtv_modem.py --log --connect LINESERVER_HOST:2323

  Without `--connect`, dialing answers NO DIALTONE (the box shows "The phone line seems to be in use").

* `lineserver.mjs` (Node, any machine on the LAN): answers each call with the webtv-bridge network
  line (PPP server + IP gateway + the built-in WebTV service). Needs a webtv-bridge checkout:

      node lineserver.mjs --bridge /path/to/webtv-bridge [--port 2323] [--relay ws://host:8081]

  `--relay` points at webtv-bridge's `tools/relay.mjs` for real Internet access (FrogFind etc.).

Start the core with an MGL that loads it and mounts the disk image in one step, e.g.

    <mistergamedescription>
      <rbf>_Development/WebTV</rbf>
      <file delay="0" type="s" index="0" path="/media/fat/games/WebTV/debug_webtv_w200_7.img"/>
    </mistergamedescription>

The boot ROM goes to games/WebTV/boot.rom. Power button: F1 on the keyboard (or the joystick's Power).
