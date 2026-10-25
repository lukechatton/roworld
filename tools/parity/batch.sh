#!/bin/bash
# sim-parity: run many lockstep pairs in parallel and summarise.
#   tools/parity/batch.sh <jobs> <ticks> <tribes> <human> <diff> <seed>...
# Writes $PARITY_DIR/batch/<tag>.txt (diff.py output) and prints the non-identical ones.
J=$1; T=$2; TR=$3; HU=$4; DF=$5; shift 5
D=${PARITY_DIR:?set PARITY_DIR}
mkdir -p $D/batch
cd "$(dirname "$0")/../.."
printf "%s\n" "$@" | xargs -P $J -I{} sh -c "TAG=b{}_t${TR}_h${HU}_d${DF} tools/parity/run_pair.sh {} $T -1 -1 '' $TR $HU $DF > $D/batch/s{}_t${TR}_h${HU}_d${DF}.txt 2>&1"
n=0; bad=0
for s in "$@"; do
  f=$D/batch/s${s}_t${TR}_h${HU}_d${DF}.txt
  n=$((n+1))
  if ! grep -q IDENTICAL $f; then bad=$((bad+1)); echo "== seed $s (tribes $TR human $HU diff $DF)"; cat $f; fi
done
echo "batch: $((n-bad))/$n identical over $T ticks (tribes $TR human $HU diff $DF)"
