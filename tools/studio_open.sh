#!/bin/zsh
# Usage: tools/studio_open.sh <name>
# Builds build/<name>.rbxl from default.project.json (if missing) and opens it in its own Studio
# window, then full-syncs src/. Afterwards use STUDIO_MATCH=<name>.rbxl with studio.py / sync.py.
set -e
name=${1:?place name}
cd "${0:A:h}/.."
export STUDIO_MATCH="$name.rbxl"
if .venv/bin/python tools/studio.py list | grep -q "\"$name.rbxl\""; then
  echo "studio for $name.rbxl already open"
else
  [ -f build/$name.rbxl ] || .bin/rojo build -o build/$name.rbxl
  nohup /Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio -localPlaceFile "$PWD/build/$name.rbxl" -task EditFile -userid 22641473 >/dev/null 2>&1 &
  for i in {1..60}; do
    sleep 3
    if .venv/bin/python tools/studio.py list | grep -q "\"$name.rbxl\""; then break; fi
  done
  sleep 5
fi
# Resolve this window's id once and pin every later call to it.
export STUDIO_ID=$(.venv/bin/python - <<'PY'
import os, sys
sys.path.insert(0, "tools")
import studio
c = studio.Client()
try:
    print(studio.pick_studio(c))
finally:
    c.close()
PY
)
echo "studio id for $name.rbxl: $STUDIO_ID (use STUDIO_ID=$STUDIO_ID or STUDIO_MATCH=$name.rbxl)"
.venv/bin/python tools/sync.py --full
