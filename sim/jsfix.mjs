// Fixes applied to the webtv-bridge JS emulator when it is used as the golden reference here
// (the clone in ext/ is left untouched; report these upstream).
//
// 1. Cause.IP7: MipsCpu.updateCause() clears only IP6..IP2 before OR-ing in the timer bit, so once
//    IP7 is set it stays set after Compare is written (timerIrq is cleared, Cause bit 15 is not).
//    On the R4640, IP7 is the timer level and a Compare write clears it; with the stale bit the
//    OS's interrupt dispatcher sees a timer tick on every later interrupt.
export async function applyJsFixes(BR) {
  const { MipsCpu } = await import(BR + '/src/cpu/mips.js');
  MipsCpu.prototype.updateCause = function () {
    let c = this.cp0[13] & ~0xfc00;
    c |= (this.irqLines & 0x1f) << 10;
    if (this.timerIrq) c |= 0x8000;
    this.cp0[13] = c;
    return c;
  };
}
