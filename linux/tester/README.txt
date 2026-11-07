WebTV Plus core for MiSTer -- tester build (November 2026)
=========================================================

This is an early test build of a WebTV Plus (LC2) box running on the MiSTer: the box's CPU
and chips in the FPGA, and its modem, dial-up line and WebTV service running on the MiSTer's
own Linux. It goes online through your MiSTer's network connection. No other computer is needed.

Status: work in progress. The CPU runs at 75 MHz (the real box ran at 167 MHz), so pages are
slower than on real hardware. There is no sound yet.

The boot ROM and disk image in this zip are for testers only. Please don't share them.


WHAT YOU NEED
-------------
* A MiSTer with a network connection (Ethernet or Wi-Fi) for browsing
* A USB keyboard
* About 1.1 GB free on the SD card


INSTALL (once)
--------------
1. Copy the four folders in this zip to the root of your MiSTer's SD card (/media/fat),
   merging them with the folders that are already there:

     _Computer/WebTV_YYYYMMDD.rbf     the core
     _Computer/WebTV Plus.mgl         starts the core with the disk image mounted
     games/WebTV/boot.rom             the box's boot ROM (loaded automatically)
     games/WebTV/webtv_disk.img       the box's hard disk
     linux/webtv/webtv_modem.py       modem + WebTV service (runs on the MiSTer's Linux)
     linux/webtv/webtv_modem.sh       starts/stops it
     linux/webtv/webtv.cfg            its settings
     linux/webtv/pcsample.py          a debugging tool (you can ignore it)
     Scripts/webtv_setup.sh           the one-time setup script
     Scripts/webtv_uninstall.sh       removes all of it again

   The paths have to be exactly these: the .mgl file refers to games/WebTV/webtv_disk.img.

2. On the MiSTer, open the Scripts menu (F12 in the main menu -> Scripts) and run
   "webtv_setup". It adds one line to /media/fat/linux/user-startup.sh so the WebTV service
   starts whenever the MiSTer boots, and starts it now. It should end with
   "WebTV service: running".

   The service only uses the MiSTer's serial port while the WebTV core is loaded, so it doesn't
   bother other cores.


START
-----
1. Main menu -> Computer -> "WebTV Plus" (not "WebTV", which is the core on its own without
   the disk image).
2. The box boots from its disk; this can take up to a minute. A BLACK screen means the box is
   on standby. Press F1 (Power).
3. It "dials" and connects. The first time, it asks for your name and a username (any you
   like: 2 to 16 letters or digits). Then you reach the home page.

Next time it goes straight to the home page after F1.


KEYS
----
  F1                  Power                   F6       Info
  End  (numpad 1)     Back                    F7       Go to (type a web address)
  Home (numpad 7)     Home page               F8       Send
  Enter               Select / Go             F9       Save
  Arrow keys          Move between links      F10      Recent
  Tab                 Next field              F11      Options
  Page Up / Down      Scroll                  Insert   Edit
  F2                  Favorites               Left Ctrl  Cmd (Cmd + letter shortcuts)
  F3                  Search
  F4                  Mail
  F5                  Find on page

F12 opens the MiSTer menu, as usual. To visit a web address, type it in the box on the home
page and press Enter once (a second Enter would click the first link on the new page).
FrogFind, 68k.news and TheOldNet (the web as it was) work best. Modern sites are
cut down for the box (scripts and styles removed, images converted and shrunk); very heavy
pages show "Page too large".

Joystick: d-pad moves; buttons are Select, Back, Home, Options, Scroll Up, Scroll Down, Power.


MENU (F12) OPTIONS
------------------
  Answer Disk Boot prompt    Yes (leave it)
  Serial port                Modem (leave it; "Debug console" is for development)
  Debug overlay              shows the box's debug output on screen instead of the picture
  Data / Instruction cache   On (leave them)
  Reset                      restarts the box (it comes back on standby: press F1)


IF SOMETHING GOES WRONG
-----------------------
* Black screen: the box is on standby. Press F1.
* Solid purple/magenta screen: the box's software crashed. Use Reset in the F12 menu (or load
  WebTV again), then F1.
* "The phone line seems to be in use" / it never connects: the WebTV service isn't running.
  Run Scripts -> webtv_setup again. It should say "running".
* To start completely fresh (as if the box was new), copy games/WebTV/webtv_disk.img from the
  zip again and delete linux/webtv/webtv-accounts.json.


REPORTING BUGS
--------------
Please say what you did and what you saw (a photo of the screen helps), and send the log. The
log is in RAM, so copy it to the SD card before you turn the MiSTer off. Over ssh:

    cp /tmp/webtv_modem.log /media/fat/webtv_modem.log

Then send /media/fat/webtv_modem.log. It has the box's own debug output and every page it
asked for.


UNINSTALL
---------
Run Scripts -> "webtv_uninstall". It stops the service, takes it out of
/media/fat/linux/user-startup.sh and deletes every file listed above, including your
registration and the box's disk image (copy games/WebTV/webtv_disk.img somewhere first if you
want to keep the box as it is).
