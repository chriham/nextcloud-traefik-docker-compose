#!/bin/bash

# Nextcloud Zero-Downtime Update Script
# Aktualisiert Container mit minimaler Ausfallzeit

set -euo pipefail

# Konfiguration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/nextcloud-caddy-docker-compose.yml"
COMPOSE_PROJECT="nextcloud-caddy"
BACKUP_SCRIPT="${SCRIPT_DIR}/backup-nextcloud.sh"

# Update-Strategie Konfiguration
BACKUP_BEFORE_UPDATE=true
ROLLBACK_ON_FAILURE=true
HEALTH_CHECK_TIMEOUT=300  # 5 Minuten
HEALTH_CHECK_INTERVAL=10  # 10 Sekunden

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

# Hilfsfunktionen
check_prerequisites() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker ist nicht installiert"
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        log_error "Docker Compose ist nicht installiert"
        exit 1
    fi
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "Docker Compose Datei nicht gefunden: $COMPOSE_FILE"
        exit 1
    fi
    
    if [[ ! -f ".env" ]]; then
        log_error ".env Datei nicht gefunden"
        exit 1
    fi
}

get_current_images() {
    local service="$1"
    docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" images -q "$service" 2>/dev/null | head -1
}

get_service_status() {
    local service="$1"
    docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" ps -q "$service" 2>/dev/null | \
        xargs -r docker inspect --format='{{.State.Status}}' 2>/dev/null | head -1 || echo "not_found"
}

wait_for_service_health() {
    local service="$1"
    local timeout="$2"
    local interval="$3"
    local elapsed=0
    
    log_info "Warte auf Gesundheitsstatus von $service..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(get_service_status "$service")
        
        case "$status" in
            "running")
                # Überprüfe Health Check falls verfügbar
                local health
                health=$(docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" ps -q "$service" 2>/dev/null | \
                    xargs -r docker inspect --format='{{.State.Health.Status}}' 2>/dev/null | head -1 || echo "none")
                
                if [[ "$health" == "healthy" ]] || [[ "$health" == "none" ]]; then
                    log_success "$service ist gesund"
                    return 0
                fi
                ;;
            "not_found")
                log_error "$service Container nicht gefunden"
                return 1
                ;;
        esac
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -n "."
    done
    
    echo ""
    log_error "$service wurde nicht innerhalb von ${timeout}s gesund"
    return 1
}

