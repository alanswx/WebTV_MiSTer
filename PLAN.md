# WebTV Plus (LC2) core for MiSTer — plan

## Target hardware (from LC2 schematics + webtv-bridge emulator)

| Part | What | MiSTer mapping |
|---|---|---|
| CPU | IDT R4640, MIPS III, big-endian, 167 MHz, base/bound (no TLB), MAD/MUL, 32-bit bus at CPU/2 | Soft CPU in fabric (see Risk 1) |
| RAM | 8 MB SDRAM at PA 0x00000000 (mirrored to 0x03ffffff) | SDRAM module (or DDR3 via HPS bridge) |
| Boot ROM | 2 MB at 0x1f800000 (ROMU), ROML unpopulated | DDR3/SDRAM, loaded by HPS from `boot.rom` |
| SOLO1 ASIC | regs at 0x04000000: bus/rom/dev/mem units, interrupts, vidUnit, gfxUnit (cels), potUnit (timing), audUnit DMA, IR, IIC, parallel port, debug serial | Main RTL effort |
| Modem | 16550 UART at 0x1e000000 + Rockwell modem | UART goes to HPS Linux (the "bridge") |
| IDE | cs0 0x1e400000 / cs1 0x1e800000, 1 GB disk, word-swapped | MiSTer HPS-backed IDE (like ao486), mounted `.vhd/.bin` |
| NVRAM/ID | 24C01 EEPROM + DS2401 serial ID on IIC | Small BRAM, saved via MiSTer save mechanism |
| Input | IR remote + Sejin IR keyboard | USB keyboard/gamepad -> IR code injector in RTL |
| Video | NTSC (and PAL) interlaced, YUV 4:2:2 framebuffer + cel compositor | Native 15 kHz out + MiSTer scaler |
| Audio | 16-bit stereo DMA | MiSTer audio |

## Reference sources

- `webtv/` — SOLO1 ASIC spec (full + reduced), LC2 / LC2-W / Pekoe2 schematics, parallel port docs, IR keyboard, Spot programmer model, boot ROMs, INT-W200 disk images.
- `ext/webtv-bridge` — Joe Britt's JS emulator: a complete, readable functional model of the box (≈5.3k lines for CPU + machine). **This is the golden model** for every RTL block.
- wtvemac MAME fork (`src/mame/webtv`) — second reference, especially SOLO video/IR. *(not downloaded yet)*
- zefie minisrv — WebTV service. *(not downloaded yet)*

## Phases

### Phase 0 — Golden reference (Mac, no FPGA)
1. Put `flipped_merged_boot.bin`, `debug_webtv_w200_7.bin` into `ext/webtv-bridge/data/`, `npm start`, boot to Home with the built-in service.
2. Add a trace mode to `tools/run.mjs`: per-instruction PC/regs + every MMIO access, as a file the RTL sim can diff against.
3. Pick the default ROM/OS pair: start with `flipped_merged_boot.bin` + its 1997 debug OS (full debug console = easiest bring-up).

### Phase 1 — CPU
- Base on an existing MIPS III core rather than writing one: the N64 core's VR4300 (MIPS III, already on MiSTer) is the closest; strip TLB, add R4640 base/bound CP0 regs, MAD/MADU/MUL, cache ops/lock as the OS uses them, big-endian only.
- Verilator testbench running the boot ROM against trace from Phase 0 until the first SOLO access diverges.

### Phase 2 — SOLO1 core + memory (Verilator first)
- Bus decoder per `bus.js`; busUnit interrupts; romUnit; memUnit; devUnit (LEDs, IIC NVRAM/serial ID); debug serial -> HPS console.
- IDE: ATA PIO register file backed by MiSTer `hps_io` sector requests.
- Milestone: boot ROM reaches "Disk Boot?", loads OS from disk image into RAM, kernel debug output appears.

