#!/bin/bash
# sim-parity: run the traced original copy and the port in lockstep for one seed.
#   tools/parity/run_pair.sh <seed> <ticks> [log_from] [log_to] [hooks] [tribes] [human 0|1|2] [diff]
# Env PARITY_DIR (scratch dir holding otr/ = traced copy of the original); DUMP_FROM/DUMP_TO dump
# the deltas of those ticks into the rl_/rlp_ logs; TAG names the output files (default: seed).
set -e
S=$1; T=$2; LF=${3:--1}; LT=${4:--1}; HK=${5:-}; TR=${6:-80}; HU=${7:-0}; DF=${8:-1}
TAG=${TAG:-$S}
D=${PARITY_DIR:?set PARITY_DIR}
AE="/Users/luke/Library/Application Support/Steam/steamapps/common/Airship Editor/AirshipEditor.app/Contents/MacOS/AirshipEditor"
cd "$(dirname "$0")/../.."
(LS_DUMP_FROM=${DUMP_FROM:--1} LS_DUMP_TO=${DUMP_TO:--1} LS_SEED=$S LS_TICKS=$T LS_TRIBES=$TR LS_HUMAN=$HU LS_DIFF=$DF LS_LOG_FROM=$LF LS_LOG_TO=$LT LS_RNGLOG=$D/rl_$TAG.txt LS_OUT=$D/o_$TAG.txt \
  "$AE" --headless --log-file $D/o_$TAG.log --path $D/otr --scene res://tests/parity_lockstep.tscn --quit-after 100000000 > /dev/null 2>&1) &
.bin/lune run tools/parity/lockstep.luau -- --seed=$S --ticks=$T --tribes=$TR --human=$HU --diff=$DF --dump_from=${DUMP_FROM:--1} --dump_to=${DUMP_TO:--1} --log_from=$LF --log_to=$LT --rnglog=$D/rlp_$TAG.txt --out=$D/p_$TAG.txt ${HK:+--hooks=$HK}
wait
python3 tools/parity/diff.py $D/o_$TAG.txt $D/p_$TAG.txt
if [ "$LF" != "-1" ]; then python3 tools/parity/rngdiff.py $D/rl_$TAG.txt $D/rlp_$TAG.txt 6; fi
