// Random gfxUnit scenes for the RTL frame renderer: random RAM (textures, codebooks), a random
// ymap with bands of random cels (all texture types incl. data loads, all alpha types, scaled /
// sloped / masked), rendered by the webtv-bridge JS video code. Writes, like sim/frame.mjs:
//   DIR/<seed>/ram.bin, regs.txt, frame.ppm
// usage: node sim/celfuzz.mjs [--seeds 1-20] [--out DIR]
import { writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const BR = join(HERE, '../ext/webtv-bridge');
const { applyJsFixes } = await import(join(HERE, 'jsfix.mjs'));
await applyJsFixes(BR);
const { WebTV } = await import(join(BR, 'src/machine/webtv.js'));

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };
const [s0, s1] = opt('seeds', '1-10').split('-').map(Number);
const outDir = opt('out', join(HERE, 'out', 'celfuzz'));
const h8 = (v) => (v >>> 0).toString(16).padStart(8, '0');

function rng(seed) {
  let s = seed >>> 0 || 1;
  const next = () => { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s; };
  const r = (n) => next() % n;
  return { next, r, range: (a, b) => a + r(b - a + 1), pick: (arr) => arr[r(arr.length)] };
}

for (let seed = s0; seed <= (s1 || s0); seed++) {
  const R = rng(seed * 2654435761);
  const m = new WebTV({ rom: new Uint8Array(2 << 20), disk: null, log: () => {} });
  const ram = m.bus.ram;
  // texture / codebook area: 1 MB of noise at 0x100000 (some Y bytes forced to 0xff = transparent)
  for (let i = 0x100000 / 4; i < 0x200000 / 4; i++) {
    let w = R.next() | 0;
    if (R.r(16) === 0) w |= 0xff000000;
    ram[i] = w;
  }
  const W = (addr, v) => { ram[(addr & 0x7fffff) >>> 2] = v | 0; };

  // ymap at 0x10000, cel lists at 0x20000 (cel blocks are 8-byte units from celsBase)
  const ymapBase = 0x10000, celsBase = 0x20000;
  let celOff = 0;
  const nbands = R.range(1, 4);
  let ymi = 0;
  for (let b = 0; b < nbands; b++) {
    const sizeCode = R.pick([0, 1, 2, 2, 2]);
    const celBytes = [8, 16, 48, 48][sizeCode];
    const lineCnt = R.range(1, 60);
    const lineTop = R.range(-200, 180) & 0x3ff;
    const disabled = R.r(8) === 0 ? 1 : 0;
    const blk = celOff >>> 3;
    W(ymapBase + 4 * ymi++, (lineCnt << 23) | (lineTop << 13) | (disabled << 12) | (sizeCode << 10) | blk);
    const ncels = R.range(1, 4);
    for (let c = 0; c < ncels; c++) {
      const isLast = c === ncels - 1 ? 1 : 0;
      const load = R.r(10) === 0;
      const tex = load ? 6 : R.pick([1, 2, 3, 4, 5, 7, 4, 4, 0]);
      const mode = (isLast << 7) | ((load ? R.pick([4, 4, 2, 6]) : R.r(4)) << 4) | (tex << 1);
      const d = new Int32Array(12);
      const texBase = (0x100000 + R.r(0xc0000)) >>> 2;
      const rowlongs = R.range(0, 255);
      const xl = R.range(-200, 100) & 0x3ff, xr = R.range(-100, 250) & 0x3ff;
      d[0] = (mode << 24) | (R.r(20) << 16) | ((rowlongs & 15) << 10) | xl;
      d[1] = (R.r(20) << 24) | (load ? (0x20000 >>> 2) : texBase);
      const dux = R.pick([0x100, 0x100, 0x80, 0x180, 0x40, -0x100 & 0xffff, R.r(0x10000)]);
      d[2] = ((rowlongs >> 4) << 24) | (((dux >> 4) & 0xff) << 16) | xr;
      d[3] = (R.pick([0xff, 0xff, R.r(256)]) << 24) | ((0x100000 + R.r(0x80000)) >>> 2);
      d[4] = ((R.r(0x10000) & 0xffff) << 16) | R.pick([0, 0x100, R.r(0x10000)]);
      d[5] = R.next() | 0;
      d[6] = ((R.r(0x10000) & 0xffff) << 16) | R.pick([0x100, 0x100, 0x80, R.r(0x10000)]);
      d[7] = (R.r(1024) << 20) | R.pick([0, 0, R.r(0x800) - 0x400 & 0xfffff]);
      d[8] = (R.r(1024) << 20) | R.pick([0, 0, R.r(0x800) - 0x400 & 0xfffff]);
      d[9] = R.pick([0, 0, 0x20, R.r(0x10000)]);
      d[10] = (R.pick([0xff, 0x7f, 0x3f, R.r(256)]) << 24) | (R.pick([0xff, 0x3f, R.r(256)]) << 16) |
        (((dux >> 12) & 0xf) << 12) | ((dux & 0xf) << 8) | R.r(256);
      d[11] = R.next() & 0xffffff;
      for (let i = 0; i < celBytes / 4; i++) W(celsBase + celOff + 4 * i, d[i]);
      celOff += celBytes;
    }
    celOff = (celOff + 7) & ~7;
  }
  W(ymapBase + 4 * ymi, (0x1ff << 13));        // termination

  // registers through the video unit's MMIO path
  const v = m.solo.video;
  const wr = (off, val) => v.write(off, val | 0);
  wr(0x9080, R.range(0x23, 0x40)); wr(0x9084, R.range(300, 480)); wr(0x908c, R.range(0x77, 0x90));
  wr(0x9090, R.range(400, 640)); wr(0x9088, R.next() & 0xffffff);
  wr(0x6044, R.pick([0, 0x140, R.range(100, 320)])); wr(0x6048, R.pick([0, 0xf, R.r(30)]));
  wr(0x604c, R.pick([0, 0xf2, R.range(100, 260)]));
  wr(0x601c, celsBase); wr(0x6020, ymapBase); wr(0x6004, 0x88);
  wr(0x9094, 0x949);
  const dir = join(outDir, String(seed));
  mkdirSync(dir, { recursive: true });
  const P = v.pot, V = v.vid, G = v.gfx;
  const regs = {
    pot_vstart: P.vstart, pot_vsize: P.vsize, pot_blnkcol: P.blankColor, pot_hstart: P.hstart, pot_hsize: P.hsize,
    pot_cntl: P.cntl, vid_nstart: V.nstart, vid_nsize: V.nsize, vid_dmacntl: V.dmacntl,
    gfx_cntl: G.cntl, gfx_celsbase_master: G.celsBaseMaster, gfx_ymapbase_master: G.ymapBaseMaster,
    gfx_initcolor: G.initColor, gfx_hcounterinit: G.hcounterInit, gfx_blanklines: G.blankLines, gfx_activelines: G.activeLines,
  };
  writeFileSync(join(dir, 'regs.txt'), Object.entries(regs).map(([k, x]) => `${k} ${h8(x)}`).join('\n') + '\n');
  const rb = new Uint8Array(ram.length * 4);
  const dv = new DataView(rb.buffer);
  ram.forEach((w, i) => dv.setInt32(i * 4, w, false));
  writeFileSync(join(dir, 'ram.bin'), rb);
  v.render();
  const ppm = Buffer.alloc(15 + 640 * 480 * 3);
  ppm.write('P6\n640 480\n255\n');
  let o = 15;
  for (let i = 0; i < 640 * 480; i++) { const p = v.fb[i]; ppm[o++] = p & 0xff; ppm[o++] = (p >>> 8) & 0xff; ppm[o++] = (p >>> 16) & 0xff; }
  writeFileSync(join(dir, 'frame.ppm'), ppm);
  process.stderr.write(`seed ${seed}: ${nbands} bands -> ${dir}\n`);
}
process.exit(0);
