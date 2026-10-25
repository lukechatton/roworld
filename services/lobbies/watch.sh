#!/bin/zsh
# Follows the lobby service's log on easy-1 (Ctrl-C to stop) with /health first. Our app only.
#   services/lobbies/watch.sh [lines=40]
HOST=${RL_HOST:-ubuntu@54.39.159.132}
ssh -o BatchMode=yes "$HOST" 'curl -s -m 5 http://127.0.0.1:$(grep ^PORT= ~/rofront-lobbies/.env | cut -d= -f2)/health'; echo
ssh -o BatchMode=yes "$HOST" "tail -n ${1:-40} -F \$(ls -t ~/.pm2/logs/rofront-lobbies-out*.log | head -1) \$(ls -t ~/.pm2/logs/rofront-lobbies-error*.log | head -1)"
