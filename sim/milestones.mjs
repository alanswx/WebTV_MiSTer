// First instruction index of: OS entry (pc in RAM), first interrupt taken, first Count read, first user-visible output
import { readFileSync, openSync, readSync, fstatSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const HERE = dirname(fileURLToPath(import.meta.url));
const BR = join(HERE, '../ext/webtv-bridge');
const { WebTV } = await import(join(BR, 'src/machine/webtv.js'));
const { OverlayDisk } = await import(join(BR, 'src/machine/ide.js'));
const fd = openSync(join(BR, 'data/debug_webtv_w200_7.bin'), 'r');
const disk = new OverlayDisk(fstatSync(fd).size, (lba, n) => { const b = new Uint8Array(n * 512); readSync(fd, b, 0, b.length, lba * 512); return b; });
const m = new WebTV({ rom: readFileSync(join(BR, 'data/flipped_merged_boot.bin')), disk, log: () => {} });
let line = '';
m.solo.debugOut = (c) => { if (c === 10) { console.log(`[dbg ${m.cpu.cycles}] ${line}`); line = ''; } else line += String.fromCharCode(c); if (line.endsWith('Disk Boot?')) m.solo.debugInput(121); };
const cpu = m.cpu;
const seen = {};
const mark = (k) => { if (!(k in seen)) { seen[k] = cpu.cycles; console.log(`== ${k} at ${cpu.cycles}`); } };
const oexc = cpu.exception.bind(cpu);
cpu.exception = (code, b) => { mark(`exception code ${code}`); return oexc(code, b); };
const oget = cpu.getCount.bind(cpu);
cpu.traceHook = (pc, op) => {
  if (((pc >>> 0) < 0x9fc00000) && ((pc >>> 0) >= 0x80000000)) mark('pc in RAM (kseg0)');
  if ((op >>> 21) === 0x200 && ((op >>> 11) & 31) === 9) mark('mfc0 Count');
  if (cpu.cycles > 400e6) cpu.traceHook = null;
};
for (let i = 0; i < 40; i++) m.run(10000000);
