// 16550 register semantics: JS Uart16550 vs RTL (tb_uart.vhd). Ops: w reg val | r reg | x byte (line RX) | d dcd
import { writeFileSync } from 'node:fs';
const BR = new URL('../../ext/webtv-bridge/', import.meta.url).pathname;
const { Uart16550 } = await import(BR + 'src/machine/uart16550.js');
let irq = false;
const u = new Uart16550({ onIrq: (s) => { irq = s; } });
u.setModemStatus(false, true, true, false);   // as the Modem does after reset
const ops = [];
let seed = 7; const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
ops.push(['w', 3, 0x83], ['w', 0, 0x0c], ['w', 1, 0x00], ['r', 0], ['r', 1], ['w', 3, 0x03], ['w', 2, 0x07], ['w', 4, 0x0b]);
for (let i = 0; i < 400; i++) {
  const k = rnd(10);
  if (k < 3) ops.push(['r', rnd(8)]);
  else if (k < 5) ops.push(['w', [1, 2, 3, 4, 7, 0][rnd(6)], rnd(256)]);
  else if (k < 7) ops.push(['x', rnd(256)]);
  else if (k < 8) ops.push(['d', rnd(2)]);
  else ops.push(['r', [0, 2, 5, 6][rnd(4)]]);
}
// keep DLAB mostly off and the FIFO small: patch LCR writes to clear DLAB half the time, FCR writes keep bit 1 rare
for (const o of ops) { if (o[0] === 'w' && o[1] === 3 && rnd(2)) o[2] &= 0x7f; if (o[0] === 'w' && o[1] === 2 && rnd(4)) o[2] &= ~2; }
let dcd = 0;
const out = [];
for (const o of ops) {
  let v = '-';
  if (o[0] === 'w') u.write(o[1], o[2]);
  else if (o[0] === 'r') v = u.read(o[1]).toString(16);
  else if (o[0] === 'x') u.receive(o[1]);
  else if (o[0] === 'd') { if (o[1] !== dcd) { dcd = o[1]; u.setModemStatus(!!dcd, true, true, false); } }
  out.push(`${o.join(' ')} ${v} ${irq ? 1 : 0}`);
}
writeFileSync(new URL('uart_ops.txt', import.meta.url), ops.map((o) => o.join(' ')).join('\n') + '\n');
console.log(out.join('\n'));
