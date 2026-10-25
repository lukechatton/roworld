#!/bin/bash
# sim-parity: (re)generate the ORIGINAL's lockstep reference traces used by tests/parity_lockstep.luau.
#   PARITY_COPY=<scratch copy of ~/games/airfront with tests/parity_lockstep.{gd,tscn}> tools/parity/make_ref.sh
# Make the copy with: rsync -a ~/games/airfront/ <copy>/ ; cp tools/parity/lockstep.gd <copy>/tests/parity_lockstep.gd ;
# cp tools/parity/lockstep.tscn <copy>/tests/parity_lockstep.tscn   (never touch ~/games/airfront itself).
# Each reference keeps the header lines and every 10th tick.
set -e
C=${PARITY_COPY:?set PARITY_COPY}
AE="/Users/luke/Library/Application Support/Steam/steamapps/common/Airship Editor/AirshipEditor.app/Contents/MacOS/AirshipEditor"
cd "$(dirname "$0")"
TMP=$(mktemp -d)
# name seed ticks tribes human diff
CONFIGS="ai_s1:1:3600:80:0:1 human_s7:7:3000:80:2:1 mp_s3:3:4000:150:3:2 ai_s5:5:6000:80:0:1"
for c in $CONFIGS; do
  IFS=: read -r name seed ticks tribes human diff <<< "$c"
  (LS_SEED=$seed LS_TICKS=$ticks LS_TRIBES=$tribes LS_HUMAN=$human LS_DIFF=$diff LS_OUT=$TMP/$name.txt \
    "$AE" --headless --log-file $TMP/$name.log --path "$C" --scene res://tests/parity_lockstep.tscn --quit-after 100000000 > /dev/null 2>&1
   awk '$1 !~ /^[0-9]+$/ || $1 % 10 == 0' $TMP/$name.txt > ref/$name.txt
   echo "$name: $(wc -l < ref/$name.txt) lines") &
done
wait
rm -rf "$TMP"
