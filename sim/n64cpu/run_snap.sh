#!/bin/bash
# Lock-step window from a JS snapshot: run_snap.sh FROM COUNT  (makes the snapshot if needed)
cd "$(dirname "$0")"
FROM=$1; N=${2:-100000}; B=${B:-.}
D=../out/snap_$FROM
if [ ! -f "$D/ss.txt" ] || [ ! -f "$D/vid.txt" ] || [ ! -f "$D/ide.txt" ]; then
  rm -rf $D
  node ../trace.mjs --from $FROM --count $((N + 1000)) --snapshot $D --out $D/ref.txt.gz 2>&1 | grep -v "^\[dbg\]"
fi
IDX=$(awk '/^cycles/{print $2}' $D/info.txt)
gzcat $D/ref.txt.gz | grep -o "MR:[0-9a-f]*/[124]=[0-9a-f]*" | sed -E 's/MR:([0-9a-f]+)\/([124])=([0-9a-f]+)/\1 \2 \3/' | awk '{printf "%08s %08s %08s\n",$1,$2,$3}' > $D/mmio.txt
gzcat $D/ref.txt.gz | awk -v f=$IDX '{for(i=4;i<=NF;i++) if ($i ~ /^IRQL=/) {sub("IRQL=","",$i); print $1 - f, $i}}' > $D/irq.txt
# IRQ_REPLAY: issue number of the instruction each interrupt preempts (the one after an IRQ-marked line)
# (the RTL issues a preempted instruction twice -- once when interrupted, once after eret -- so each
#  earlier interrupt moves the issue/export numbers on by one)
gzcat $D/ref.txt.gz | awk -v f=$IDX '/ IRQ( |$)/{print $1 + 1 - f + k; k++}' > $D/irqat.txt
# SOLO interrupt state changes: "<rel idx> <key> <hex>"
gzcat $D/ref.txt.gz | awk -v f=$IDX '{for(i=4;i<=NF;i++) if ($i ~ /^S:/) {split(substr($i,3),a,"="); printf "%d %s %08s\n", $1 - f, a[1], a[2]}}' | tr ' ' ' ' > $D/solo_ev.txt
$B/tb_cpu -gsnap_dir=$D -gmmio_file=$D/mmio.txt -gtrace_file=$D/rtl.txt -gfirst_idx=0 -girq_file=$D/irq.txt -girqat_file=$D/irqat.txt -gsolo_ev_file=$D/solo_ev.txt -gmax_instr=$N --ieee-asserts=disable 2>&1 | grep -iE "error|fail|warning|done:" | head -${SHOW:-12}
python3 -I ../compare.py $D/ref.txt.gz $D/rtl.txt --snap $D/ss.txt
