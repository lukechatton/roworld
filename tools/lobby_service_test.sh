#!/bin/zsh
# Runs the lobby service's own tests, then the game's lobby code against a real service on this Mac:
# builds services/lobbies, starts it on a free port with a throwaway secret, runs
# tests/lobby_service.luau (Lune), flips the service's LOBBIES switch off and runs the switch check.
set -eu
REPO="${0:A:h:h}"
SVC="$REPO/services/lobbies"
(cd "$SVC" && npm test >/dev/null) || { echo "service tests failed"; (cd "$SVC" && npm test 2>&1 | tail -30); exit 1; }
echo "service tests: ok"
DIR=$(mktemp -d)
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
SECRET=$(openssl rand -hex 32)
printf 'RL_SECRET=%s\nPORT=%s\nHOST=127.0.0.1\nSTATE_FILE=off\nLOG_LEVEL=warn\n' "$SECRET" "$PORT" > "$DIR/.env"
RL_DIR="$DIR" node "$SVC/dist/src/main.js" > "$DIR/service.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$DIR"' EXIT
for _ in {1..50}; do curl -s -m 1 "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 0.1; done
cd "$REPO"
RL_TEST_URL="http://127.0.0.1:$PORT" RL_TEST_SECRET="$SECRET" RL_TEST_VERBOSE="${RL_TEST_VERBOSE:-0}" .bin/lune run tests/lobby_service.luau
sed -i '' 's/^LOBBIES=.*//' "$DIR/.env"; echo "LOBBIES=0" >> "$DIR/.env"
sleep 2.5
RL_TEST_URL="http://127.0.0.1:$PORT" RL_TEST_SECRET="$SECRET" RL_TEST_OFF=1 .bin/lune run tests/lobby_service.luau
echo "--- service health"; curl -s "http://127.0.0.1:$PORT/health"; echo
if [[ -s "$DIR/service.log" ]]; then echo "--- service log"; cat "$DIR/service.log"; fi