create_backup_containers() {
    local service="$1"
    local timestamp="$2"
    
    log_info "Erstelle Backup-Container für $service..."
    
    local container_id
    container_id=$(docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" ps -q "$service")
    
    if [[ -n "$container_id" ]]; then
        # Stoppe Container (falls laufend)
        docker stop "$container_id" 2>/dev/null || true
        
        # Erstelle Backup-Image
        local backup_image="${COMPOSE_PROJECT}_${service}_backup_${timestamp}"
        if docker commit "$container_id" "$backup_image"; then
            log_success "Backup-Image erstellt: $backup_image"
            
            # Benenne Container um
            local backup_container="${COMPOSE_PROJECT}_${service}_backup_${timestamp}"
            docker rename "$container_id" "$backup_container" 2>/dev/null || true
            
            return 0
        else
            log_error "Konnte Backup-Image für $service nicht erstellen"
            return 1
        fi
    else
        log_warning "Kein Container für $service gefunden"
        return 1
    fi
}

rollback_service() {
    local service="$1"
    local timestamp="$2"
    
    log_warning "Starte Rollback für $service..."
    
    # Stoppe aktuellen (fehlerhaften) Container
    docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" stop "$service" 2>/dev/null || true
    docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" rm -f "$service" 2>/dev/null || true
    
    # Stelle Backup-Container wieder her
    local backup_container="${COMPOSE_PROJECT}_${service}_backup_${timestamp}"
    local target_container="${COMPOSE_PROJECT}_${service}_1"
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${backup_container}$"; then
        # Benenne Backup-Container zurück
        docker rename "$backup_container" "$target_container"
        
        # Starte Container
        docker start "$target_container"
        
        if wait_for_service_health "$service" 60 5; then
            log_success "Rollback für $service erfolgreich"
            return 0
        else
            log_error "Rollback für $service fehlgeschlagen"
            return 1
        fi
    else
        log_error "Backup-Container für $service nicht gefunden"
        return 1
    fi
}

update_single_service() {
    local service="$1"
    local timestamp="$2"
    local force_update="${3:-false}"
    
    log_info "Starte Update für Service: $service"
    
    # Aktuelle Image-ID abrufen
    local current_image
    current_image=$(get_current_images "$service")
    
    # Neues Image pullen
    log_info "Lade neues Image für $service..."
    if ! docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" pull "$service"; then
        log_error "Konnte neues Image für $service nicht laden"
        return 1
    fi
    
    # Neue Image-ID abrufen
    local new_image
    new_image=$(docker-compose -f "$COMPOSE_FILE" images -q "$service" | head -1)
    
    # Überprüfe ob Update notwendig
    if [[ "$current_image" == "$new_image" ]] && [[ "$force_update" != "true" ]]; then
        log_info "$service ist bereits aktuell"
        return 0
    fi
    
    log_info "Image-Update erkannt für $service"
    log_info "Alt: $current_image"
    log_info "Neu: $new_image"
    
    # Erstelle Backup-Container
    if ! create_backup_containers "$service" "$timestamp"; then
        log_error "Konnte Backup für $service nicht erstellen"
        return 1
    fi
    
    # Starte neuen Container
    log_info "Starte neuen Container für $service..."
    if ! docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" up -d "$service"; then
        log_error "Konnte neuen Container für $service nicht starten"
        
        if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
            rollback_service "$service" "$timestamp"
        fi
        return 1
    fi
    
    # Warte auf Gesundheitsstatus
    if wait_for_service_health "$service" "$HEALTH_CHECK_TIMEOUT" "$HEALTH_CHECK_INTERVAL"; then
        log_success "Update für $service erfolgreich"
        
        # Bereinige Backup-Container (optional)
        local cleanup_backup
        read -p "Backup-Container für $service löschen? (y/N): " -r cleanup_backup
        if [[ $cleanup_backup =~ ^[Yy]$ ]]; then
            cleanup_backup_containers "$service" "$timestamp"
        fi
        
        return 0
    else
        log_error "Gesundheitscheck für $service fehlgeschlagen"
        
        if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
            rollback_service "$service" "$timestamp"
        fi
        return 1
    fi
}

cleanup_backup_containers() {
    local service="$1"
    local timestamp="$2"
    
    log_info "Bereinige Backup-Container für $service..."
    
    local backup_container="${COMPOSE_PROJECT}_${service}_backup_${timestamp}"
    local backup_image="${COMPOSE_PROJECT}_${service}_backup_${timestamp}"
    
    # Entferne Backup-Container
    docker rm "$backup_container" 2>/dev/null || true
    
    # Entferne Backup-Image
    docker rmi "$backup_image" 2>/dev/null || true
    
    log_success "Backup-Container für $service bereinigt"
}

perform_nextcloud_upgrade() {
    log_info "Führe Nextcloud-Upgrade durch..."
    
    # Aktiviere Wartungsmodus
    log_info "Aktiviere Wartungsmodus..."
    docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app \
        php occ maintenance:mode --on || log_warning "Konnte Wartungsmodus nicht aktivieren"
    
    # Führe Nextcloud-Upgrade durch
    log_info "Starte Nextcloud-Upgrade..."
    if docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app \
        php occ upgrade; then
        log_success "Nextcloud-Upgrade erfolgreich"
    else
        log_error "Nextcloud-Upgrade fehlgeschlagen"
        return 1
    fi
    
    # Deaktiviere Wartungsmodus
    log_info "Deaktiviere Wartungsmodus..."
    docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app \
        php occ maintenance:mode --off || log_warning "Konnte Wartungsmodus nicht deaktivieren"
    
    # Führe zusätzliche Wartungsaufgaben durch
    log_info "Führe Wartungsaufgaben durch..."
    docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app php occ db:add-missing-indices
    docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app php occ db:convert-filecache-bigint
    docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app php occ maintenance:repair
    
    log_success "Nextcloud-Upgrade und Wartung abgeschlossen"
}

show_update_summary() {
    log_info "Update-Zusammenfassung:"
    echo ""
    
    local services=("app" "web" "proxy" "postgres" "redis" "cron" "notify_push" "imaginary")
    
    for service in "${services[@]}"; do
        local status
        status=$(get_service_status "$service")
        
        local image
        image=$(docker-compose -f "$COMPOSE_FILE" images "$service" 2>/dev/null | tail -n +2 | awk '{print $4}' || echo "N/A")
        
        echo "  $service: $status ($image)"
    done
    echo ""
}

# Hauptfunktion
main() {
    local update_type="${1:-all}"
    local force_update="${2:-false}"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    
    echo -e "${BLUE}"
    cat << "EOF"
  _   _           _       _                 _   _    _           _       _       
 | \ | |         | |     | |               | | | |  | |         | |     | |      
 |  \| | _____  _| |_ ___| | ___  _   _  __| | | |  | |_ __   __| | __ _| |_ ___ 
 | . ` |/ _ \ \/ / __/ __| |/ _ \| | | |/ _` | | |  | | '_ \ / _` |/ _` | __/ _ \
 | |\  |  __/>  <| || (__| | (_) | |_| | (_| | | |__| | |_) | (_| | (_| | ||  __/
 \_| \_/\___/_/\_\\__\___|_|\___/ \__,_|\__,_|  \____/| .__/ \__,_|\__,_|\__\___|
                                                       | |                       
                                                       |_|                       
EOF
    echo -e "${NC}"
    
    log_info "Nextcloud Update gestartet (Typ: $update_type, Timestamp: $timestamp)"
    
    # Überprüfungen
    check_prerequisites
    
    # Pre-Update Backup
    if [[ "$BACKUP_BEFORE_UPDATE" == "true" ]]; then
        log_info "Erstelle Pre-Update Backup..."
        if [[ -x "$BACKUP_SCRIPT" ]]; then
            "$BACKUP_SCRIPT" full
        else
            log_warning "Backup-Script nicht gefunden oder nicht ausführbar"
        fi
    fi
    
    # Update-Strategie
    case "$update_type" in
        "all"|"")
            # Reihenfolge für minimale Downtime
            local services=("redis" "postgres" "imaginary" "notify_push" "app" "web" "proxy" "cron")
            
            for service in "${services[@]}"; do
                if docker-compose -f "$COMPOSE_FILE" ps | grep -q "$service"; then
                    update_single_service "$service" "$timestamp" "$force_update" || {
                        log_error "Update für $service fehlgeschlagen"
                        exit 1
                    }
                else
                    log_info "Service $service läuft nicht, überspringe..."
                fi
            done
            
            # Nextcloud-spezifische Upgrades
            perform_nextcloud_upgrade
            ;;
        "nextcloud")
            update_single_service "app" "$timestamp" "$force_update"
            perform_nextcloud_upgrade
            ;;
        "proxy")
            update_single_service "proxy" "$timestamp" "$force_update"
            ;;
        "database"|"db")
            update_single_service "postgres" "$timestamp" "$force_update"
            ;;
        *)
            if docker-compose -f "$COMPOSE_FILE" ps | grep -q "$update_type"; then
                update_single_service "$update_type" "$timestamp" "$force_update"
            else
                log_error "Unbekannter Service: $update_type"
                echo "Verfügbare Services: all, nextcloud, proxy, database, redis, cron, notify_push, imaginary"
                exit 1
            fi
            ;;
    esac
    
    # Post-Update Überprüfungen
    show_update_summary
    
    log_success "Update abgeschlossen!"
    log_info "Überprüfen Sie die Anwendung unter: https://$(grep NEXTCLOUD_HOSTNAME .env | cut -d= -f2)"
}

# Script-Aufruf
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
