#!/usr/bin/env bash
# prof.sh BIN NAME VARIANT(bench|benchc): one merge under perf; prints the read side of the merge thread.
set -uo pipefail
L=/work/mrt
BIN=$1; NAME=$2; V=${3:-benchc}
PERF=$(ls /usr/lib/linux-tools/*/perf | head -1)
export WORK=$L/$V PERF CPUS=0-7
[ "$V" = benchc ] && export AFTER_CREATE="ALTER TABLE bench.{t} MODIFY SETTING min_bytes_for_wide_part = 0"
KIT=$L/kit; [ "$V" = benchc ] && KIT=$L/kitc
bash $KIT/bench.sh prof "$BIN" "$NAME"
D=$WORK/perf-$NAME.data
OUT=$L/prof-$V-$NAME
echo "== comm"; cat $WORK/prof-$NAME-comm.txt
$PERF report -i $D --comms MergeMutate --children --sort symbol --stdio -g none --percent-limit 0.3 2>/dev/null | grep '%' | cut -c1-220 > $OUT-incl.txt
$PERF report -i $D --comms MergeMutate --no-children --sort symbol --parent 'MergeTreeSequentialSource::generate' --exclude-other --stdio -g none --percent-limit 0.05 2>/dev/null | grep '%' | cut -c1-220 > $OUT-readself.txt
$PERF report -i $D --comms MergeMutate --no-children --sort symbol --stdio -g none --percent-limit 0.2 2>/dev/null | grep '%' | cut -c1-220 > $OUT-self.txt
grep -E 'generate|ReaderWide::readRows|ReaderCompactSingleBuffer::readRows|decompress\(' $OUT-incl.txt | head
echo "== read-side self (% of merge thread)"; head -60 $OUT-readself.txt
echo PROF_DONE
