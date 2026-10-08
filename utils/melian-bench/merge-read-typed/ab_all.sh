#!/usr/bin/env bash
# ab_all.sh RUNS: A/B on Compact source parts, then on Wide source parts; prints both summaries.
for V in benchc bench; do
  echo "######## $V"
  bash $(dirname "$0")/ab.sh "${1:-5}" $V 2>&1 | grep -v '^AB_DONE'
  cat /work/mrt/$V/checksums.txt | awk '{print $1, $3, $4, $5, $6}' | sort | uniq -c
done
echo ABALL_DONE
