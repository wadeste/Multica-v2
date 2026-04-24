#!/bin/bash
# Staging deploy script — runs on the staging server via self-hosted runner.
set -euo pipefail

COMPOSE="docker compose -f docker-compose.selfhost.yml -f docker-compose.selfhost.build.yml -f docker-compose.staging.yml"

echo "[staging] $(date) — starting"

cd "$(dirname "$0")"

git pull origin staging

echo "[staging] building backend + frontend"
$COMPOSE build backend frontend

echo "[staging] restarting services"
$COMPOSE up -d --no-deps --remove-orphans backend frontend

$COMPOSE ps
echo "[staging] done — $(date)"
