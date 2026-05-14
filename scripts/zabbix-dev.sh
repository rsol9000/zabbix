#!/usr/bin/env bash
# Always run from the repo root, regardless of where the script is invoked from

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"

export DOCKER_GID=$(getent group docker | cut -d: -f3)
echo "🐳 Docker GID: $DOCKER_GID"

docker compose -f "$COMPOSE_FILE" up -d "$@"