#!/bin/zsh
# Asks Roblox to restart production's servers that run an outdated place version, after a delay
# (Open Cloud "Restart Universe Servers", the Creator Dashboard's Server Management -> Restart Servers
# with "Delay server restart"): matchmaking to those servers stops at once, they stay up for the delay
# so matches can finish, then their players are moved to servers of the new version.
#
# Usage: tools/restart_servers.sh [minutes]     (1-60, default 60; 0 = at once, which cuts matches short)
# Run it after tools/publish.sh has confirmed the publish. Servers already on the newest version are
# left alone (closeAllVersions = false). The key is .secrets/roblox_api_key (scope universe:write).
set -u
REPO="${0:A:h:h}"
UNIVERSE=10768172922
MIN="${1:-60}"
[[ "$MIN" == <0-60> ]] || { echo "minutes must be 0 to 60"; exit 2; }
if [[ "$MIN" == 0 ]]; then
	BODY='{"closeAllVersions": false, "bleedOffServers": false}'
else
	BODY="{\"closeAllVersions\": false, \"bleedOffServers\": true, \"bleedOffDurationMinutes\": $MIN}"
fi
# (${UNIVERSE} in braces: zsh reads a bare $UNIVERSE:r... as the :r modifier and eats the "r", and
# the call went to a URL that does not exist: HTTP 404 on its first run, 2026-10-08)
out=$(curl -s --max-time 30 -X POST "https://apis.roblox.com/cloud/v2/universes/${UNIVERSE}:restartServers" \
	-H "x-api-key: $(cat "$REPO/.secrets/roblox_api_key")" -H "Content-Type: application/json" \
	-d "$BODY" -w "\nHTTP %{http_code}")
code="${out##*HTTP }"
if [[ "$code" == 200 ]]; then
	echo "RESTART asked at $(date -u +%Y-%m-%dT%H:%M:%SZ): outdated servers of universe $UNIVERSE close in $MIN min"
else
	echo "restart refused: ${out[1,400]}"; exit 1
fi
