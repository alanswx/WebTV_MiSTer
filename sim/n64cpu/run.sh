#!/bin/bash
# build (if needed), run N instructions, compare with the JS reference trace
cd "$(dirname "$0")"
N=${1:-10000}
REF=${REF:-../out/trace_0_2000000.txt.gz}
[ "$NOBUILD" ] || ./build.sh > out/build.log 2>&1 || { grep -i error out/build.log | head; exit 1; }
./tb_cpu -gmax_instr=$N --ieee-asserts=disable 2>&1 | grep -v "^ *$" | grep -v "loaded\|simulation finished" | tail -4
python3 -I ../compare.py "$REF" out/rtl_trace.txt
