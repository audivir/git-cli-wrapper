#!/usr/bin/env bash
# Starts a throwaway Gitea in Docker and runs the OAuth end-to-end test against it.
# Needs docker, uv, and gt in PATH. GITEA_PORT changes the port (default 3000).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PORT="${GITEA_PORT:-3000}"
NAME="git-cli-wrapper-e2e-gitea"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker run -d --name "$NAME" -p "$PORT:3000" \
  -e GITEA__security__INSTALL_LOCK=true \
  -e "GITEA__server__ROOT_URL=http://localhost:$PORT/" \
  -e GITEA__server__DOMAIN=localhost \
  gitea/gitea:latest >/dev/null

for _ in $(seq 1 60); do
  curl -fsS "http://localhost:$PORT/api/v1/version" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://localhost:$PORT/api/v1/version" >/dev/null || {
  echo "gitea did not start" >&2
  exit 1
}

docker exec -u git "$NAME" gitea admin user create --username tester --password 'Test-pass-123' \
  --email tester@example.test --admin --must-change-password=false >/dev/null

uv run --with playwright playwright install chromium >/dev/null
GITEA_URL="http://localhost:$PORT" uv run "$HERE/oauth.py"