### Phase 3 — Video and audio
- potUnit timing (NTSC 525i; HSTART/VSTART offsets as in `solo_video.js`), vidUnit framebuffer DMA, gfxUnit cel/ymap compositor (spec ch. 3 + `solo_cels.js`), YUV->RGB.
- audUnit DMA -> MiSTer audio.
- Milestone: on DE10-Nano, WebTV splash on the TV / scaler.

### Phase 4 — Input
- USB keyboard -> Sejin IR keyboard codes, gamepad -> remote codes, injected at the IR receiver (`ir.js` model).
- OSD: power button, reset, disk image select, ROM select.

### Phase 5 — Networking via the Linux side (the "bridge")
The stock OS dials out through its 16550 modem. On MiSTer we route that UART to the HPS (as ao486/Minimig do), so **no OS patch and no parallel-port dongle trick is needed**.
- Linux daemon `webtv-modem` on the ARM: Hayes AT command set (answer the TellyScript dial with CONNECT), PPP server, and a userspace IP gateway (TCP/DNS) out over MiSTer's Ethernet/WiFi.
- Source for it: webtv-bridge's Pico C firmware already has `pico/src/modem.c`, `ppp.c`, `gw.c`, and a host build (`pico/sim/net_sim.c`) — port that to plain Linux sockets and cross-compile for armv7. Fallback: `pppd` + Linux NAT.
- Service: point at a public WebTV service or minisrv on a PC; optionally run minisrv on the MiSTer (Node on armv7 — heavy, decide later).
- Optional later: the PARMOD parallel-port channel from webtv-bridge for debug console, screenshots and key injection from a browser — on MiSTer the HPS can play the Pico's role directly.

### Phase 6 — Polish
- Speed tuning, save states of NVRAM + disk writes, PAL, MiSTer scaler settings, docs, release.

## Risks
1. **CPU speed.** 167 MHz MIPS III won't close timing on a Cyclone V. VR4300 on MiSTer runs ~94 MHz. The JS emulator isn't cycle-accurate and still runs the OS fine, so ~half speed is probably OK — but CP0 Count/timer and SOLO timers must tick at real-world rates, and caches matter (8 MB in SDRAM with no cache would be far too slow).
2. **Interlaced YUV cel compositor** is the biggest RTL block; budget most of the effort here.
3. **ROM/OS availability.** Builds beyond those on the disk images need the full MSN TV ROM collection (see below).
4. Licensing: webtv-bridge is MIT; MAME webtv driver BSD-3; minisrv GPL-3 (keep separate); N64 core GPL — the core inherits GPL if we reuse it.

## Inventory / missing files
See the chat summary from 2026-11-05; key gaps: Drive export part `-1-001.zip`, and the ROM collection is only part 1 of a split zip.

## Findings from the JS reference (2026-11-05)

Setup: `ext/webtv-bridge/data/` links to `webtv/extracted/WebTV/*` and `webtv/rom-collection/` (LC2 set carved from the ROM collection part: 178 OS builds, boot ROMs 2046/2205 + others).
`node tools/run.mjs --cycles 9000000000 --answer 'Disk Boot?=y' --net builtin --press 1600000000:power --png out/t9.png` boots flipped_merged_boot + debug_webtv_w200_7 to the registration page at ~224 MIPS.

`sim/profile.mjs` (interpreter, 3.5 G instructions: power-on -> Power -> dialing) -> `sim/out/profile.txt`:
- **87 distinct ops.** Plain MIPS II integer core dominates. 64-bit ops present but rare except `daddu` (2.3%, compiler `move`); `dsll32/dsra32/ddiv` ~1k each -> keep 64-bit GPRs (as VR4300 has).
- **R4640 extras:** `mul` (SPECIAL2) 14.9M -> required. `mad/madu` not seen. `wait` used for idle.
- **FPU:** `lwc1/swc1` 35M each (likely FP-register memcpy/context save) but FP arithmetic only a few thousand single-precision ops (add/mul/div/cvt/trunc/c.eq.s). -> need FPR file + loads/stores at speed; arithmetic can be a small slow multi-cycle unit. No double precision seen.
- **CP0:** Count read 58M times (busy-wait timing -> Count must tick at true 83.5 MHz-equivalent rate, half CPU clock), Status/Cause/EPC/Compare, PRId/Config, R4640 IBase/IBound/DBase/DBound ($0-$3), CAlg ($17), TagLo/TagHi ($28/$29).
- **CACHE ops** 0/1/8/9/16/20/21 (index invalidate / writeback, index store tag, hit invalidate, hit writeback) -> real I/D caches needed (also for performance).
- **MMIO:** 157 distinct registers touched: 141 SOLO, 9 IDE, 7 modem UART.

