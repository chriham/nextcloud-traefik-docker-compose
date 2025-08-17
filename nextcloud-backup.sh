#!/bin/bash

# Nextcloud Backup Management Script
# Konsolidiertes Backup-System mit Verschlüsselung und Entschlüsselung

set -euo pipefail

# Konfiguration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-${SCRIPT_DIR}/backups}"
COMPOSE_FILE="${SCRIPT_DIR}/nextcloud-caddy-docker-compose.yml"
COMPOSE_PROJECT="nextcloud-caddy"

# Docker Compose Command detection
if docker compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
    log_warning "Verwende veraltetes 'docker-compose'. Empfehlung: Verwende 'docker compose'"
else
    log_error "Docker Compose nicht gefunden"
    exit 1
fi
DATE_FORMAT="%Y%m%d_%H%M%S"
TIMESTAMP=$(date +"$DATE_FORMAT")

# Retention (Tage)
DB_RETENTION_DAYS=${DB_RETENTION_DAYS:-7}
DATA_RETENTION_DAYS=${DATA_RETENTION_DAYS:-7}
CONFIG_RETENTION_DAYS=${CONFIG_RETENTION_DAYS:-30}

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

show_banner() {
    echo -e "${BLUE}"
    cat << "EOF"
  _   _           _       _                 _   ____             _                
 | \ | |         | |     | |               | | |  _ \           | |               
 |  \| | _____  _| |_ ___| | ___  _   _  __| | | |_) | __ _  ___| | ___   _ _ __  
 | . ` |/ _ \ \/ / __/ __| |/ _ \| | | |/ _` | |  _ < / _` |/ __| |/ / | | | '_ \ 
 | |\  |  __/>  <| || (__| | (_) | |_| | (_| | | |_) | (_| | (__|   <| |_| | |_) |
 \_| \_/\___/_/\_\\__\___|_|\___/ \__,_|\__,_| |____/ \__,_|\___|_|\_\\__,_| .__/ 
                                                                           | |    
                                                                           |_|    
EOF
    echo -e "${NC}"
}

show_usage() {
    echo "Nextcloud Backup Management Script"
    echo ""
    echo "Usage: $0 [action] [options]"
    echo ""
    echo "Aktionen:"
    echo "  create [type]     Backup erstellen"
    echo "  decrypt <file>    Backup entschlüsseln"
    echo "  list [type]       Backups auflisten"
    echo "  cleanup           Alte Backups bereinigen"
    echo "  status            Backup-Status anzeigen"
    echo "  interactive       Interaktives Menü (Standard)"
    echo ""
    echo "Backup-Typen:"
    echo "  full              Vollständiges Backup (Standard)"
    echo "  database          Nur Datenbank"
    echo "  data              Nur Nextcloud-Dateien"
    echo "  config            Nur Konfiguration"
    echo "  volumes           Nur Docker Volumes"
    echo "  logs              Nur Container-Logs"
    echo ""
    echo "Beispiele:"
    echo "  $0                                    # Interaktives Menü"
    echo "  $0 create full                       # Vollständiges Backup"
    echo "  $0 create database                   # Nur Datenbank"
    echo "  $0 decrypt backup.sql.gz             # Backup entschlüsseln"
    echo "  $0 list database                     # Datenbank-Backups auflisten"
    echo "  $0 cleanup                           # Alte Backups löschen"
}

# =============================================================================
# HILFSFUNKTIONEN
# =============================================================================

check_prerequisites() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker ist nicht installiert oder nicht verfügbar"
        exit 1
    fi
    
    # Docker Compose check is done at script start
}

check_gpg_availability() {
    if [[ "${BACKUP_GPG_ENCRYPTION:-false}" == "true" ]]; then
        if ! command -v gpg &> /dev/null; then
            log_error "GPG ist nicht installiert, aber GPG-Verschlüsselung ist aktiviert"
            log_info "Installation: sudo apt install gnupg (Ubuntu/Debian) oder brew install gnupg (macOS)"
            exit 1
        fi
        
        if [[ -z "${BACKUP_GPG_RECIPIENTS:-}" ]]; then
            log_error "GPG-Verschlüsselung ist aktiviert, aber keine Empfänger konfiguriert"
            log_info "Führen Sie 'nextcloud-manager.sh setup-gpg' aus oder setzen Sie BACKUP_GPG_RECIPIENTS in .env"
            exit 1
        fi
        
        log_info "GPG-Verschlüsselung aktiviert für: ${BACKUP_GPG_ENCRYPT_TYPES:-all}"
    fi
}

should_encrypt_backup() {
    local backup_type="$1"
    
    if [[ "${BACKUP_GPG_ENCRYPTION:-false}" != "true" ]]; then
        return 1  # Keine Verschlüsselung
    fi
    
    local encrypt_types="${BACKUP_GPG_ENCRYPT_TYPES:-all}"
    
    if [[ "$encrypt_types" == "all" ]]; then
        return 0  # Alles verschlüsseln
    fi
    
    if [[ "$encrypt_types" == "none" ]]; then
        return 1  # Nichts verschlüsseln
    fi
    
    # Überprüfe ob Backup-Typ in der Liste ist
    if [[ ",$encrypt_types," == *",$backup_type,"* ]]; then
        return 0  # Verschlüsseln
    fi
    
    return 1  # Nicht verschlüsseln
}

encrypt_file_with_gpg() {
    local input_file="$1"
    local output_file="$2"
    local backup_type="$3"
    
    if ! should_encrypt_backup "$backup_type"; then
        # Keine Verschlüsselung - einfach kopieren oder umbenennen
        if [[ "$input_file" != "$output_file" ]]; then
            mv "$input_file" "$output_file"
        fi
        return 0
    fi
    
    log_info "Verschlüssele $backup_type mit GPG..."
    
    # Parse GPG-Empfänger
    IFS=',' read -ra recipients <<< "${BACKUP_GPG_RECIPIENTS}"
    local gpg_recipients=()
    for recipient in "${recipients[@]}"; do
        # Entferne Leerzeichen
        recipient="${recipient// /}"
        if [[ -n "$recipient" ]]; then
            gpg_recipients+=("-r" "$recipient")
        fi
    done
    
    if [[ ${#gpg_recipients[@]} -eq 0 ]]; then
        log_error "Keine gültigen GPG-Empfänger gefunden"
        return 1
    fi
    
    # GPG-Verschlüsselung
    local gpg_homedir="${BACKUP_GPG_HOMEDIR:-}"
    local gpg_compression="${BACKUP_GPG_COMPRESSION:-6}"
    local gpg_cipher="${BACKUP_GPG_CIPHER:-AES256}"
    
    local gpg_cmd=(
        "gpg"
        "--trust-model" "always"
        "--compress-algo" "$gpg_compression"
        "--cipher-algo" "$gpg_cipher"
        "--encrypt"
        "${gpg_recipients[@]}"
        "--output" "$output_file.gpg"
        "$input_file"
    )
    
    # Setze GPG-Homedir falls angegeben
    if [[ -n "$gpg_homedir" ]]; then
        gpg_cmd=("gpg" "--homedir" "$gpg_homedir" "${gpg_cmd[@]:1}")
    fi
    
    if "${gpg_cmd[@]}" 2>/dev/null; then
        # Entferne unverschlüsselte Datei
        rm "$input_file"
        
        # Benenne verschlüsselte Datei um
        mv "$output_file.gpg" "$output_file"
        
        log_success "$backup_type GPG-verschlüsselt ($(du -h "$output_file" | cut -f1))"
        return 0
    else
        log_error "GPG-Verschlüsselung für $backup_type fehlgeschlagen"
        return 1
    fi
}

check_container_running() {
    local container_name="$1"
    if ! $DOCKER_COMPOSE -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" ps | grep -q "$container_name.*Up"; then
        log_warning "Container $container_name läuft nicht"
        return 1
    fi
    return 0
}

create_backup_dirs() {
    local dirs=(
        "$BACKUP_BASE_DIR/database"
        "$BACKUP_BASE_DIR/data"
        "$BACKUP_BASE_DIR/config"
        "$BACKUP_BASE_DIR/volumes"
        "$BACKUP_BASE_DIR/logs"
    )
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done
}

# =============================================================================
# BACKUP FUNKTIONEN
# =============================================================================

backup_database() {
    log_info "Starte Datenbank-Backup..."
    
    # Lade Umgebungsvariablen
    source .env 2>/dev/null || {
        log_error "Konnte .env Datei nicht laden"
        return 1
    }
    
    local backup_file="$BACKUP_BASE_DIR/database/nextcloud-db-${TIMESTAMP}.sql.gz"
    
    if [[ "${DATABASE_TYPE:-docker}" == "docker" ]]; then
        # Docker PostgreSQL
        if check_container_running "postgres"; then
            local temp_backup_file="${backup_file%.gz}"
            if $DOCKER_COMPOSE -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T postgres \
                pg_dump -U "$NEXTCLOUD_DB_USER" "$NEXTCLOUD_DB_NAME" | gzip > "$temp_backup_file"; then
                
                # Verschlüssele mit GPG falls konfiguriert
                if encrypt_file_with_gpg "$temp_backup_file" "$backup_file" "database"; then
                    log_success "Datenbank-Backup erstellt: $(basename "$backup_file")"
                    log_info "Backup-Größe: $(du -h "$backup_file" | cut -f1)"
                else
                    log_error "Datenbank-Backup-Verschlüsselung fehlgeschlagen"
                    return 1
                fi
            else
                log_error "Datenbank-Backup fehlgeschlagen"
                return 1
            fi
        else
            log_error "PostgreSQL Container läuft nicht"
            return 1
        fi
    else
        # Externe Datenbank
        log_info "Externe Datenbank erkannt - verwende Host-Tools für Backup"
        if command -v pg_dump &> /dev/null; then
            local db_password
            db_password=$(cat secrets/postgres_password.txt 2>/dev/null || echo "")
            
            if [[ -n "$db_password" ]]; then
                local temp_backup_file="${backup_file%.gz}"
                if PGPASSWORD="$db_password" pg_dump -h "$DB_HOST" -U "$NEXTCLOUD_DB_USER" "$NEXTCLOUD_DB_NAME" | gzip > "$temp_backup_file"; then
                    # Verschlüssele mit GPG falls konfiguriert
                    if encrypt_file_with_gpg "$temp_backup_file" "$backup_file" "database"; then
                        log_success "Externe Datenbank-Backup erstellt: $(basename "$backup_file")"
                    else
                        log_error "Externe Datenbank-Backup-Verschlüsselung fehlgeschlagen"
                        return 1
                    fi
                else
                    log_error "Externe Datenbank-Backup fehlgeschlagen"
                    return 1
                fi
            else
                log_error "Konnte Datenbank-Passwort nicht lesen"
                return 1
            fi
        else
            log_error "pg_dump ist nicht verfügbar für externe Datenbank"
            return 1
        fi
    fi
}

backup_nextcloud_data() {
    log_info "Starte Nextcloud-Daten-Backup..."
    
    source .env 2>/dev/null || {
        log_error "Konnte .env Datei nicht laden"
        return 1
    }
    
    local data_dir="${NEXTCLOUD_DATA_DIR:-./nextcloud-data}"
    local backup_file="$BACKUP_BASE_DIR/data/nextcloud-data-${TIMESTAMP}.tar.gz"
    
    if [[ -d "$data_dir" ]]; then
        # Aktiviere Wartungsmodus
        log_info "Aktiviere Wartungsmodus..."
        if check_container_running "app"; then
            $DOCKER_COMPOSE -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app \
                php occ maintenance:mode --on || log_warning "Konnte Wartungsmodus nicht aktivieren"
        fi
        
        # Erstelle Backup
        local temp_backup_file="${backup_file%.tar.gz}.tar.gz.tmp"
        if tar -czf "$temp_backup_file" -C "$(dirname "$data_dir")" "$(basename "$data_dir")"; then
            # Verschlüssele mit GPG falls konfiguriert
            if encrypt_file_with_gpg "$temp_backup_file" "$backup_file" "data"; then
                log_success "Daten-Backup erstellt: $(basename "$backup_file")"
                log_info "Backup-Größe: $(du -h "$backup_file" | cut -f1)"
            else
                log_error "Daten-Backup-Verschlüsselung fehlgeschlagen"
                return 1
            fi
        else
            log_error "Daten-Backup fehlgeschlagen"
            return 1
        fi
        
        # Deaktiviere Wartungsmodus
        log_info "Deaktiviere Wartungsmodus..."
        if check_container_running "app"; then
            $DOCKER_COMPOSE -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app \
                php occ maintenance:mode --off || log_warning "Konnte Wartungsmodus nicht deaktivieren"
        fi
    else
        log_error "Nextcloud-Daten-Verzeichnis nicht gefunden: $data_dir"
        return 1
    fi
}

backup_nextcloud_config() {
    log_info "Starte Nextcloud-Konfiguration-Backup..."
    
    local backup_file="$BACKUP_BASE_DIR/config/nextcloud-config-${TIMESTAMP}.tar.gz"
    
    # Erstelle temporäres Verzeichnis für Konfiguration
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Kopiere Nextcloud config.php
    if check_container_running "app"; then
        $DOCKER_COMPOSE -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app \
            cat /var/www/html/config/config.php > "$temp_dir/config.php" 2>/dev/null || \
            log_warning "Konnte config.php nicht extrahieren"
    fi
    
    # Kopiere Docker-Konfigurationsdateien
    local config_files=(
        ".env"
        "nextcloud.env"
        "Caddyfile.nextcloud"
        "Caddyfile.proxy"
        "nextcloud-caddy-docker-compose.yml"
        "cron.sh"
    )
    
    for file in "${config_files[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "$temp_dir/"
        fi
    done
    
    # Kopiere secrets (GPG-verschlüsselt oder unverschlüsselt)
    if [[ -d "secrets" ]]; then
        mkdir -p "$temp_dir/secrets"
        
        if should_encrypt_backup "secrets"; then
            log_info "Verschlüssele Secrets mit GPG..."
            
            # Verschlüssele jeden Secret einzeln mit GPG
            for secret_file in secrets/*.txt; do
                if [[ -f "$secret_file" ]]; then
                    local base_name
                    base_name=$(basename "$secret_file" .txt)
                    local temp_secret_file="$temp_dir/secrets/${base_name}.txt"
                    
                    # Kopiere Secret in temporäres Verzeichnis
                    cp "$secret_file" "$temp_secret_file"
                    
                    # Verschlüssele mit GPG
                    local encrypted_secret_file="$temp_dir/secrets/${base_name}.gpg"
                    if encrypt_file_with_gpg "$temp_secret_file" "$encrypted_secret_file" "secrets"; then
                        log_info "Secret GPG-verschlüsselt: $base_name"
                    else
                        log_warning "Konnte $base_name nicht GPG-verschlüsseln"
                        # Fallback: unverschlüsselt speichern
                        cp "$secret_file" "$temp_dir/secrets/${base_name}.txt"
                    fi
                fi
            done
            
            # Erstelle GPG-Entschlüsselungs-Script
            cat > "$temp_dir/secrets/decrypt_secrets_gpg.sh" << 'GPG_DECRYPT_EOF'
#!/bin/bash
# GPG-Entschlüsselungs-Script für Nextcloud Secrets

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v gpg &> /dev/null; then
    echo "FEHLER: GPG ist nicht installiert"
    exit 1
fi

echo "Entschlüssele Secrets mit GPG..."
for gpg_file in "$SCRIPT_DIR"/*.gpg; do
    if [[ -f "$gpg_file" ]]; then
        base_name=$(basename "$gpg_file" .gpg)
        output_file="$SCRIPT_DIR/${base_name}.txt"
        
        if gpg --quiet --decrypt --output "$output_file" "$gpg_file" 2>/dev/null; then
            echo "Entschlüsselt: ${base_name}.txt"
            chmod 600 "$output_file"
        else
            echo "FEHLER: Konnte $base_name nicht entschlüsseln"
            echo "Stellen Sie sicher, dass Sie den passenden privaten Schlüssel haben"
        fi
    fi
done

echo ""
echo "GPG-Entschlüsselung abgeschlossen!"
echo "WARNUNG: Löschen Sie die entschlüsselten Dateien nach Verwendung!"
GPG_DECRYPT_EOF
            
            chmod +x "$temp_dir/secrets/decrypt_secrets_gpg.sh"
            
            # Erstelle README für GPG-verschlüsselte Secrets
            cat > "$temp_dir/secrets/README.txt" << README_EOF
Nextcloud Secrets Backup - GPG-Verschlüsselt
===========================================

Diese Secrets wurden mit GPG verschlüsselt.

ENTSCHLÜSSELUNG:
1. Extrahieren Sie dieses Backup-Archiv
2. Wechseln Sie in das secrets/ Verzeichnis  
3. Führen Sie aus: ./decrypt_secrets_gpg.sh

VORAUSSETZUNGEN:
- GPG muss installiert sein
- Sie benötigen den passenden privaten GPG-Schlüssel
- Der private Schlüssel muss in Ihrem GPG-Keyring sein

VERSCHLÜSSELTE DATEIEN:
$(for f in secrets/*.txt; do [[ -f "$f" ]] && echo "- $(basename "$f" .txt).gpg"; done)

GPG-EMPFÄNGER:
$(echo "${BACKUP_GPG_RECIPIENTS:-}" | tr ',' '\n' | sed 's/^/- /')

VERSCHLÜSSELUNG:
- Cipher: ${BACKUP_GPG_CIPHER:-AES256}
- Kompression: ${BACKUP_GPG_COMPRESSION:-6}

Erstellt: $(date)
Timestamp: $TIMESTAMP
README_EOF
            
            log_success "Secrets mit GPG verschlüsselt"
        else
            # Keine Verschlüsselung - kopiere Secrets unverschlüsselt
            log_info "Kopiere Secrets unverschlüsselt..."
            cp secrets/*.txt "$temp_dir/secrets/" 2>/dev/null || true
            
            # Erstelle einfaches README
            cat > "$temp_dir/secrets/README.txt" << README_EOF
Nextcloud Secrets Backup - Unverschlüsselt
=========================================

Diese Secrets sind UNVERSCHLÜSSELT gesichert.

SICHERHEITSWARNUNG:
- Diese Dateien enthalten sensitive Passwörter
- Bewahren Sie das Backup sicher auf
- Beschränken Sie den Zugriff auf autorisierte Personen

DATEIEN:
$(for f in secrets/*.txt; do [[ -f "$f" ]] && echo "- $(basename "$f")"; done)

Erstellt: $(date)
Timestamp: $TIMESTAMP
README_EOF
            
            log_warning "Secrets unverschlüsselt gesichert - Backup sicher aufbewahren!"
        fi
    fi
    
    # Erstelle Backup-Archiv
    local temp_archive_file="${backup_file%.tar.gz}.tar.gz.tmp"
    if tar -czf "$temp_archive_file" -C "$temp_dir" .; then
        # Verschlüssele mit GPG falls konfiguriert
        if encrypt_file_with_gpg "$temp_archive_file" "$backup_file" "config"; then
            log_success "Konfiguration-Backup erstellt: $(basename "$backup_file")"
            log_info "Backup-Größe: $(du -h "$backup_file" | cut -f1)"
        else
            log_error "Konfiguration-Backup-Verschlüsselung fehlgeschlagen"
            return 1
        fi
    else
        log_error "Konfiguration-Backup fehlgeschlagen"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
}

backup_docker_volumes() {
    log_info "Starte Docker-Volumes-Backup..."
    
    local volumes=(
        "nextcloud-data"
        "redis-data"
        "caddy-data"
        "caddy-config"
    )
    
    for volume in "${volumes[@]}"; do
        local backup_file="$BACKUP_BASE_DIR/volumes/${volume}-${TIMESTAMP}.tar.gz"
        
        if docker volume inspect "${COMPOSE_PROJECT}_${volume}" &>/dev/null; then
            # Erstelle temporären Container für Volume-Backup
            local temp_volume_backup="/backup/${volume}-${TIMESTAMP}.tar.gz.tmp"
            local final_volume_backup="/backup/${volume}-${TIMESTAMP}.tar.gz"
            
            if docker run --rm -v "${COMPOSE_PROJECT}_${volume}:/data" -v "$BACKUP_BASE_DIR/volumes:/backup" \
                alpine:latest tar -czf "$temp_volume_backup" -C /data .; then
                
                # Verschlüssele mit GPG falls konfiguriert
                local host_temp_file="$BACKUP_BASE_DIR/volumes/${volume}-${TIMESTAMP}.tar.gz.tmp"
                local host_final_file="$BACKUP_BASE_DIR/volumes/${volume}-${TIMESTAMP}.tar.gz"
                
                if encrypt_file_with_gpg "$host_temp_file" "$host_final_file" "volumes"; then
                    log_success "Volume-Backup erstellt: ${volume}-${TIMESTAMP}.tar.gz"
                else
                    log_warning "Volume-Backup-Verschlüsselung fehlgeschlagen für: $volume"
                fi
            else
                log_warning "Volume-Backup fehlgeschlagen für: $volume"
            fi
        else
            log_warning "Volume nicht gefunden: ${COMPOSE_PROJECT}_${volume}"
        fi
    done
}

backup_logs() {
    log_info "Starte Container-Logs-Backup..."
    
    local log_backup_dir="$BACKUP_BASE_DIR/logs/$TIMESTAMP"
    mkdir -p "$log_backup_dir"
    
    local services=(
        "app"
        "web"
        "proxy"
        "postgres"
        "redis"
        "cron"
        "notify_push"
    )
    
    for service in "${services[@]}"; do
        if check_container_running "$service"; then
            $DOCKER_COMPOSE -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" logs --no-color "$service" > "$log_backup_dir/${service}.log" 2>/dev/null || \
                log_warning "Konnte Logs für $service nicht exportieren"
        fi
    done
    
    # Komprimiere Logs
    local temp_logs_file="$BACKUP_BASE_DIR/logs/logs-${TIMESTAMP}.tar.gz.tmp"
    local final_logs_file="$BACKUP_BASE_DIR/logs/logs-${TIMESTAMP}.tar.gz"
    
    if tar -czf "$temp_logs_file" -C "$BACKUP_BASE_DIR/logs" "$TIMESTAMP"; then
        rm -rf "$log_backup_dir"
        
        # Verschlüssele mit GPG falls konfiguriert
        if encrypt_file_with_gpg "$temp_logs_file" "$final_logs_file" "logs"; then
            log_success "Container-Logs-Backup erstellt: logs-${TIMESTAMP}.tar.gz"
        else
            log_warning "Container-Logs-Backup-Verschlüsselung fehlgeschlagen"
        fi
    else
        log_error "Container-Logs-Backup fehlgeschlagen"
        rm -rf "$log_backup_dir"
    fi
}

create_backup() {
    local backup_type="${1:-full}"
    
    log_info "Starte Backup (Typ: $backup_type, Timestamp: $TIMESTAMP)"
    
    case "$backup_type" in
        "full"|"")
            backup_database
            backup_nextcloud_data
            backup_nextcloud_config
            backup_docker_volumes
            backup_logs
            ;;
        "database"|"db")
            backup_database
            ;;
        "data")
            backup_nextcloud_data
            ;;
        "config")
            backup_nextcloud_config
            ;;
        "volumes")
            backup_docker_volumes
            ;;
        "logs")
            backup_logs
            ;;
        *)
            log_error "Unbekannter Backup-Typ: $backup_type"
            echo "Verfügbare Typen: full, database, data, config, volumes, logs"
            return 1
            ;;
    esac
    
    log_success "Backup abgeschlossen!"
}

# =============================================================================
# ENTSCHLÜSSELUNG
# =============================================================================

is_encrypted_backup() {
    local file="$1"
    [[ "$file" == *.gpg ]] || file "$file" 2>/dev/null | grep -q "GPG\|PGP"
}

decrypt_backup() {
    local backup_file="$1"
    local output_file="${2:-}"
    
    log_info "Entschlüssele Backup: $(basename "$backup_file")"
    
    # Überprüfe ob Datei existiert
    if [[ ! -f "$backup_file" ]]; then
        log_error "Datei nicht gefunden: $backup_file"
        return 1
    fi
    
    # Überprüfe GPG
    if ! command -v gpg &> /dev/null; then
        log_error "GPG ist nicht installiert"
        echo "Installation: sudo apt install gnupg (Ubuntu/Debian) oder brew install gnupg (macOS)"
        return 1
    fi
    
    # Überprüfe ob GPG-verschlüsselt
    if ! is_encrypted_backup "$backup_file"; then
        log_warning "Datei scheint nicht GPG-verschlüsselt zu sein"
        read -p "Trotzdem versuchen zu entschlüsseln? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    # Bestimme Output-Datei falls nicht angegeben
    if [[ -z "$output_file" ]]; then
        # Entferne .gpg Endung falls vorhanden
        if [[ "$backup_file" == *.gpg ]]; then
            output_file="${backup_file%.gpg}"
        else
            output_file="${backup_file}.decrypted"
        fi
    fi
    
    # Überprüfe ob Output-Datei bereits existiert
    if [[ -f "$output_file" ]]; then
        log_warning "Output-Datei existiert bereits: $output_file"
        read -p "Überschreiben? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    # Zeige GPG-Informationen
    log_info "GPG-Informationen für: $(basename "$backup_file")"
    echo ""
    
    # Zeige GPG-Paket-Informationen
    if gpg --list-packets "$backup_file" 2>/dev/null; then
        echo ""
    else
        log_warning "Konnte GPG-Paket-Informationen nicht anzeigen"
    fi
    
    # Entschlüssele
    log_info "Starte GPG-Entschlüsselung..."
    if gpg --decrypt --output "$output_file" "$backup_file" 2>/dev/null; then
        log_success "Entschlüsselung erfolgreich!"
        log_info "Entschlüsselte Datei: $output_file"
        log_info "Dateigröße: $(du -h "$output_file" | cut -f1)"
        
        # Zeige Datei-Info
        local file_type
        file_type=$(file "$output_file" | cut -d: -f2-)
        log_info "Dateityp:$file_type"
        
        # Zeige nächste Schritte basierend auf Dateityp
        echo ""
        log_info "Nächste Schritte:"
        
        case "$(basename "$output_file")" in
            *.sql.gz)
                echo "1. Datenbank-Backup: gunzip '$output_file' um SQL-Datei zu extrahieren"
                echo "2. Importieren: psql -U user -d database < '${output_file%.gz}'"
                ;;
            *-data-*.tar.gz)
                echo "1. Daten-Backup: tar -xzf '$output_file' um Dateien zu extrahieren"
                echo "2. Dateien in Nextcloud-Datenverzeichnis kopieren"
                ;;
            *-config-*.tar.gz)
                echo "1. Konfigurations-Backup: tar -xzf '$output_file' um Konfiguration zu extrahieren"
                echo "2. Secrets und Konfigurationsdateien überprüfen"
                ;;
            *)
                echo "1. Backup-Inhalt überprüfen: file '$output_file'"
                echo "2. Bei Archiven: tar -tzf '$output_file' (Inhalt anzeigen)"
                ;;
        esac
        
        echo ""
        log_warning "SICHERHEITSHINWEIS:"
        echo "Löschen Sie die entschlüsselte Datei nach Verwendung:"
        echo "rm '$output_file'"
        
        return 0
    else
        log_error "GPG-Entschlüsselung fehlgeschlagen"
        log_info "Mögliche Ursachen:"
        echo "  - Sie haben nicht den passenden privaten Schlüssel"
        echo "  - Der private Schlüssel ist nicht in Ihrem GPG-Keyring"
        echo "  - Die Datei ist beschädigt"
        echo "  - Falsche Passphrase"
        
        # Entferne leere Output-Datei
        [[ -f "$output_file" ]] && rm "$output_file"
        return 1
    fi
}

# =============================================================================
# LISTEN UND STATUS
# =============================================================================

list_backups() {
    local backup_type="${1:-all}"
    
    log_info "Verfügbare Backups (Typ: $backup_type)"
    echo ""
    
    local backup_dirs=()
    case "$backup_type" in
        "all")
            backup_dirs=("database" "data" "config" "volumes" "logs")
            ;;
        "database"|"db")
            backup_dirs=("database")
            ;;
        "data")
            backup_dirs=("data")
            ;;
        "config")
            backup_dirs=("config")
            ;;
        "volumes")
            backup_dirs=("volumes")
            ;;
        "logs")
            backup_dirs=("logs")
            ;;
        *)
            log_error "Unbekannter Backup-Typ: $backup_type"
            return 1
            ;;
    esac
    
    local total_backups=0
    local total_size=0
    
    for backup_dir in "${backup_dirs[@]}"; do
        local dir_path="$BACKUP_BASE_DIR/$backup_dir"
        
        if [[ -d "$dir_path" ]]; then
            echo "=== $backup_dir ==="
            
            local count=0
            local dir_size=0
            
            while IFS= read -r -d '' file; do
                local basename_file
                basename_file=$(basename "$file")
                local filesize_bytes
                filesize_bytes=$(stat -f "%z" "$file" 2>/dev/null || stat -c "%s" "$file" 2>/dev/null)
                local filesize_human
                filesize_human=$(du -h "$file" | cut -f1)
                local timestamp
                timestamp=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null || stat -c "%y" "$file" 2>/dev/null | cut -d. -f1)
                
                local encrypted_marker=""
                if is_encrypted_backup "$file"; then
                    encrypted_marker=" 🔒"
                fi
                
                printf "  %-50s %8s %s%s\n" "$basename_file" "$filesize_human" "$timestamp" "$encrypted_marker"
                
                ((count++))
                ((total_backups++))
                dir_size=$((dir_size + filesize_bytes))
                total_size=$((total_size + filesize_bytes))
            done < <(find "$dir_path" -maxdepth 1 -type f \( -name "*.gz" -o -name "*.gpg" \) -print0 | sort -z)
            
            if [[ $count -eq 0 ]]; then
                echo "  Keine Backups gefunden"
            else
                local dir_size_human
                dir_size_human=$(numfmt --to=iec --suffix=B $dir_size 2>/dev/null || echo "${dir_size}B")
                echo "  Gesamt: $count Backups, $dir_size_human"
            fi
            echo ""
        else
            echo "=== $backup_dir ==="
            echo "  Verzeichnis nicht gefunden: $dir_path"
            echo ""
        fi
    done
    
    if [[ $total_backups -gt 0 ]]; then
        local total_size_human
        total_size_human=$(numfmt --to=iec --suffix=B $total_size 2>/dev/null || echo "${total_size}B")
        log_info "Zusammenfassung: $total_backups Backups, $total_size_human"
        echo ""
        echo "Legende: 🔒 = GPG-verschlüsselt"
    else
        log_warning "Keine Backups gefunden"
    fi
}

cleanup_old_backups() {
    log_info "Bereinige alte Backups..."
    
    local cleaned_files=0
    local cleaned_size=0
    
    # Datenbank-Backups
    while IFS= read -r -d '' file; do
        local size
        size=$(stat -f "%z" "$file" 2>/dev/null || stat -c "%s" "$file" 2>/dev/null)
        rm "$file"
        ((cleaned_files++))
        cleaned_size=$((cleaned_size + size))
        log_info "Gelöscht: $(basename "$file")"
    done < <(find "$BACKUP_BASE_DIR/database" -name "*.sql.gz*" -type f -mtime +$DB_RETENTION_DAYS -print0 2>/dev/null)
    
    # Daten-Backups
    while IFS= read -r -d '' file; do
        local size
        size=$(stat -f "%z" "$file" 2>/dev/null || stat -c "%s" "$file" 2>/dev/null)
        rm "$file"
        ((cleaned_files++))
        cleaned_size=$((cleaned_size + size))
        log_info "Gelöscht: $(basename "$file")"
    done < <(find "$BACKUP_BASE_DIR/data" -name "*.tar.gz*" -type f -mtime +$DATA_RETENTION_DAYS -print0 2>/dev/null)
    
    # Konfiguration-Backups
    while IFS= read -r -d '' file; do
        local size
        size=$(stat -f "%z" "$file" 2>/dev/null || stat -c "%s" "$file" 2>/dev/null)
        rm "$file"
        ((cleaned_files++))
        cleaned_size=$((cleaned_size + size))
        log_info "Gelöscht: $(basename "$file")"
    done < <(find "$BACKUP_BASE_DIR/config" -name "*.tar.gz*" -type f -mtime +$CONFIG_RETENTION_DAYS -print0 2>/dev/null)
    
    # Volume-Backups
    while IFS= read -r -d '' file; do
        local size
        size=$(stat -f "%z" "$file" 2>/dev/null || stat -c "%s" "$file" 2>/dev/null)
        rm "$file"
        ((cleaned_files++))
        cleaned_size=$((cleaned_size + size))
        log_info "Gelöscht: $(basename "$file")"
    done < <(find "$BACKUP_BASE_DIR/volumes" -name "*.tar.gz*" -type f -mtime +$DATA_RETENTION_DAYS -print0 2>/dev/null)
    
    # Log-Backups
    while IFS= read -r -d '' file; do
        local size
        size=$(stat -f "%z" "$file" 2>/dev/null || stat -c "%s" "$file" 2>/dev/null)
        rm "$file"
        ((cleaned_files++))
        cleaned_size=$((cleaned_size + size))
        log_info "Gelöscht: $(basename "$file")"
    done < <(find "$BACKUP_BASE_DIR/logs" -name "*.tar.gz*" -type f -mtime +$CONFIG_RETENTION_DAYS -print0 2>/dev/null)
    
    if [[ $cleaned_files -gt 0 ]]; then
        local cleaned_size_human
        cleaned_size_human=$(numfmt --to=iec --suffix=B $cleaned_size 2>/dev/null || echo "${cleaned_size}B")
        log_success "$cleaned_files alte Backups bereinigt, $cleaned_size_human freigegeben"
    else
        log_info "Keine alten Backups zum Bereinigen gefunden"
    fi
}

show_backup_status() {
    log_info "Backup-System Status"
    echo ""
    
    # Konfiguration
    echo "=== KONFIGURATION ==="
    if [[ -f ".env" ]]; then
        source .env 2>/dev/null || true
        echo "GPG-Verschlüsselung: ${BACKUP_GPG_ENCRYPTION:-false}"
        if [[ "${BACKUP_GPG_ENCRYPTION:-false}" == "true" ]]; then
            echo "GPG-Empfänger: ${BACKUP_GPG_RECIPIENTS:-keine}"
            echo "Verschlüsselte Typen: ${BACKUP_GPG_ENCRYPT_TYPES:-all}"
        fi
        echo "Retention (Tage): DB=$DB_RETENTION_DAYS, Data=$DATA_RETENTION_DAYS, Config=$CONFIG_RETENTION_DAYS"
    else
        echo "Keine .env Konfiguration gefunden"
    fi
    echo ""
    
    # Backup-Verzeichnisse
    echo "=== BACKUP-VERZEICHNISSE ==="
    for backup_type in database data config volumes logs; do
        local dir_path="$BACKUP_BASE_DIR/$backup_type"
        if [[ -d "$dir_path" ]]; then
            local count
            count=$(find "$dir_path" -type f | wc -l)
            local size
            size=$(du -sh "$dir_path" 2>/dev/null | cut -f1 || echo "0B")
            echo "$backup_type: $count Dateien, $size"
        else
            echo "$backup_type: Verzeichnis nicht gefunden"
        fi
    done
    echo ""
    
    # Gesamtstatistik
    if [[ -d "$BACKUP_BASE_DIR" ]]; then
        echo "=== GESAMTSTATISTIK ==="
        echo "Backup-Verzeichnis: $BACKUP_BASE_DIR"
        echo "Gesamtgröße: $(du -sh "$BACKUP_BASE_DIR" 2>/dev/null | cut -f1 || echo "Unbekannt")"
        
        local total_files
        total_files=$(find "$BACKUP_BASE_DIR" -type f | wc -l)
        echo "Gesamtanzahl Dateien: $total_files"
    fi
}

# =============================================================================
# INTERAKTIVES MENÜ
# =============================================================================

interactive_menu() {
    while true; do
        show_banner
        echo "Nextcloud Backup Management"
        echo ""
        echo "1) Backup erstellen"
        echo "2) Backup entschlüsseln"
        echo "3) Backups auflisten"
        echo "4) Alte Backups bereinigen"
        echo "5) Backup-Status anzeigen"
        echo "6) Hilfe anzeigen"
        echo "0) Beenden"
        echo ""
        
        read -p "Auswahl (0-6): " choice
        
        case $choice in
            1)
                echo ""
                echo "Backup-Typ auswählen:"
                echo "1) Vollständiges Backup"
                echo "2) Nur Datenbank"
                echo "3) Nur Nextcloud-Dateien"
                echo "4) Nur Konfiguration"
                echo "5) Nur Docker Volumes"
                echo "6) Nur Container-Logs"
                echo ""
                read -p "Auswahl (1-6): " backup_choice
                
                case $backup_choice in
                    1) create_backup "full" ;;
                    2) create_backup "database" ;;
                    3) create_backup "data" ;;
                    4) create_backup "config" ;;
                    5) create_backup "volumes" ;;
                    6) create_backup "logs" ;;
                    *) log_error "Ungültige Auswahl" ;;
                esac
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            2)
                echo ""
                read -p "Pfad zur verschlüsselten Backup-Datei: " backup_file
                if [[ -n "$backup_file" ]]; then
                    decrypt_backup "$backup_file"
                fi
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            3)
                echo ""
                echo "Backup-Typ auswählen:"
                echo "1) Alle Backups"
                echo "2) Nur Datenbank"
                echo "3) Nur Nextcloud-Dateien"
                echo "4) Nur Konfiguration"
                echo "5) Nur Docker Volumes"
                echo "6) Nur Container-Logs"
                echo ""
                read -p "Auswahl (1-6): " list_choice
                
                case $list_choice in
                    1) list_backups "all" ;;
                    2) list_backups "database" ;;
                    3) list_backups "data" ;;
                    4) list_backups "config" ;;
                    5) list_backups "volumes" ;;
                    6) list_backups "logs" ;;
                    *) log_error "Ungültige Auswahl" ;;
                esac
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            4)
                echo ""
                log_warning "Alte Backups werden basierend auf Retention-Einstellungen gelöscht"
                read -p "Fortfahren? (y/N): " -r
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    cleanup_old_backups
                fi
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            5)
                show_backup_status
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            6)
                show_usage
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            0)
                log_info "Auf Wiedersehen!"
                exit 0
                ;;
            *)
                log_error "Ungültige Auswahl: $choice"
                sleep 2
                ;;
        esac
        
        clear
    done
}

# =============================================================================
# HAUPTFUNKTION
# =============================================================================

main() {
    local action="${1:-interactive}"
    
    case "$action" in
        create)
            show_banner
            # Überprüfungen
            check_prerequisites
            check_gpg_availability
            create_backup_dirs
            
            # Lade Konfiguration
            source .env 2>/dev/null || {
                log_error "Konnte .env Datei nicht laden"
                exit 1
            }
            
            create_backup "${2:-full}"
            ;;
        decrypt)
            show_banner
            if [[ $# -lt 2 ]]; then
                log_error "Backup-Datei ist erforderlich"
                show_usage
                exit 1
            fi
            decrypt_backup "$2" "$3"
            ;;
        list)
            show_banner
            list_backups "${2:-all}"
            ;;
        cleanup)
            show_banner
            # Lade Konfiguration für Retention-Einstellungen
            source .env 2>/dev/null || {
                log_warning "Konnte .env nicht laden, verwende Standard-Retention"
            }
            cleanup_old_backups
            ;;
        status)
            show_banner
            show_backup_status
            ;;
        interactive|"")
            # Überprüfungen für interaktives Menü
            check_prerequisites
            check_gpg_availability
            create_backup_dirs
            
            # Lade Konfiguration
            source .env 2>/dev/null || {
                log_warning "Konnte .env Datei nicht laden"
            }
            
            interactive_menu
            ;;
        --help|-h|help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unbekannte Aktion: $action"
            show_usage
            exit 1
            ;;
    esac
}

# Script ausführen
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
