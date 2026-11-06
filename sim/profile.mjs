// Hardware-usage profile of a WebTV boot, for scoping the FPGA core.
// Runs the webtv-bridge JS emulator (interpreter mode) from power-on through a Power press
// to the service's registration page, and records:
//   - every distinct instruction mnemonic and how often it ran (=> which MIPS III / R4640
//     features the CPU core must implement)
//   - every MMIO register touched (address, size, reads/writes) (=> SOLO/IDE/modem scope)
//   - CP0 registers read/written
//
// usage: node sim/profile.mjs [--cycles N] [--power-at N] [--out DIR]
import { readFileSync, openSync, readSync, fstatSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const BR = join(HERE, '../ext/webtv-bridge');
const { WebTV } = await import(join(BR, 'src/machine/webtv.js'));
const { OverlayDisk } = await import(join(BR, 'src/machine/ide.js'));
const { disasm } = await import(join(BR, 'src/cpu/disasm.js'));
const { createNetworkLine } = await import(join(BR, 'src/net/line.js'));
const { WebTVService } = await import(join(BR, 'src/wtvsrv/service.js'));

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };
const cycles = Number(opt('cycles', '4000000000'));
const powerAt = Number(opt('power-at', '1600000000'));
const outDir = opt('out', join(HERE, 'out'));
mkdirSync(outDir, { recursive: true });

const rom = readFileSync(opt('rom', join(BR, 'data/flipped_merged_boot.bin')));
const fd = openSync(opt('disk', join(BR, 'data/debug_webtv_w200_7.bin')), 'r');
const disk = new OverlayDisk(fstatSync(fd).size, (lba, n) => { const b = new Uint8Array(n * 512); readSync(fd, b, 0, b.length, lba * 512); return b; });

const quiet = () => {};
const m = new WebTV({ rom, disk, log: quiet });
let line = '';
m.solo.debugOut = (c) => {
  if (c === 10) { if (line.includes('Disk Boot?')) {} line = ''; } else if (c !== 13) line += String.fromCharCode(c);
  if (line.endsWith('Disk Boot?')) for (const ch of 'y') m.solo.debugInput(ch.charCodeAt(0));
};
const service = new WebTVService({ log: quiet });
m.modemLine.line = createNetworkLine({ relayUrl: null, service, hostMap: {}, log: quiet });
m.sched.at('power', powerAt, () => m.ir.pressButton('power'));

// ---- instruction profile: key = the instruction word with register/immediate fields masked
// out, so each distinct operation maps to one entry; mnemonic via the disassembler.
const opCount = new Map();
const opName = new Map();
const keyOf = (op) => {
  const major = op >>> 26;
  if (major === 0) return op & 0xfc00003f;            // SPECIAL: funct
  if (major === 1) return op & 0xfc1f0000;            // REGIMM: rt
  if (major === 0x10 || major === 0x11 || major === 0x12) {
    const rs = (op >>> 21) & 31;
    if (rs === 0x10 || (major === 0x11 && rs >= 0x10)) return op & 0xffe0003f; // CO / fmt: funct
    return op & 0xffe00000;                           // MF/MT/CF/CT/BC: rs
  }
  if (major === 0x1c) return op & 0xfc00003f;         // SPECIAL2 (R4640 MAD/MUL)
  if (major === 0x2f) return op & 0xfc1f0000;         // CACHE: op field
  return op & 0xfc000000;
};
const cp0Use = new Map();
m.cpu.traceHook = (pc, op) => {
  const k = keyOf(op) >>> 0;
  const c = opCount.get(k);
  if (c === undefined) { opCount.set(k, 1); opName.set(k, disasm(op, pc).split(/\s+/)[0] + (((op >>> 26) === 0x2f) ? ` op=${(op >>> 16) & 31}` : '')); }
  else opCount.set(k, c + 1);
  if ((op >>> 26) === 0x10) {
    const rs = (op >>> 21) & 31, rd = (op >>> 11) & 31;
    if (rs === 0 || rs === 4 || rs === 1 || rs === 5) {
      const key = `${['mfc0', 'dmfc0', '', '', 'mtc0', 'dmtc0'][rs]} $${rd}`;
      cp0Use.set(key, (cp0Use.get(key) || 0) + 1);
    }
  }
};

// ---- MMIO profile
const mmio = new Map();
m.bus.watch = (pa, size, isWrite, v) => {
  const k = `${(pa >>> 0).toString(16).padStart(8, '0')}/${size}`;
  let e = mmio.get(k);
  if (!e) mmio.set(k, e = { r: 0, w: 0, first: m.cpu.cycles, vals: new Set() });
  isWrite ? e.w++ : e.r++;
  if (isWrite && e.vals.size < 8) e.vals.add((v >>> 0).toString(16));
};

const t0 = Date.now();
const SLICE = 50_000_000;
for (let done = 0; done < cycles; done += SLICE) {
  m.run(SLICE);
  process.stderr.write(`\r${(done / 1e9).toFixed(2)}G instr, ${((Date.now() - t0) / 1000).toFixed(0)}s `);
}
process.stderr.write('\n');

const total = [...opCount.values()].reduce((a, b) => a + b, 0);
const ops = [...opCount].map(([k, c]) => ({ name: opName.get(k), count: c, key: k.toString(16) })).sort((a, b) => b.count - a.count);
const region = (pa) => pa < 0x04000000 ? 'ram' : pa < 0x04010000 ? 'solo' : pa < 0x1e400000 ? 'modem' : pa < 0x1f000000 ? 'ide' : 'rom';
const regs = [...mmio].map(([k, e]) => ({ addr: k, region: region(parseInt(k, 16)), r: e.r, w: e.w, first: e.first, vals: [...e.vals] })).sort((a, b) => a.addr < b.addr ? -1 : 1);

let txt = `# Instruction mix (${total} instructions, ${ops.length} distinct ops)\n`;
for (const o of ops) txt += `${o.name.padEnd(16)} ${String(o.count).padStart(12)}  ${(100 * o.count / total).toFixed(3).padStart(7)}%\n`;
txt += `\n# CP0 access\n`;
for (const [k, c] of [...cp0Use].sort()) txt += `${k.padEnd(12)} ${c}\n`;
txt += `\n# MMIO registers (${regs.length})\n`;
for (const r of regs) txt += `${r.addr.padEnd(12)} ${r.region.padEnd(6)} r=${String(r.r).padStart(9)} w=${String(r.w).padStart(9)}  vals=${r.vals.join(',')}\n`;
writeFileSync(join(outDir, 'profile.txt'), txt);
const { writePng } = await import(join(BR, 'tools/png.mjs'));
try { writePng(join(outDir, 'profile_end.png'), m.solo.video.fb, 640, 480); } catch {}
console.log(`wrote ${join(outDir, 'profile.txt')} in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
