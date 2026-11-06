// Golden-reference instruction trace from the webtv-bridge JS emulator, for lock-step
// comparison with the RTL CPU.
//
// usage: node sim/trace.mjs [--from N] [--count M] [--out FILE.gz] [--rom F] [--disk F]
//                           [--power-at N] [--snapshot DIR]
//
// One line per retired instruction (hex unless noted):
//   <idx> <pc32> <op32> [r<n>=<64>] [hi=<64>] [lo=<64>] [c0_<n>=<32>] [f<n>=<32>] [fcsr=<32>]
//         [MR:<pa>/<size>=<val>] [MW:<pa>/<size>=<val>] [S:<k>=<val>]
// <idx> is decimal (instructions executed since reset). Register fields show the values
// *after* the instruction; only changed registers are listed. MR/MW are MMIO accesses (RAM
// and ROM accesses are not listed). An instruction that took an exception/interrupt shows
// the CP0 changes (Status/Cause/EPC) and the next line starts at the vector.
// S:<k>=<val> is SOLO interrupt state after the instruction, when it changed: g/a/d/v/r = gpio/
// aud/dev/vid/rio group status, V = vid enables, B = BUS_INTEN, t = timer status, m = modem7e.
// The testbench forces the ones owned by units that are not in RTL yet.
//
// --from N starts tracing at instruction N (fast JIT up to there) and, with --snapshot DIR,
// writes the machine state at that point (regs.txt + ram.bin) so a testbench can start there.
import { readFileSync, openSync, readSync, fstatSync, writeFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { gzipSync } from 'node:zlib';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const BR = join(HERE, '../ext/webtv-bridge');
const { applyJsFixes } = await import(join(HERE, 'jsfix.mjs'));
await applyJsFixes(BR);
const { WebTV } = await import(join(BR, 'src/machine/webtv.js'));
const { OverlayDisk } = await import(join(BR, 'src/machine/ide.js'));
const { createNetworkLine } = await import(join(BR, 'src/net/line.js'));
const { WebTVService } = await import(join(BR, 'src/wtvsrv/service.js'));

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };
const from = Number(opt('from', '0'));
const count = Number(opt('count', '1000000'));
const outFile = opt('out', join(HERE, 'out', `trace_${from}_${count}.txt.gz`));
const snapDir = opt('snapshot', null);
const powerAt = Number(opt('power-at', '1600000000'));
mkdirSync(dirname(outFile), { recursive: true });

const rom = readFileSync(opt('rom', join(BR, 'data/flipped_merged_boot.bin')));
const diskPath = opt('disk', join(BR, 'data/debug_webtv_w200_7.bin'));
let disk = null;
if (diskPath !== 'none') {
  const fd = openSync(diskPath, 'r');
  disk = new OverlayDisk(fstatSync(fd).size, (lba, n) => { const b = new Uint8Array(n * 512); readSync(fd, b, 0, b.length, lba * 512); return b; });
}

const quiet = () => {};
const m = new WebTV({ rom, disk, log: quiet });
let line = '';
m.solo.debugOut = (c) => {
  if (c === 10) { process.stderr.write(`[dbg] ${line}\n`); line = ''; } else if (c !== 13) line += String.fromCharCode(c);
  if (line.endsWith('Disk Boot?')) m.solo.debugInput('y'.charCodeAt(0));
};
m.modemLine.line = createNetworkLine({ relayUrl: null, service: new WebTVService({ log: quiet }), hostMap: {}, log: quiet });
m.sched.at('power', powerAt, () => m.ir.pressButton('power'));

const cpu = m.cpu;
const h8 = (v) => (v >>> 0).toString(16).padStart(8, '0');
const h16 = (hi, lo) => h8(hi) + h8(lo);

// previous architectural state, for diffs
const pL = new Int32Array(32), pH = new Int32Array(32), pC0 = new Int32Array(32), pF = new Int32Array(32);
let pHiL = 0, pHiH = 0, pLoL = 0, pLoH = 0, pFcsr = 0;
const so = m.solo;
const soloKeys = () => [['g', so.gpioInt.stat], ['a', so.audInt.stat], ['d', so.devInt.stat], ['v', so.vidInt.stat],
  ['r', so.rioInt.stat], ['V', so.vidInt.en], ['B', so.busEn], ['t', so.timInt.stat], ['m', so.modem7e ? 1 : 0]];
