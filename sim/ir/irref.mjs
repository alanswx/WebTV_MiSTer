// Reference IR runs from the JS model: key events at given times, TRANS_DATA read every READ_US.
// usage: node irref.mjs > ref.txt   (also writes events.txt for the RTL testbench)
import { writeFileSync } from 'node:fs';
const BR = new URL('../../ext/webtv-bridge/', import.meta.url).pathname;
const { SoloIr } = await import(BR + 'src/machine/ir.js');
const HZ = 1_000_000;                     // 1 "cycle" = 1 us
const m = {
  cpuHz: HZ, cpu: { cycles: 0 },
  sched: { ev: [], at(n, t, f) { this.cancel(n); this.ev.push({ n, t, f }); }, after(n, d, f) { this.at(n, m.cpu.cycles + d, f); },
    cancel(n) { this.ev = this.ev.filter((e) => e.n !== n); }, pending(n) { return this.ev.some((e) => e.n === n); } },
  solo: { setDevIrq() {} },
};
const ir = new SoloIr(m);
// events: [time us, scancode, release]
const events = [];
let t = 100000;
for (const sc of [0x1b, 0x1b, 0x4b, 0x50, 0x3a, 0x1e, 0x31, 0x0a]) { events.push([t, sc, 0]); events.push([t + 30000, sc, 1]); t += 150000; }
events.push([t, 0x7f, 0], [t + 1000, 0x7f, 1], [t + 2000, 0x6d, 0], [t + 3000, 0x6d, 1]);   // queued back to back
writeFileSync(new URL('events.txt', import.meta.url), events.map(([a, b, c]) => `${a} ${b} ${c}`).join('\n') + '\n');
const READ_US = 1000, END = t + 400000;
let ei = 0;
const out = [];
for (let now = 0; now <= END; now += 1) {
  m.cpu.cycles = now;
  while (ei < events.length && events[ei][0] <= now) { ir.enqueue(events[ei][1], !!events[ei][2]); ei++; }
  for (const e of [...m.sched.ev]) if (e.t <= now) { m.sched.ev = m.sched.ev.filter((x) => x !== e); e.f(); }
  if (now % READ_US === 0) { const v = ir.transData(); if (v) out.push(`${now} ${v.toString(16)}`); }
}
console.log(out.join('\n'));
