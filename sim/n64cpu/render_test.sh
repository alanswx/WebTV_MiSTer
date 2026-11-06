#!/bin/bash
# Render a frame captured by sim/frame.mjs with the RTL renderer and compare with the JS frame.
#   render_test.sh FRAME_DIR     (B=build dir)
cd "$(dirname "$0")"
D=$1; B=${B:-.}
for k in pot_vstart pot_vsize pot_hstart pot_hsize pot_cntl pot_blnkcol vid_nstart vid_dmacntl gfx_cntl \
         gfx_ymapbase_master gfx_celsbase_master gfx_hcounterinit gfx_blanklines gfx_activelines; do
  awk -v k=$k '$1 == k {print $2}' $D/regs.txt
done > $D/regs.hex
$B/tb_render -gframe_dir=$D -gout_file=$D/rtl.ppm --ieee-asserts=disable 2>&1 | grep -E "rendered|error|fail" | sed 's/.*(report note): //'
python3 -I ../ppmdiff.py $D/frame.ppm $D/rtl.ppm $D/diff.png
