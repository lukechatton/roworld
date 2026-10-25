#!/bin/bash
# sim-parity: create the scratch copies of the ORIGINAL used by the lockstep tools (never modifies
# ~/games/airfront):
#   PARITY_DIR=<scratch dir> tools/parity/setup_copies.sh
# $PARITY_DIR/orig  plain copy + tests/parity_lockstep.{gd,tscn} (+ rng/sort reference scenes)
# $PARITY_DIR/otr   same, with the Sim's RandomNumberGenerator swapped for TraceRng (call-site log)
set -e
D=${PARITY_DIR:?set PARITY_DIR}
T="$(cd "$(dirname "$0")" && pwd)"
AE="/Users/luke/Library/Application Support/Steam/steamapps/common/Airship Editor/AirshipEditor.app/Contents/MacOS/AirshipEditor"
mkdir -p "$D"
for c in orig otr; do
  rsync -a --delete ~/games/airfront/ "$D/$c/"
  cp "$T/lockstep.gd" "$D/$c/tests/parity_lockstep.gd"
  cp "$T/lockstep.tscn" "$D/$c/tests/parity_lockstep.tscn"
  cp "$T/rng_ref.gd" "$D/$c/tests/parity_rng_ref.gd"
  cp "$T/rng_ref.tscn" "$D/$c/tests/parity_rng_ref.tscn"
  cp "$T/sort_ref.gd" "$D/$c/tests/parity_sort_ref.gd"
  cp "$T/sort_ref.tscn" "$D/$c/tests/parity_sort_ref.tscn"
done
cp "$T/trace_rng.gd" "$D/otr/scripts/core/trace_rng.gd"
sed -i '' 's/^var rng := RandomNumberGenerator.new()/var rng := TraceRng.new()/' "$D/otr/scripts/core/sim_state.gd"
sed -i '' 's/rng: RandomNumberGenerator = null) -> int:/rng: TraceRng = null) -> int:/' "$D/otr/scripts/core/sim_colors.gd"
sed -i '' 's/rng: RandomNumberGenerator) -> int:/rng: TraceRng) -> int:/' "$D/otr/scripts/core/sim_nav.gd"
# register the new class_name
"$AE" --headless --import --quit --log-file "$D/otr_import.log" --path "$D/otr" > /dev/null 2>&1 || true
echo "copies ready in $D (orig, otr)"
