# WebTV Plus (LC2) core for MiSTer — work in progress

An FPGA implementation of the WebTV Plus / LC2 box (IDT R4640 CPU, SOLO1 ASIC, 8 MB RAM) for the
[MiSTer](https://github.com/MiSTer-devel) platform.

Status: simulation-verified, not yet tested on hardware. See [PLAN.md](PLAN.md) for the design notes,
verification results and next steps.

## What is here

- `rtl/cpu` — the R4640 CPU, forked from the N64_MiSTer VR4300 (GPL-3.0, see `rtl/cpu/UPSTREAM.txt`).
- `rtl/webtv` — the LC2 hardware: memory system and DDR3 arbiter, SOLO1 system units (interrupts, timer,
  IIC/NVRAM, serial ID, debug serial), video registers and a cel/framebuffer renderer, IDE disk, IR
  keyboard/remote receiver, the modem's 16550 UART, and the MiSTer glue (`webtv_mister.vhd`).
- `WebTV.sv`, `sys/` — MiSTer top level and framework (`sys/` from Template_MiSTer).
- `sim/` — GHDL testbenches. The golden model is the
  [webtv-bridge](https://github.com/joebritt/webtv-bridge) JS emulator: `sim/trace.mjs` makes instruction
  traces and snapshots, and the CPU + SOLO + IDE run in lock-step against them (`sim/n64cpu/sweep.sh`).

## Using it

Put the boot ROM in `games/WebTV/boot.rom` (or load it from the OSD) and mount a raw WebTV disk image
with "Mount Disk". No ROM or disk images are included.

### Controls

A USB/PS/2 keyboard acts as the WebTV IR keyboard. Letters, digits and punctuation type as usual;
the WebTV function keys are:

| Key | WebTV | | Key | WebTV |
|---|---|---|---|---|
| F1 | Power | | F6 | Info |
| End (numpad 1) | Back | | F7 | Go to (type a URL) |
| Home (numpad 7) | Home | | F8 | Send |
| Enter | Select / Go | | F9 | Save |
| Arrows | Move between links and fields | | F10 | Recent |
| Tab | Next field | | F11 | Options |
| Page Up / Page Down | Scroll up / down | | Insert (numpad 0) | Edit |
| F2 | Favorites | | Left Ctrl | Cmd (Cmd + letter shortcuts) |
| F3 | Search | | | |
| F4 | Mail | | | |
| F5 | Find on page | | | |

F12 opens the MiSTer menu, so the WebTV "View" key (also on F12) is not reachable. In a text field,
Enter moves to the next control (e.g. the "Go to page" button); press it again to activate that.

Joystick: d-pad moves; buttons are Select, Back, Home, Options, Scroll Up, Scroll Down and Power.

The screen is black while the box is on standby: press Power (F1). A solid purple/magenta screen is
the WebTV OS's crash screen. To go online, see [linux/README.md](linux/README.md) and
[linux/DEPLOY.md](linux/DEPLOY.md).
