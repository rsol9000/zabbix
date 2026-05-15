#!/usr/bin/env bash
# Always run from the repo root, regardless of where the script is invoked from

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"

export DOCKER_GID=$(getent group docker | cut -d: -f3)
echo "🐳 Docker GID: $DOCKER_GID"

#############################################################################################################
####################################    CHECK OPENSSL    ####################################################
#############################################################################################################

if ! command -v openssl &> /dev/null; then
  echo "🔧 Installing openssl..."
  command -v apt-get &> /dev/null && apt-get update -qq && apt-get install -y -qq openssl
  command -v apk &> /dev/null && apk add --no-cache openssl
  command -v yum &> /dev/null && yum install -y -q openssl
fi

command -v openssl &> /dev/null || { echo "❌ openssl required"; exit 1; }
echo "✅ openssl ready: $(openssl version | cut -d' ' -f1-2)"

#generar certificados TLS para el agente
openssl rand -hex 32 > psk/zabbix_agentd.psk


docker compose -f "$COMPOSE_FILE" up -d "$@"