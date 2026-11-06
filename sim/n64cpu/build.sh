#!/bin/bash
# Analyze + elaborate the WebTV CPU (rtl/cpu, forked from N64_MiSTer), sim models and the
# testbench with GHDL.  B=dir puts the build products elsewhere (default: this directory).
set -e
cd "$(dirname "$0")"
R=../../rtl/cpu
B=${B:-.}
mkdir -p "$B"
rm -rf "$B/work" "$B/memlib"; mkdir -p "$B/work" "$B/memlib"
O="--std=08 -frelaxed -fsynopsys ${GHDL_OPT:--O2}"
M="ghdl -a $O --work=mem --workdir=$B/memlib"
G="ghdl -a $O --workdir=$B/work -P$B/memlib"
$M sim_models.vhd
$M $R/SyncFifoFallThroughMLAB.vhd
$G sim_models.vhd
for f in functions export divider cpu_FPU_sqrt cpu_FPU cpu_TLB_instr cpu_TLB_data cpu_instrcache cpu_datacache cpu_cop0; do
  $G $R/$f.vhd
done
$G cpu_mul_sim.vhd
$G $R/cpu.vhd
$G ../../rtl/webtv/webtv_sdpram.vhd
$G ../../rtl/webtv/webtv_bustick.vhd
$G ../../rtl/webtv/webtv_ddr3mux.vhd
$G ../../rtl/webtv/webtv_memmux.vhd
$G ../../rtl/webtv/webtv_solo_sys.vhd
$G ../../rtl/webtv/webtv_iic.vhd
$G ../../rtl/webtv/webtv_solo_vid.vhd
$G ../../rtl/webtv/webtv_gfx_render.vhd
$G ../../rtl/webtv/webtv_ide.vhd
$G ../../rtl/webtv/webtv_ir.vhd
$G ../../rtl/webtv/webtv_uart16550.vhd
$G ../../rtl/webtv/webtv_core.vhd
$G tb_cpu.vhd
ghdl -e $O --workdir=$B/work -P$B/memlib -o $B/tb_cpu tb_cpu
$G tb_render.vhd
ghdl -e $O --workdir=$B/work -P$B/memlib -o $B/tb_render tb_render
$G ../../rtl/webtv/webtv_mister.vhd
$G tb_mister.vhd
ghdl -e $O --workdir=$B/work -P$B/memlib -o $B/tb_mister tb_mister
