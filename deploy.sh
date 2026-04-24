#!/bin/bash
# Production deploy script — run on the server or triggered via CI.
# Pulls latest main, rebuilds changed images, does a rolling restart.
set -euo pipefail

COMPOSE="docker compose -f docker-compose.selfhost.yml -f docker-compose.selfhost.build.yml"

echo "[deploy] $(date) — starting"

cd "$(dirname "$0")"

git pull origin main

echo "[deploy] building backend + frontend"
$COMPOSE build backend frontend

echo "[deploy] restarting services"
$COMPOSE up -d --no-deps --remove-orphans backend frontend

echo "[deploy] waiting for backend health"
for i in $(seq 1 30); do
  if docker inspect multica-backend-1 --format '{{.State.Status}}' 2>/dev/null | grep -q "running"; then
    break
  fi
  sleep 2
done

$COMPOSE ps
echo "[deploy] done — $(date)"
