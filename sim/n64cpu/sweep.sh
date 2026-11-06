#!/bin/bash
# Lock-step windows from JS snapshots across the whole boot, in parallel.
#   sweep.sh [N per window] [points...]     (B=build dir, J=parallel jobs)
cd "$(dirname "$0")"
N=${1:-200000}; shift
PTS=${@:-"150000000 300000000 500000000 800000000 1200000000 1650000000 2000000000 2500000000 3000000000"}
J=${J:-9}
for p in $PTS; do echo $p; done | xargs -P $J -I{} sh -c "B=${B:-.} ./run_snap.sh {} $N > out/sweep_{}.log 2>&1"
for p in $PTS; do printf "%12s  " $p; grep -E "^OK|^MISMATCH" out/sweep_$p.log || echo "(no result)"; done
