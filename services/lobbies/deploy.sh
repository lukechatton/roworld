#!/bin/zsh
# Deploys the lobby service to easy-1 (~/rofront-lobbies) and (re)starts ONLY the pm2 app
# "rofront-lobbies". easy-1 is shared company infrastructure: this script never touches another pm2
# app, container, the Caddyfile, the firewall or any database, and never runs `pm2 save` (that
# rewrites everyone's saved process list: the box owner decides; docs/lobby-service.md "Ops").
#
#   services/lobbies/deploy.sh              build + test + upload + reload
#   services/lobbies/deploy.sh --env FILE   also upload FILE as ~/rofront-lobbies/.env (chmod 600)
set -eu
HOST=${RL_HOST:-ubuntu@54.39.159.132}
DIR=rofront-lobbies
cd "${0:A:h}"
ENVFILE=""
if [[ "${1:-}" == "--env" ]]; then ENVFILE="${2:?env file}"; fi

npm test >/dev/null || { echo "tests failed: not deploying"; npm test 2>&1 | tail -30; exit 1; }
ssh -o BatchMode=yes "$HOST" "mkdir -p ~/$DIR && chmod 700 ~/$DIR"
rsync -a --delete --exclude test dist/ "$HOST:$DIR/dist/"
rsync -a package.json ecosystem.config.cjs "$HOST:$DIR/"
if [[ -n "$ENVFILE" ]]; then
	scp -q "$ENVFILE" "$HOST:$DIR/.env"
fi
ssh "$HOST" 'set -e; source ~/.nvm/nvm.sh >/dev/null 2>&1; cd ~/rofront-lobbies; test -f .env || { echo "missing ~/rofront-lobbies/.env"; exit 1; }; chmod 600 .env
if pm2 describe rofront-lobbies >/dev/null 2>&1; then pm2 reload ecosystem.config.cjs --only rofront-lobbies --update-env >/dev/null; echo reloaded; else pm2 start ecosystem.config.cjs --only rofront-lobbies >/dev/null; echo started; fi
sleep 1.5; pm2 describe rofront-lobbies | grep -E "status|restarts|uptime" | head -3; curl -s -m 3 http://127.0.0.1:$(grep ^PORT= .env | cut -d= -f2)/health; echo'
