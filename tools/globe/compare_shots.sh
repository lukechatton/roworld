#!/bin/zsh
# Capture the port at the original's view_mock SHOTS and build side-by-side comparisons.
# Usage: tools/globe/compare_shots.sh [name ...]   (Play must be running with AF_DEV=GlobeDev)
#        PHONE=1 tools/globe/compare_shots.sh ...   (device simulator on; refs from the original's
#        `--capture --phone --view-tier=mobile` in /private/tmp/claude-501/ref_phone)
cd "${0:A:h}/../.."
OUT=/private/tmp/claude-501/cmp
REF=/private/tmp/claude-501/ref
PFX=""
if [ -n "$PHONE" ]; then REF=/private/tmp/claude-501/ref_phone; PFX="phone_"; fi
mkdir -p $OUT
typeset -A SHOTS
SHOTS=(mock_eu_close "45,13,1.32" mock_eu_mid "41,17,1.58" mock_africa_eu "24,16,2.05" mock_globe "22,12,2.6" mock_closest "46,6.5,1.12" mock_americas "15,-80,2.2" mock_asia "33,105,1.75" mock_south_pole "-80,60,1.9")
names=(${@:-${(k)SHOTS}})
for n in $names; do
  echo "workspace:SetAttribute(\"AF_CAM\", \"${SHOTS[$n]}\") return 1" | tools/globe/st luau Client - >/dev/null
  for i in {1..40}; do
    sleep 1
    p=$(echo 'return workspace:GetAttribute("AF_PERF") or ""' | tools/globe/st luau Client - | .venv/bin/python -c 'import json,sys
t=sys.stdin.read().strip()
try:
  d=json.loads(t); g=d.get("globe",{}); print(g.get("pending_fill",1)+g.get("pending_tiles",0))
except Exception: print(1)')
    [ "$i" -gt 3 ] && [ "$p" = "0" ] && break
  done
  sleep 1
  tools/globe/st shot $OUT/port_$PFX$n.png >/dev/null
  .venv/bin/python - $n "$REF" "$PFX" <<'PY'
import sys
from PIL import Image
n, ref, pfx = sys.argv[1], sys.argv[2], sys.argv[3]
b=Image.open(f'/private/tmp/claude-501/cmp/port_{pfx}{n}.png').convert('RGB')
W=1920; H=round(W*b.size[1]/b.size[0])
a=Image.open(f'{ref}/{n}.png').convert('RGB').resize((W,H), Image.LANCZOS)
b=b.resize((W,H), Image.LANCZOS)
c=Image.new('RGB',(W,2*H)); c.paste(a,(0,0)); c.paste(b,(0,H)); c.save(f'/private/tmp/claude-501/cmp/sbs_{pfx}{n}.png')
c.resize((W//2,H)).save(f'/private/tmp/claude-501/cmp/sbs_{pfx}{n}_small.png')
PY
  echo "done $PFX$n"
done