## Status / how to run (2026-11-05)

Layout:
- `rtl/cpu/` — fork of N64_MiSTer's VR4300 CPU (GPL-3, upstream rev in `UPSTREAM.txt`). WebTV changes are marked `-- WebTV:`.
- `sim/trace.mjs` — JS reference trace (`--from N --count M [--snapshot DIR] [--rom F --disk none]`); lines carry `IRQ` (interrupt taken after this instruction) and `IRQL=` (external line state).
- `sim/profile.mjs`, `sim/segments.mjs`, `sim/milestones.mjs` — usage studies of the JS run.
- `sim/n64cpu/` — GHDL lock-step testbench (`tb_cpu.vhd`, behavioral altera_mf models):
  - `build.sh` (B=dir for a separate build), `run.sh N` (from reset vs the 2M boot trace),
  - `run_snap.sh FROM N` (JS snapshot at FROM -> RTL window of N instructions, MMIO + IRQ replay),
  - `sweep.sh N` (windows across the whole boot in parallel), `test_rom.sh ROM N` (hand-made test ROMs in `sim/tests/`).
- `sim/compare.py REF RTL [--snap ss.txt]` — first-divergence finder.

Test modes in the CPU (ports default off): `LOCKSTEP_COUNT` (Count = issued instructions / 2, like the JS model) and
`IRQ_REPLAY` + `irqReplayAt` (an interrupt preempts exactly the instruction with that issue number; normal IRQ timing off).

R4640 changes so far (rtl/cpu):
1. PRId = 0x2200.
2. CP0 0-3 = IBase/IBound/DBase/DBound storage; 16 = R4640 Config (reset 0x00026030); 17 = CAlg; 18/19 = IWatch/DWatch.
3. CACHE op 0x14 (Fill I) accepted, implemented as Hit Invalidate I.
4. Cause.IV (bit 23, reset 1 like the JS model) and the +0x200 interrupt vector (combinational vector select).
5. SPECIAL2: MUL (rd, HI/LO untouched), MAD, MADU.
6. Kernel mode never maps (no TLB): kseg0 cached, kuseg/kseg2/kseg3 uncached (OS only uses kernel mode; kseg2 is write-through in its CAlg).
7. Removed the N64 "first Count write" RDRAM hack.
8. Caches in R4640 geometry: I 8 KB and D 8 KB, both 32-byte lines (VR4300 had I 16 KB / D 16-byte lines), direct mapped.
   Real R4640 Config (MAME: 0x00026030 | IC=1 | DC=1) reports 8 KB + 8 KB; the OS does ~46 full index flushes and
   steps hit-writebacks by the Config line size, so size and line must match or code/DMA data goes stale.
   (The JS model reports 0x00026030 = 4 KB; the lock-step testbench uses that value.)

Memory system (rtl/webtv):
- `webtv_memmux.vhd` (clk1x): CPU requests -> RAM (8 MB, DDR3 offset 0), boot ROM (2 MB, DDR3 offset 8 MB, writes
  dropped) or a 32-bit big-endian MMIO bus (bus_addr/read/write/be/dataWrite/dataRead/done) for SOLO/modem/IDE.
- `webtv_ddr3mux.vhd` (clk2x): N-client DDR3 arbiter (CPU, video DMA, audio DMA, HPS), MiSTer ddr3 port, window at
  0x30000000. Byte order in DDR3 = address order (same as the HPS), so ROM/disk images load unswapped.
