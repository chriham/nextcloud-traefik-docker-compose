#!/bin/bash

# Nextcloud Host Cron Script (Standard für neue Installationen)
# Wird vom Host-System Cron ausgeführt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Docker Compose Command detection
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
    echo "[$TIMESTAMP] WARNING: Verwende veraltetes 'docker-compose'. Empfehlung: Verwende 'docker compose'"
else
    echo "[$TIMESTAMP] ERROR: Docker Compose nicht gefunden"
    exit 1
fi

# Logging
log() {
    echo "[$TIMESTAMP] $1" | tee -a "$SCRIPT_DIR/logs/nextcloud-cron.log"
}

# Erstelle Log-Verzeichnis falls nicht vorhanden
mkdir -p "$SCRIPT_DIR/logs"

log "Starting Nextcloud cron via OCC..."

# Wechsle ins Nextcloud-Verzeichnis
cd "$SCRIPT_DIR"

# Führe Nextcloud Background Jobs über OCC aus
if $DOCKER_COMPOSE exec -T app php occ background:cron --no-interaction 2>&1 | tee -a "$SCRIPT_DIR/logs/nextcloud-cron.log"; then
    log "Nextcloud cron completed successfully"
    exit 0
else
    log "ERROR: Nextcloud cron failed"
    exit 1
fi
