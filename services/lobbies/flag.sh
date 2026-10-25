#!/bin/zsh
# The lobby service's kill switch on easy-1 (no restart: the service re-reads it every 2 s).
#   services/lobbies/flag.sh             show it
#   services/lobbies/flag.sh LOBBIES 0   every hub goes back to MemoryStore within one list (3 s)
#   services/lobbies/flag.sh LOBBIES 1   back on the service
# Lobbies already made on one side keep running there (a match server updates the store its lobby
# lives in). docs/lobby-service.md "Switch".
set -eu
HOST=${RL_HOST:-ubuntu@54.39.159.132}
if [[ $# -eq 0 ]]; then
	ssh -o BatchMode=yes "$HOST" 'grep -E "^(PORT|LOBBIES|LOG_LEVEL)=" ~/rofront-lobbies/.env || true'
	exit 0
fi
KEY=$1; VAL=${2:?value 0 or 1}
[[ "$KEY" == "LOBBIES" ]] || { echo "unknown switch $KEY"; exit 2; }
[[ "$VAL" == "0" || "$VAL" == "1" ]] || { echo "value must be 0 or 1"; exit 2; }
ssh -o BatchMode=yes "$HOST" "set -e; cd ~/rofront-lobbies; if grep -q '^$KEY=' .env; then sed -i 's/^$KEY=.*/$KEY=$VAL/' .env; else echo '$KEY=$VAL' >> .env; fi; chmod 600 .env; sleep 2.5
grep -E '^LOBBIES=' .env; curl -s -m 3 http://127.0.0.1:\$(grep ^PORT= .env | cut -d= -f2)/health | head -c 200; echo"