- Testbench now uses both plus a DDR3 model (latency/BUSY knobs: -gddr3_latency, -gddr3_busy_pct) and an MMIO bus
  model. Boot ROM, MUL ROM, 30%-BUSY stress all match.
- `webtv_core.vhd`: top level of the core so far = cpu + memmux + ddr3mux + bustick. Ports: MiSTer ddr3, the MMIO
  bus (+ bus_tick for the SOLO), irqRequest, an HPS loader DDR3 client (lowest priority; the DDR3 mux has its own
  reset_mem so the HPS can load while the CPU is held in reset), savestate port, test ports (lockstep/IRQ replay/export).
  tb_cpu instantiates it; `-ghps_load=true` writes the boot ROM through the HPS port first (2 MB in 38 ms sim time).
- Performance: IPC ~0.85 on OS code (insensitive to DDR3 latency 12..30) -> ~80 MIPS at 93.75 MHz.

Open on the CPU side:
- Count rate: DONE. `rtl/webtv/webtv_bustick.vhd` makes an 83.58 MHz-average tick (fractional accumulator, 2 ppm)
  on clk93; with COUNT_EXTERNAL='1' the CPU's Count advances on it, and the SOLO's TCOUNT (same bus-clock counter
  in the JS model) must use the same tick. Verified with sim/tests/count.rom (0.8914 counts/cycle, expected 0.8916).
- CAlg-driven cacheability (only matters if software uses kuseg or changes CAlg; the OS sets 0x21233333 once).

Verified in lock-step with the JS model:
- boot ROM from reset: 2,000,000 instructions;
- OS from a snapshot at 67.0M: 990,000 instructions (Count reads);
- OS from 108.6M: 395,000 instructions incl. the first 4 interrupts (IV vector, handler, eret);
- MUL/MAD/MADU test ROM.
Sim speed ~4-5k instr/s per process.

SOLO system units: `rtl/webtv/webtv_solo_sys.vhd` (in webtv_core) = busUnit (interrupt fabric with all
groups, error/fence regs, TCOUNT/TCOMPARE timer, reset cause, watchdog arm), romUnit, devUnit (LED, DS2401 serial
id, IIC pin register, GPIO), memUnit, sucUnit (debug serial TX/RX). IIC bus devices: `rtl/webtv/webtv_iic.vhd` (24C01 NVRAM + 4 register-file
chips, bit-for-bit as the JS I2cBus; snapshots add iic.txt). IR, parallel port, video and audio units stay on the
external MMIO bus for now. 108.6M window: all 636 bit-banged IIC reads come from RTL and match. TCOUNT is a half-tick counter on clk93: +2 per bus_tick, or +1 per
instruction in lock-step mode (JS: TCOUNT = cycles / 2); the timer fires at the exact point the JS event does.
Verification: trace.mjs snapshots now also write solo.txt (raw SOLO state) and trace lines carry `S:k=v` for SOLO
interrupt state changes. The testbench loads solo.txt, forces the state owned by units not yet in RTL (gpio/aud/
dev/vid/rio status, vid enables, BUS_INTEN, modem7e), checks every read the RTL SOLO answers against the JS value,
and compares the SOLO irq output with the JS IRQ line. From reset (2M) and 108.6M (395k): 0 read / 0 irq mismatches.
JS reference bugs found (patched at load time in sim/jsfix.mjs, not in the ext/ clone; to report upstream):
- MipsCpu.updateCause() never clears Cause.IP7 (only IP6..2), so after the first timer interrupt every later
  interrupt also looks like a timer tick to the OS dispatcher; R4640 clears IP7 on a Compare write.
