#!/bin/zsh
# Publishes Rofront the same way extract publishes Out Alive (~/roblox/extract/dev/tools/publish.sh):
# presses File → Publish to Roblox in the Rofront Studio window in the background (helper
# ~/.local/bin/studio-publish, Accessibility granted — don't rebuild it or the grant is lost) and
# waits for Studio's log to confirm the version, then pushes the committed branch if a remote exists.
#
# Rofront extras before pressing Publish:
#   1. what ships is exactly HEAD (uncommitted working-tree edits are ignored, with a note);
#   2. HEAD is checked out in a clean worktree and full-synced into the linked Studio window, then the
#      Dev harness folders are removed (release contents = release.project.json);
#   3. the window must be in Edit mode and its game.PlaceId must be the Rofront root place.
#
# Usage: tools/publish.sh [--staging] [--ref <commit>] [window-place-name]
#   --staging publishes to the private "Rofront Staging" experience instead (tools/publish.staging.json;
#     since 2026-10-04: a separate game to test in before production). Its
#     first publish is manual (File -> Publish to Roblox As... -> a new experience named Rofront Staging,
#     owned by the group), then put its ids in that file. Staging has its own DataStores, MemoryStores
#     and developer products (Data/Products `staging`), and stays off production's lobby service.
#   --ref publishes that commit instead of HEAD (rollback: tools/publish.sh --ref <last good sha>).
#   window-place-name defaults to the Studio window whose title starts "Rofront" in any case (staging:
#     "Rofront Staging"; production: any other, today "RoFront [World PvP]").
#
# After a production publish the old servers keep running the old version. To move players over without
# cutting matches short, ask Roblox for a delayed restart (docs/fresh-servers.md): tools/restart_servers.sh 60
set -u
REPO="${0:A:h:h}"
PLACE_ID=137151641329864
STAGING=0
if [[ "${1:-}" == "--staging" ]]; then
	STAGING=1; shift
	PLACE_ID=$(python3 -c "import json;print(json.load(open('$REPO/tools/publish.staging.json'))['place'])" 2>/dev/null)
	[[ -n "$PLACE_ID" && "$PLACE_ID" != "0" ]] || { echo "tools/publish.staging.json has no place id (the first publish is manual: File -> Publish to Roblox As...)"; exit 3; }
fi
BIN="$HOME/.local/bin/studio-publish"
PY="$REPO/.venv/bin/python"
WT="${TMPDIR:-/private/tmp}/rofront-publish-wt"

cd "$REPO" || exit 1
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
	echo "note: uncommitted working-tree changes are NOT published (what ships is HEAD, from a clean worktree)"
fi
REF=HEAD
if [[ "${1:-}" == "--ref" ]]; then
	REF="${2:?commit}"; shift 2
fi
HEAD_SHA=$(git rev-parse --short "$REF") || exit 1

# Studio window for the published place (title "<name> - Roblox Studio").
PLACE="${1:-}"
if [[ -z "$PLACE" ]]; then
	if [[ $STAGING == 1 ]]; then
		PLACE=$("$BIN" --list 2>/dev/null | grep -io '"Rofront Staging[^"]*- Roblox Studio"' | head -1 | sed -e 's/^"//' -e 's/ - Roblox Studio"$//')
	else
		# (any case: production's window was "RoFront [World PvP]", and is "RoWorld [World PvP]" once Studio
		# reopens it after the experience's rename on 2026-10-25; the place id below decides in the end)
		PLACE=$("$BIN" --list 2>/dev/null | grep -ioE '"(Rofront|RoWorld)[^"]*- Roblox Studio"' | grep -vi '"Rofront Staging' | head -1 | sed -e 's/^"//' -e 's/ - Roblox Studio"$//')
	fi
fi
if [[ -z "$PLACE" ]]; then
	echo "no Rofront Studio window found (open the published place in Studio: Creator Dashboard → Rofront → Edit in Studio)"
	exit 3
fi

