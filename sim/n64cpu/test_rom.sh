#!/bin/bash
# Run a test ROM in the JS model and the RTL and compare: test_rom.sh ROM [N]
cd "$(dirname "$0")"
ROM=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); N=${2:-200}
T=out/$(basename "$ROM" .rom); mkdir -p "$T"
node ../trace.mjs --rom "$ROM" --disk none --count $((N + 50)) --out "$T/ref.txt.gz" 2>/dev/null
: > "$T/mmio.txt"
B=${B:-.}
$B/tb_cpu -grom_file="$ROM" -gmmio_file="$T/mmio.txt" -gtrace_file="$T/rtl.txt" -gmax_instr=$N --ieee-asserts=disable 2>&1 | grep -iE "error|fail" | head -5
python3 -I ../compare.py "$T/ref.txt.gz" "$T/rtl.txt"