Tool fixes: trace.mjs must process.exit() (the network service keeps the event loop alive: looked like a hang);
IRQ replay targets shift by one per earlier interrupt (preempted instruction issues twice in the RTL).
IRQ_REPLAY now squashes the preempted instruction in stage 3 exactly like the executeIgnoreNext path (a real
interrupt squashes it in decode): before, a preempted load/store still did its memory access and register write
(found at 2.0G/3.0G: a preempted lb clobbered r2 before the handler saved it). The preempted instruction no
longer exports, so the testbench's export skipping is gone.
Snapshots now carry video unit state too (vid.txt); Cause is saved via updateCause() (current IP bits).
The renderer is in webtv_core (DDR3 client VIDEO, started at vblank, double-buffered at FB_BASE0/1 = 12/14 MB in
the window, fb_display/fb_frame outputs for scanout) and runs during the lock-step simulations.
Fix found on the way: snapshot restore of Cause did not restore the latched IP7/IP1:0 (2.0G/2.5G windows started
with the timer interrupt already pending).

Video (rtl/webtv/webtv_solo_vid.vhd): vid/gfx/dve/div/pot register file with the JS semantics (address masks,
set/clear aliases, sub-unit interrupts, enable side effects into BUS_VIDINTEN/BUS_INTEN), display timing like both
emulators (progressive 640x480 frame; here 800x525 VGA timing from a 25.175 MHz pixel enable): POT_CLINE = line,
VSYNCO at vblank, HSYNC at POT_HINTLINE, vid DMA interrupt per frame. The JS model times video in CPU cycles, so in
lock-step the testbench replays the timing-dependent reads (CLINE, POT/VID intstat, cstart/csize/ccnt) and forces
the vid summary; everything else (incl. BUS_INTEN / vid enables, no longer forced) is checked.
Frame renderer (rtl/webtv/webtv_gfx_render.vhd): DONE functionally. Same algorithm as JS drawCels/render in exact
integer arithmetic (8.8 / 10.10 fixed point, /219 and /255 exact), first pass builds the cel table (incl. data-load
cels and the per-band data[] carry-over), then row by row into a line buffer, written to a 32-bit RGB framebuffer.
Checked with sim/n64cpu/render_test.sh against JS frames (sim/frame.mjs: 300M vid mode, 3.0G "Connecting", 6.0G
registration page) and 40 random scenes from sim/celfuzz.mjs (all texture/alpha types, scaled/sloped/masked cels,
loads): all pixel-exact. Speed: 624k clk1x cycles for an OS frame (~10 ms at 62.5 MHz: 60 Hz OK) with a
32 x 32-byte read cache filled by 4-beat bursts (captured on clk2x), 3 states per pixel pair, and a second DDR3
client (DDR3_FBW) writing the finished row while the next is composed. Still sim-shaped: line buffers and their
one-cycle init/copy must become block RAM accesses for synthesis.
Synthesis shape (DONE): cel table and two ping-pong line buffers (even/odd banks, 320 x 24 each) are M10K
(rtl/webtv/webtv_sdpram.vhd, registered read); a 640-bit "written" flag per buffer replaces the row clear (an
unwritten pixel reads as its row-start value); texel cache data is MLAB (RamMLAB, async read, write port fed
straight from the DDR3 beats). Still pixel-exact on the 3 OS frames and 40 fuzz scenes; 718k cycles a frame
(~11.5 ms). The per-pixel blend arithmetic (2 pixels/cycle, div255 multiplies) is the likely timing hot spot.
Sweep on b15 (CPU + SOLO sys/IIC/video + renderer in the core): all 10 windows 108.6M..3.0G match, 0 SOLO read /
irq mismatches.
Original plan: a frame renderer that runs the JS/MAME drawCels algorithm (and the 4:2:2 framebuffer
conversion) once per frame into an RGB framebuffer in DDR3 (a frame time = ~200 clocks per pixel, enough for
uncached texel fetches), double-buffered and flipped at vblank; HDMI through the MiSTer scaler's framebuffer mode,
analog later with a line-buffer scanout. Verified standalone: RAM snapshot + gfx registers -> image, compared with
the JS frame.

Sweep (sweep.sh, 200k instructions per window from JS snapshots): 150M, 300M, 500M, 800M, 1.2G, 1.65G match.
2.0G found a late timer IP7 in lock-step Count (fixed); 2.5G/3.0G needed relative instruction indices (fixed).