# MCP id of that window (by place id, so a stale window title can't pick the wrong instance).
SID=$("$PY" - <<PY
import json, sys
sys.path.insert(0, "$REPO/tools")
import studio
c = studio.Client()
try:
    d = json.loads(studio.text_of(c.call("list_roblox_studios", {})))
    ids = [s["id"] for s in d.get("studios", []) if "placeId: $PLACE_ID" in (s.get("name") or "")]
    print(ids[0] if len(ids) == 1 else "")
finally:
    c.close()
PY
)
if [[ -z "$SID" ]]; then
	echo "expected exactly one Studio instance with placeId $PLACE_ID"
	exit 3
fi
export STUDIO_ID="$SID" STUDIO_ALLOW_PUBLISHED=1

state=$("$PY" "$REPO/tools/studio.py" call get_studio_state '{}' 2>&1)
if ! echo "$state" | grep -q "Mode: Edit"; then
	echo "refusing: Studio is not in Edit mode (stop the playtest first)"; echo "$state"; exit 1
fi

# Clean HEAD → Studio.
# (a worktree of a repository that is gone, e.g. after .git was re-created, is rebuilt)
if git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
	git -C "$WT" checkout -q --detach "$HEAD_SHA" || exit 1
else
	rm -rf "$WT"; git worktree add -f --detach "$WT" "$HEAD_SHA" >/dev/null || exit 1
fi
ln -sfn "$REPO/.bin" "$WT/.bin"
"$PY" "$WT/tools/sync.py" --full || exit 1
check=$(sed "s/__PLACE_ID__/$PLACE_ID/" <<'LUA' | "$PY" "$REPO/tools/studio.py" luau Edit -
if tostring(game.PlaceId) ~= "__PLACE_ID__" then return "WRONG PLACE " .. game.PlaceId end
for _, p in ipairs({ game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("AirfrontClient"), game:GetService("ServerScriptService"):FindFirstChild("AirfrontServer") }) do
	local d = p and p:FindFirstChild("Dev")
	if d then d:Destroy() end
end
if workspace:GetAttribute("AF_DEV") ~= nil or workspace:GetAttribute("AF_DIAG") ~= nil or workspace:GetAttribute("AF_DEV_NO_EDITABLE") ~= nil then
	return "DEV ATTRIBUTES SET"
end
return "OK " .. game.PlaceId
LUA
)
echo "preflight: $check"
[[ "$check" == OK* ]] || exit 1

start=$(date -u +%Y-%m-%dT%H:%M:%S)
# (Studio renamed File -> "Publish to Roblox" to "Publish" by 2026-10-15; the helper's default is the old
# name, and it presses nothing when the item isn't there, so the new name is tried after)
if ! out=$("$BIN" --place "$PLACE" 2>&1); then
	if [[ "$out" == *'no "Publish to Roblox" in File'* ]]; then
		"$BIN" --place "$PLACE" --item "Publish" || exit $?
	else
		echo "$out"
		exit 1
	fi
fi
for i in {1..60}; do
	line=$(grep -hF "Published new changes in \"$PLACE\"" ~/Library/Logs/Roblox/*Studio*_last.log 2>/dev/null | sort | tail -1)
	ts=${line%%.*}
	if [[ -n "$line" && "$ts" > "$start" || -n "$line" && "$ts" == "$start" ]]; then
		ver=$(grep -h "Add publish notes to v" ~/Library/Logs/Roblox/*Studio*_last.log | sort | tail -1 | grep -o "v[0-9]*$")
		echo "PUBLISHED \"$PLACE\" $ver at $ts UTC (HEAD $HEAD_SHA)"
		# (a staging publish is a test build: the branch is pushed when it goes to production)
		if [[ $STAGING == 0 && -n "$(git -C "$REPO" remote)" ]]; then
			if git -C "$REPO" push --quiet 2>&1; then
				echo "PUSHED $(git -C "$REPO" rev-parse --abbrev-ref HEAD) @ $HEAD_SHA"
			else
				echo "PUSH FAILED (publish itself succeeded)"
			fi
		fi
		exit 0
	fi
	sleep 2
done
echo "no publish confirmation in the Studio log within 120 s"
exit 1