let pSolo = soloKeys().map(([, v]) => v >>> 0);
const snap = () => {
  pSolo = soloKeys().map(([, v]) => v >>> 0);
  pL.set(cpu.gprL); pH.set(cpu.gprH); pC0.set(cpu.cp0); pF.set(cpu.fpr);
  pHiL = cpu.hiL; pHiH = cpu.hiH; pLoL = cpu.loL; pLoH = cpu.loH; pFcsr = cpu.fcr31;
};

let chunk = [];
let chunkLen = 0;
let written = 0;
const flush = () => {
  if (!chunk.length) return;
  appendFileSync(outFile, gzipSync(chunk.join('')));
  chunk = []; chunkLen = 0;
};
let cur = null;     // line being built for the instruction in flight
let mmio = '';
let traced = 0;
let lastIrql = -1;  // forces an IRQL= on the first traced line
let done = false;

const finishPrev = (nextPc) => {
  if (cur === null) return;
  let s = cur;
  // interrupt taken between this instruction and the next: EXL rose with ExcCode 0
  // (and the next instruction is an exception vector: an mtc0 to Status can also set EXL)
  const vec = nextPc === undefined ? 0 : (nextPc >>> 0);
  const atVector = vec === 0x80000180 || vec === 0x80000200 || vec === 0xbfc00380 || vec === 0xbfc00400;
  if (atVector && !(pC0[12] & 2) && (cpu.cp0[12] & 2) && ((cpu.cp0[13] >>> 2) & 31) === 0) s += ' IRQ';
  const L = cpu.gprL, H = cpu.gprH;
  for (let r = 1; r < 32; r++) if (L[r] !== pL[r] || H[r] !== pH[r]) s += ` r${r}=${h16(H[r], L[r])}`;
  if (cpu.hiL !== pHiL || cpu.hiH !== pHiH) s += ` hi=${h16(cpu.hiH, cpu.hiL)}`;
  if (cpu.loL !== pLoL || cpu.loH !== pLoH) s += ` lo=${h16(cpu.loH, cpu.loL)}`;
  // Count (9) changes every other cycle; it is only reported when written (mtc0) or read
  for (let r = 0; r < 32; r++) if (r !== 9 && cpu.cp0[r] !== pC0[r]) s += ` c0_${r}=${h8(cpu.cp0[r])}`;
  for (let r = 0; r < 32; r++) if (cpu.fpr[r] !== pF[r]) s += ` f${r}=${h8(cpu.fpr[r])}`;
  if (cpu.fcr31 !== pFcsr) s += ` fcsr=${h8(cpu.fcr31)}`;
  s += mmio;
  soloKeys().forEach(([k, v], i) => { if ((v >>> 0) !== pSolo[i]) s += ` S:${k}=${(v >>> 0).toString(16)}`; });
  s += '\n';
  chunk.push(s); chunkLen += s.length;
  if (chunkLen > (4 << 20)) flush();
  written++;
  cur = null; mmio = '';
  snap();
};

const hook = (pc, op) => {
  finishPrev(pc);
  if (traced >= count) { done = true; cpu.stopRequested = true; return; }
  cur = `${cpu.cycles - 1} ${h8(pc)} ${h8(op)}`;
  // external interrupt lines (bit0 = IP2) as seen before this instruction runs
  if (cpu.irqLines !== lastIrql) { cur += ` IRQL=${cpu.irqLines.toString(16)}`; lastIrql = cpu.irqLines; }
  // mfc0 Count: record the value the reference returned so a testbench can inject it
  if ((op >>> 21) === (0x10 << 5) && ((op >>> 11) & 31) === 9) cur += ` count=${h8(cpu.getCount())}`;
  traced++;
};
m.bus.watch = (pa, size, isWrite, v) => {
  if (cur !== null) mmio += ` ${isWrite ? 'MW' : 'MR'}:${h8(pa)}/${size}=${(v >>> 0).toString(16)}`;
};