MiSTer project (DONE, not yet synthesized -- no Quartus on this machine): sys/ is the latest Template_MiSTer
(github MiSTer-devel/Template_MiSTer e901a9f, 2026-11-03); WebTV.qpf/.qsf/.sdc, files.qip, rtl/webtv.qip, PLL from
N64_MiSTer (rtl/pll: 62.5 / 93.75 / 125 MHz). WebTV.sv (emu) = hps_io (WIDE, ROM download index 0 = boot.rom,
disk image S0, ps2_key, joystick) + rtl/webtv/webtv_mister.vhd:
- boot ROM download -> DDR3 at 8 MB through the HPS client (ioctl_wait while each 64-bit word is written);
- 8 MB RAM clear, then the CPU start sequence (SS_reset, Status/Config/Compare reset values), as tb_cpu does;
- SOLO software reset (RESETCAUSE) restarts the CPU (no reload / clear);
- debug serial <-> UART pins at 115200 8N1 (64-byte TX FIFO), auto-answer 'y' to "Disk Boot?" (OSD option);
- PS/2 keyboard (set 2 -> Sejin scancodes, irkeys.js KEY_MAP) and joystick (arrows, select, back, home, options,
  scroll, power) -> IR keyboard events;
- video: MISTER_FB framebuffer mode (FB_FORMAT 32bpp RGB, 640x480, stride 2560, base 0x30000000 + fb_display); the
  core's own VGA output carries only timing (black) until a scanout path exists (analog out).
