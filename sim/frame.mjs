// Capture one rendered frame from the webtv-bridge JS emulator, with everything the renderer used,
// as a reference for the RTL frame renderer.
//
// usage: node sim/frame.mjs --at N [--out DIR] [--frames K] [--rom F] [--disk F] [--power-at N]
//
// Runs to instruction N, then captures the next K (default 1) frames. For each frame i, DIR/i/:
//   ram.bin    8 MB RAM image (big-endian words, as the box sees it) at the moment of rendering
//   regs.txt   "<name> <hex>": pot/vid/gfx registers and the derived draw window
//   frame.ppm  the JS emulator's 640x480 RGB output for that frame
import { readFileSync, openSync, readSync, fstatSync, writeFileSync, mkdirSync } from 'node:fs';
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
const at = Number(opt('at', '2500000000'));
const frames = Number(opt('frames', '1'));
const outDir = opt('out', join(HERE, 'out', `frame_${at}`));
const powerAt = Number(opt('power-at', '1600000000'));

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
  if (c === 10) line = ''; else if (c !== 13) line += String.fromCharCode(c);
  if (line.endsWith('Disk Boot?')) m.solo.debugInput('y'.charCodeAt(0));
};
m.modemLine.line = createNetworkLine({ relayUrl: null, service: new WebTVService({ log: quiet }), hostMap: {}, log: quiet });
m.sched.at('power', powerAt, () => m.ir.pressButton('power'));

const h8 = (v) => (v >>> 0).toString(16).padStart(8, '0');
const vid = m.solo.video;
let captured = 0;
let armed = false;
const origRender = vid.render.bind(vid);
vid.render = () => {
  if (!armed) return origRender();
  const dir = join(outDir, String(captured));
  mkdirSync(dir, { recursive: true });
  const ram = new Uint8Array(m.bus.ram.length * 4);
  const dv = new DataView(ram.buffer);
  m.bus.ram.forEach((w, i) => dv.setInt32(i * 4, w, false));
  writeFileSync(join(dir, 'ram.bin'), ram);
  const P = vid.pot, V = vid.vid, G = vid.gfx, D = vid.draw;
  const regs = {
    pot_vstart: P.vstart, pot_vsize: P.vsize, pot_blnkcol: P.blankColor, pot_hstart: P.hstart, pot_hsize: P.hsize,
    pot_cntl: P.cntl, vid_nstart: V.nstart, vid_nsize: V.nsize, vid_dmacntl: V.dmacntl,
    gfx_cntl: G.cntl, gfx_celsbase_master: G.celsBaseMaster, gfx_ymapbase_master: G.ymapBaseMaster,
    gfx_initcolor: G.initColor, gfx_hcounterinit: G.hcounterInit, gfx_blanklines: G.blankLines, gfx_activelines: G.activeLines,
    draw_hstart: D.hstart, draw_hsize: D.hsize, draw_vstart: D.vstart, draw_vsize: D.vsize, draw_nstart: D.nstart,
    instr: m.cpu.cycles,
  };
  writeFileSync(join(dir, 'regs.txt'), Object.entries(regs).map(([k, v]) => `${k} ${h8(v)}`).join('\n') + '\n');
  origRender();
  const fb = vid.fb;
  const ppm = Buffer.alloc(15 + 640 * 480 * 3);
  ppm.write('P6\n640 480\n255\n');
  let o = 15;
  for (let i = 0; i < 640 * 480; i++) { const p = fb[i]; ppm[o++] = p & 0xff; ppm[o++] = (p >>> 8) & 0xff; ppm[o++] = (p >>> 16) & 0xff; }
  writeFileSync(join(dir, 'frame.ppm'), ppm);
  process.stderr.write(`frame ${captured} at instruction ${m.cpu.cycles} (${(P.cntl & 8) ? 'gfx' : 'vid'} mode) -> ${dir}\n`);
  captured++;
};

const tick = () => new Promise((r) => setImmediate(r));
while (captured < frames) {
  if (!armed && m.cpu.cycles >= at) armed = true;
  m.run(armed ? 1_000_000 : Math.min(20_000_000, at - m.cpu.cycles));
  await tick();
}
process.exit(0);