// Snapshot of the state *before* the instruction at `pc` executes (called from the trace hook,
// where cpu.cycles already counts that instruction). ss.txt holds "<slot> <hex64>" savestate
// writes for the RTL testbench (N64_MiSTer CPU slot numbering; CP0 at 64+n).
const writeSnapshot = (pc) => {
  mkdirSync(snapDir, { recursive: true });
  const c0 = cpu.cp0;
  const rel = cpu.cycles - 1 - cpu.countBase;
  const count = (cpu.countOffset + Math.floor(rel / 2)) >>> 0, frac = rel & 1;
  const sx = (v) => ((v | 0) < 0 ? 'ffffffff' : '00000000') + h8(v);
  const ss = [];
  ss.push([0, sx(pc)]);
  ss.push([3, h16(cpu.hiH, cpu.hiL)], [4, h16(cpu.loH, cpu.loL)]);
  for (let r = 0; r < 32; r++) ss.push([32 + r, h16(cpu.gprH[r], cpu.gprL[r])]);
  for (let k = 0; k < 32; k += 2) ss.push([96 + k, h8(cpu.fpr[k + 1]) + h8(cpu.fpr[k])]);
  ss.push([24, h8((cpu.fcr31 >>> 23) & 1) + h8(cpu.fcr31 & 0x1ffffff)]);
  for (let r = 0; r < 4; r++) ss.push([64 + r, h8(0) + h8(c0[r])]);           // R4640 base/bound
  ss.push([64 + 9, h8(frac) + h8(count)]);
  ss.push([64 + 11, h8(0) + h8(c0[11])]);
  ss.push([64 + 12, h8(0) + h8(c0[12])]);
  ss.push([64 + 13, h8(0) + h8(cpu.updateCause())]);   // current IP bits (the stored Cause can be stale)
  ss.push([64 + 14, sx(c0[14])]);
  ss.push([64 + 16, h8(c0[16]) + h8(3)]);                                     // R4640 Config | internal K0=3
  ss.push([64 + 17, h8(0) + h8(c0[17])]);                                     // CAlg
  writeFileSync(join(snapDir, 'ss.txt'), ss.map(([k, v]) => `${k} ${v}`).join('\n') + '\n');
  let s = `cycles ${cpu.cycles - 1}\npc ${h8(pc)}\ncount ${h8(count)} frac ${frac}\n`;
  writeFileSync(join(snapDir, 'info.txt'), s);
  // SOLO system-unit state, as raw loads for webtv_solo_sys init_* ("<offset> <value>" hex)
  const ev = m.sched.events.find((e) => e.name === 'solo-timer');
  const sl = [
    [0x0004, so.chpcntl], [0x0008, so.busStatSoft], [0x000c, so.busEn], [0x0010, so.errStat], [0x0014, so.errEnable],
    ...[0, 1, 2, 3, 4].map((i) => [0x1c + 4 * i, so.fence[i]]), [0x0030, so.wdValue],
    [0x0034, so.lowRd[0]], [0x0038, so.lowRd[1]], [0x003c, so.lowWr[0]], [0x0040, so.lowWr[1]],
    [0x0048, cpu.cycles - 1], [0x004c, so.tcompare],
    [0x0050, (ev ? (ev.time & 1) | 2 : 0) | (so.wdEnable ? 4 : 0)],
    [0x0058, so.gpioInt.stat], [0x005c, so.gpioInt.en], [0x0064, so.gpioPol],
    [0x0068, so.audInt.stat], [0x0070, so.audInt.en], [0x0074, so.devInt.stat], [0x007c, so.devInt.en],
    [0x0080, so.vidInt.stat], [0x0088, so.vidInt.en], [0x008c, so.rioInt.stat], [0x0094, so.rioPol || 0],
    [0x0098, so.rioInt.en], [0x009c, so.timInt.stat], [0x00a4, so.timInt.en], [0x00a8, so.resetCause],
    ...[0, 1, 2, 3].map((i) => [0xb0 + 4 * i, so.jfence[i]]), [0x00c8, so.bootMode], [0x00cc, so.useBootMode],
    [0x1004, so.romCntl0], [0x1008, so.romCntl1], [0x4004, so.led],
    [0x4008, so.idCntl | (so.idState << 4) | (so.idBit << 8) | (so.idBitIdx << 16)], [0x400c, so.nvCntl],
    [0x4014, so.gpioOut], [0x4018, so.gpioEn],
    [0x5000, so.memCntl], [0x5004, so.memRefCnt], [0x5008, so.memData], [0x500c, so.memCmd], [0x5010, so.memTiming],
  ];
  // video units (webtv_solo_vid init_*): register offsets as read
  {
    const vd = m.solo.video, V = vd.vid, G = vd.gfx, P = vd.pot, Dv = vd.div;
    const vl = [
      [0x3000, V.cstart], [0x3004, V.csize], [0x3008, V.ccnt], [0x300c, V.nstart], [0x3010, V.nsize], [0x3014, V.dmacntl],
      [0x3038, V.intstat], [0x303c, V.inten], [0x3040, V.vdata],
      [0x6004, G.cntl], [0x6010, G.ootYcount], [0x6014, G.celsBase], [0x6018, G.ymapBase], [0x601c, G.celsBaseMaster],
      [0x6020, G.ymapBaseMaster], [0x6024, G.initColor], [0x6028, G.ycounterInit], [0x602c, G.pauseCycles],
      [0x6030, G.ootCelsBase], [0x6034, G.ootYmapBase], [0x6038, G.ootCelsOffset], [0x603c, G.ootYmapCount],
      [0x6040, G.termCycleCount], [0x6044, G.hcounterInit], [0x6048, G.blankLines], [0x604c, G.activeLines],
      [0x6060, G.inten], [0x6068, G.intstat], [0x6080, G.wbdStart], [0x6084, G.wbdLsize], [0x608c, G.wbStride], [0x6090, G.wbdConfig],
      [0x9080, P.vstart], [0x9084, P.vsize], [0x9088, P.blankColor], [0x908c, P.hstart], [0x9090, P.hsize], [0x9094, P.cntl],
      [0x9098, P.hintline], [0x909c, P.inten], [0x90a0, P.intstat],
      [0x8064, Dv.gpioOutMask], [0x8068, Dv.gpioOut], [0x8070, Dv.inten], [0x8078, Dv.intstat],
      ...Array.from({ length: 0x40 / 4 }, (_, i) => [0x8000 + 4 * i, Dv.regs[i]]),
      ...[...vd.dve.entries()].map(([o, x]) => [o, x]),
    ];
    writeFileSync(join(snapDir, 'vid.txt'), vl.map(([o, x]) => `${o.toString(16).padStart(4, '0')} ${h8(x)}`).join('\n') + '\n');
  }
  // IIC bus + devices (webtv_iic init_*)
  const bus = m.i2c, ST = { idle: 0, addr: 1, write: 2, read: 3, mack: 4, sack: 5, nack: 6 };
  const devs = [[0x50, 1], [0x44, 2], [0x46, 3], [0x5b, 4], [0x61, 5]].map(([a, i]) => [bus.devices.get(a), i]);
  const di = (d) => { const e = devs.find(([o]) => o === d); return e ? e[1] : 0; };
  const il = [
    [0x0000, (bus.scl & 1) | ((bus.sdaMaster & 1) << 1) | ((bus.sdaSlave & 1) << 2) | (ST[bus.state] << 4) |
      ((bus.bits & 0xff) << 8) | ((bus.nbits & 15) << 16) | (di(bus.dev) << 20) | (bus.reading ? 1 << 23 : 0) | ((bus.outByte & 0xff) << 24)],
    [0x0001, (ST[bus.next] || 0) | (bus.masterNack ? 8 : 0)],
    ...devs.map(([d, i]) => [0x10 + i, (d.ptr & 0xff) | (d.gotPtr ? 0x100 : 0)]),
  ];
  devs.forEach(([d, i]) => d.mem.forEach((b, k) => il.push([0x1000 + (i === 1 ? 0 : 128 + (i - 2) * 256) + k, b])));
  writeFileSync(join(snapDir, 'iic.txt'), il.map(([o, v]) => `${o.toString(16).padStart(4, '0')} ${h8(v)}`).join('\n') + '\n');
  writeFileSync(join(snapDir, 'solo.txt'), sl.map(([o, v]) => `${o.toString(16).padStart(4, '0')} ${h8(v)}`).join('\n') + '\n');
  // IDE (webtv_ide init_*): registers, buffer, a read in progress; fff0 = image size in sectors
  const ide = m.ide;
  const xl = [[0xfff0, ide.totalSectors],
    [0x0, ide.error], [0x1, ide.feature], [0x2, ide.count], [0x3, ide.sector], [0x4, ide.cylLo], [0x5, ide.cylHi],
    [0x6, ide.drvHead], [0x7, ide.status], [0x8, ide.devCtl], [0x9, ide.cmd], [0xa, ide.multiple], [0xb, ide.irq ? 1 : 0],
    [0xc, (ide.buf ? 1 : 0) | (ide.buf && ide.cmd === 0xec ? 2 : 0) | (ide.wbuf ? 4 : 0) | (ide.secCmd ? 8 : 0)],
    [0xd, ide.bufPos], [0xe, ide.buf ? ide.buf.length : (ide.wbuf ? ide.wbuf.length : 0)], [0xf, ide.xferRemain]];
  if (ide.buf && ide.cmd !== 0xec) for (let k = 0; k < ide.buf.length / 2; k++) xl.push([0x1000 + k, ide.buf[2 * k] | (ide.buf[2 * k + 1] << 8)]);
  if (ide.wbuf) for (let k = 0; k < ide.wbuf.length / 2; k++) xl.push([0x1000 + k, ide.wbuf[2 * k] | (ide.wbuf[2 * k + 1] << 8)]);
  const pend = m.sched.events.find((e) => e.name === 'ide-read');
  if (pend) {
    // the read is restarted in RTL from the current registers; its data goes first into disk.txt
    const lba = ide.getLba(), n = ide.blockSize();
    ide.backend.getSectors(lba, n);        // (logged by the wrapper)
    xl.push([0x0010, pend.time - cpu.cycles]);
  }
  if (m.sched.events.find((e) => e.name === 'ide-write')) process.stderr.write('WARNING: IDE write in progress at the snapshot (not restored)\n');
  writeFileSync(join(snapDir, 'ide.txt'), xl.map(([o, v]) => `${o.toString(16).padStart(4, '0')} ${h8(v)}`).join('\n') + '\n');
  const ram = new Uint8Array(m.bus.ram.length * 4);
  const dv = new DataView(ram.buffer);
  m.bus.ram.forEach((w, i) => dv.setInt32(i * 4, w, false)); // big-endian, as the box sees it
  writeFileSync(join(snapDir, 'ram.bin'), ram);
  process.stderr.write(`snapshot before instruction ${cpu.cycles - 1} (pc ${h8(pc)}) -> ${snapDir}\n`);
};