- MMIO units not in RTL yet (parallel port, audio, modem) read 0.
Checked: sim/n64cpu/tb_mister.vhd (ROM download over ioctl, DDR3 model, UART decoder): ROM image and RAM clear
verified word for word, CPU runs, frames rendered and flipped; WebTV.sv lint-clean in verilator (stubs).
The JS model prints its first debug line at ~80M instructions and loads the OS from the IDE disk, so a real
boot needs the disk:
IDE (rtl/webtv/webtv_ide.vhd, DONE): ATA PIO as the JS IdeDisk (all its commands, CHS/LBA with a 32-step divider
for setLba, IDENTIFY, READ/WRITE (MULTIPLE), security data blocks), 16-sector buffer (M10K), backed by the hps_io
block device (S0). RIO interrupt device 1 with set/clear/level into the SOLO. Busy time: 2000 instructions in
lock-step (JS sched.after), else until the HPS has moved the data. The OS reads ~8200 single sectors (0x20, CHS)
between 100M and 150M instructions; no writes before 3G.
Lock-step: snapshots add ide.txt (registers, buffer, a read in progress) and disk.txt (every sector the window
reads, served by the testbench's sd_* model). To time the busy period like JS, an uncached store now waits for its
bus write in lock-step mode (the CPU's posted write FIFO made the IDE see the command ~27 instructions late);
outside lock-step stores stay posted.
Sweep with the IDE in RTL: 15 windows (108.6M, 110M, 115M, 125M, 140M, 150M, 200M ... 3.0G) all match, 0 SOLO /
IDE read and 0 irq mismatches.
IR (rtl/webtv/webtv_ir.vhd, DONE for hardware): devUnit IR receiver + Sejin keyboard as the JS SoloIr: key events ->
22-bit packets -> runs on a 15 us tick, TRANS_DATA reads, 60 Hz DEV_INT_IRIN poll, 2047-tick idle runs, 20 ms
packet spacing. sim/ir: irref.mjs (JS model, 20 key events, read every 1 ms) vs tb_ir.vhd: identical level/ticks
sequence (260 runs); the ready count differs at a few reads by the RTL's tick quantization (<= 15 us). In
lock-step runs the IR addresses stay on the replayed MMIO bus (JS key presses can't be injected at exact
instruction counts).

Modem UART (rtl/webtv/webtv_uart16550.vhd, DONE): 16550 at 0x1E000000 with the JS register semantics, RIO device
0 interrupt, modem7e flag on a 0x7E data read. Line side = real 8N1 serial (2 KB TX FIFO with THRE flow control,
256-byte RX FIFO with RTS), DSR/CTS on, DCD from an input. sim/ir/uartref.mjs vs tb_uart.vhd: 408 random register
ops / received bytes / carrier changes, every read value and the interrupt line identical. On MiSTer the OSD
"Serial port" picks the debug console (default) or the modem line on the UART pins (to the HPS, where the AT/PPP
side has to run; carrier detect = HPS DTR via UART_DSR). Lock-step: replayed like the IR.

Hardware bring-up (2026-11-06, mister192, Quartus 17.0 Lite on misterubuntu):
- Builds and fits (62% ALMs, 85/112 DSP after replacing div255 / yexp / blend multiplies; IIC memories moved to
  block RAM; renderer pixel path now a 6-stage pipeline, cel setup and geometry split over states).
- Timing: at 62.5/93.75/125 MHz the CPU misses by ~2 ns (forwarding -> stall paths in the N64-derived pipeline;
  seeds don't help). A WEBTV_SLOW build (qsf VERILOG_MACRO, PLL 50/75/100 MHz) meets timing and is what boots.
- Bring-up tools: OSD "Debug overlay" (bit boxes: status, sticky errors, instruction count, PC, debug-serial
  count, frames, LED, IDE state, boot-ROM exception dump), a branch trace (last 1024 non-sequential PCs) frozen on
  the boot ROM's exception vector and dumped to DDR3 0x30FA0000, RAM / framebuffer readable from Linux through
  /dev/mem mmap at 0x30000000, debug serial captured on the HPS /dev/ttyS1, MGL to load core + disk image.
- Bugs found on hardware (none visible in lock-step, which starts from JS snapshots):
  1. 16550 address decode compared slices of different lengths (always false).
  2. R4640 Config was loaded into the wrong half of SS slot 16, and mtc0 could overwrite the cache geometry
     (now read-only outside lock-step): the ROM sized its cache flushes for 4 KB.
  3. CPU write FIFO 8 deep could overflow with 4-beat D-cache writebacks (now 16).
  4. mtc0 Status (CU1) followed by ctc1 one instruction later trapped "FPU unusable": the decode-stage CU1
     check now forwards a Status write in flight (the OS entry code does exactly this).
  5. IDE: MiSTer mounts the image after the core starts and hps_io delivers img_size after img_mounted: the
     drive now follows img_size after a mount and comes up ready; the CPU start waits up to 3 s for a mount.
  6. "Spurious interrupt": the CPU commits to an interrupt at decode and keeps it after the line drops (the OS
     IDE driver polls status, which clears the drive's interrupt, right after a command). Outside lock-step the
     RIO status bits now stay latched until software clears them (as the chip does).
  7. SOLO state now goes back to power-up on an OSD/power reset (cold_reset); the debug TX FIFO is 1 KB.
- Status: the boot ROM loads the browser image from the disk, the disk OS boots (FAT volumes, tasks, NV memory,
  TellyScript). It stops at TellyScript's modem handshake ("Watchpup fired"): nothing answers on the modem
  UART. JS answers there with its Modem class (AT commands, TellyScript "NULL loader" download).

Next:
- Modem side: answer TellyScript / AT commands (Linux-side bridge on the HPS UART, or a minimal responder).
- CPU timing at 93.75 MHz (forwarding/stall paths) so the full-speed build can be used.
- Quartus build (needs a machine with Quartus 17): fit/timing; expect work on the renderer's blend path and the
  CPU at 93.75 MHz (the N64 core's CPU met timing there).
- Linux side of the modem: AT commands + PPP + gateway on the HPS (webtv-bridge pico/src modem.c/ppp.c/gw.c or
  src/machine/modem.js + src/net), talking to the core's UART.
- Audio unit (DMA + sample output), parallel port, analog video scanout.
- SOLO/video unit reset on a software reset (JS doReset resets them; the RTL keeps their state).
- Base/bound for user mode and CAlg cacheability (unused by the OS so far).