writeFileSync(outFile, '');
// sectors read from the disk while tracing (testbench disk model): "<lba hex> <512 bytes hex>" per sector
const diskFile = snapDir ? join(snapDir, 'disk.txt') : null;
const diskLog = (lba, data) => {
  if (!diskFile) return;
  let t = '';
  for (let i = 0; i < data.length / 512; i++) t += `${h8(lba + i)} ${Buffer.from(data.subarray(i * 512, i * 512 + 512)).toString('hex')}\n`;
  appendFileSync(diskFile, t);
};
const start = () => {
  cpu.traceHook = (pc, op) => {
    if (cpu.inDelay) return;               // never start inside a branch delay slot
    if (diskFile) {
      writeFileSync(diskFile, '');
      if (m.ide.backend) {
        const be = m.ide.backend, get = be.getSectors.bind(be);
        be.getSectors = (lba, n) => { const d = get(lba, n); diskLog(lba, d); return d; };
      }
    }
    if (snapDir) writeSnapshot(pc);
    snap();
    cpu.traceHook = hook;
    hook(pc, op);
  };
};
if (from === 0) start();
else m.sched.at('trace-start', from, start);

const t0 = Date.now();
// yield to the event loop between slices: the built-in WebTV service answers asynchronously
const tick = () => new Promise((r) => setImmediate(r));
while (!done) {
  m.run(from > cpu.cycles ? Math.min(20_000_000, from - cpu.cycles + 1) : 1_000_000);
  if (cpu.stopRequested) done = done || traced >= count;
  await tick();
}
flush();
process.stderr.write(`traced ${written} instructions from ${from} in ${((Date.now() - t0) / 1000).toFixed(1)}s -> ${outFile}\n`);
// the network service keeps timers alive: exit explicitly
process.exit(0);
