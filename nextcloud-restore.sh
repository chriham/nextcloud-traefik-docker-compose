#!/bin/bash

# Nextcloud Comprehensive Restore Script
# Stellt Nextcloud-Backups vollständig wieder her

set -euo pipefail

# Konfiguration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-${SCRIPT_DIR}/backups}"
COMPOSE_FILE="${SCRIPT_DIR}/nextcloud-caddy-docker compose.yml"
COMPOSE_PROJECT="nextcloud-caddy"

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

show_usage() {
    echo "Nextcloud Restore Script"
    echo ""
    echo "Usage: $0 [restore_type] [backup_timestamp]"
    echo ""
    echo "Restore-Typen:"
    echo "  full        - Vollständige Wiederherstellung (interaktiv)"
    echo "  database    - Nur Datenbank wiederherstellen"
    echo "  data        - Nur Nextcloud-Dateien wiederherstellen"  
    echo "  config      - Nur Konfiguration wiederherstellen"
    echo "  secrets     - Nur Secrets wiederherstellen"
    echo "  volumes     - Nur Docker Volumes wiederherstellen"
    echo "  interactive - Interaktive Auswahl (Standard)"
    echo ""
    echo "Beispiele:"
    echo "  $0                           # Interaktive Wiederherstellung"
    echo "  $0 full                      # Vollständige interaktive Wiederherstellung"
    echo "  $0 database 20241217_143022  # Datenbank-Backup vom 17.12.2024 14:30"
    echo "  $0 config                    # Konfiguration interaktiv auswählen"
}

# Hilfsfunktionen
check_prerequisites() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker ist nicht installiert"
        exit 1
    fi
    
    if ! command -v docker compose &> /dev/null; then
        log_error "Docker Compose ist nicht installiert"
        exit 1
    fi
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "Docker Compose Datei nicht gefunden: $COMPOSE_FILE"
        exit 1
    fi
    
    if [[ ! -d "$BACKUP_BASE_DIR" ]]; then
        log_error "Backup-Verzeichnis nicht gefunden: $BACKUP_BASE_DIR"
        exit 1
    fi
}

check_gpg_for_encrypted_backups() {
    # Prüfe ob GPG für verschlüsselte Backups verfügbar ist
    if find "$BACKUP_BASE_DIR" -name "*.gpg" -type f | head -1 | grep -q .; then
        if ! command -v gpg &> /dev/null; then
            log_error "Verschlüsselte Backups gefunden, aber GPG ist nicht installiert"
            log_info "Installation: sudo apt install gnupg (Ubuntu/Debian) oder brew install gnupg (macOS)"
            exit 1
        fi
        log_info "GPG verfügbar für verschlüsselte Backup-Wiederherstellung"
    fi
}

is_encrypted_backup() {
    local file="$1"
    [[ "$file" == *.gpg ]] || file "$file" 2>/dev/null | grep -q "GPG\|PGP"
}

decrypt_backup_if_needed() {
    local backup_file="$1"
    local output_file="$2"
    
    if is_encrypted_backup "$backup_file"; then
        log_info "Entschlüssele GPG-Backup: $(basename "$backup_file")"
        if gpg --quiet --decrypt --output "$output_file" "$backup_file" 2>/dev/null; then
            log_success "Backup entschlüsselt"
            return 0
        else
            log_error "GPG-Entschlüsselung fehlgeschlagen"
            log_info "Stellen Sie sicher, dass Sie den passenden privaten Schlüssel haben"
            return 1
        fi
    else
        # Nicht verschlüsselt - einfach kopieren
        cp "$backup_file" "$output_file"
        return 0
    fi
}

enable_maintenance_mode() {
    log_info "Aktiviere Wartungsmodus..."
    if docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app \
        php occ maintenance:mode --on 2>/dev/null; then
        log_success "Wartungsmodus aktiviert"
        return 0
    else
        log_warning "Konnte Wartungsmodus nicht aktivieren (Container läuft möglicherweise nicht)"
        return 1
    fi
}

disable_maintenance_mode() {
    log_info "Deaktiviere Wartungsmodus..."
    if docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app \
        php occ maintenance:mode --off 2>/dev/null; then
        log_success "Wartungsmodus deaktiviert"
        return 0
    else
        log_warning "Konnte Wartungsmodus nicht deaktivieren"
        return 1
    fi
}

stop_services() {
    local services=("$@")
    log_info "Stoppe Services: ${services[*]}"
    
    for service in "${services[@]}"; do
        if docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" stop "$service" 2>/dev/null; then
            log_info "Service gestoppt: $service"
        else
            log_warning "Konnte Service nicht stoppen: $service"
        fi
    done
}

start_services() {
    local services=("$@")
    log_info "Starte Services: ${services[*]}"
    
    for service in "${services[@]}"; do
        if docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" start "$service" 2>/dev/null; then
            log_info "Service gestartet: $service"
        else
            log_warning "Konnte Service nicht starten: $service"
        fi
    done
}

list_available_backups() {
    local backup_type="$1"
    local backup_dir="$BACKUP_BASE_DIR/$backup_type"
    
    if [[ ! -d "$backup_dir" ]]; then
        log_warning "Kein $backup_type Backup-Verzeichnis gefunden: $backup_dir"
        return 1
    fi
    
    log_info "Verfügbare $backup_type Backups:"
    local backups=()
    
    while IFS= read -r -d '' file; do
        local basename_file
        basename_file=$(basename "$file")
        local filesize
        filesize=$(du -h "$file" | cut -f1)
        local timestamp
        timestamp=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null || stat -c "%y" "$file" 2>/dev/null | cut -d. -f1)
        
        backups+=("$file")
        printf "%3d) %s (%s, %s)\n" "${#backups[@]}" "$basename_file" "$filesize" "$timestamp"
    done < <(find "$backup_dir" -maxdepth 1 -type f \( -name "*.gz" -o -name "*.gpg" \) -print0 | sort -z)
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        log_warning "Keine $backup_type Backups gefunden"
        return 1
    fi
    
    echo ""
    read -p "Backup auswählen (Nummer eingeben, 0 für Abbruch): " -r selection
    
    if [[ "$selection" == "0" ]] || [[ -z "$selection" ]]; then
        log_info "Wiederherstellung abgebrochen"
        return 1
    fi
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#backups[@]} ]]; then
        selected_backup="${backups[$((selection-1))]}"
        log_info "Ausgewähltes Backup: $(basename "$selected_backup")"
        return 0
    else
        log_error "Ungültige Auswahl: $selection"
        return 1
    fi
}

restore_database() {
    local backup_file="$1"
    
    log_info "Starte Datenbank-Wiederherstellung..."
    
    # Lade Umgebungsvariablen
    source .env 2>/dev/null || {
        log_error "Konnte .env Datei nicht laden"
        return 1
    }
    
    # Entschlüssele Backup falls nötig
    local temp_backup
    temp_backup=$(mktemp --suffix=.sql.gz)
    
    if ! decrypt_backup_if_needed "$backup_file" "$temp_backup"; then
        rm -f "$temp_backup"
        return 1
    fi
    
    # Wartungsmodus aktivieren
    enable_maintenance_mode
    
    # Services stoppen
    stop_services app web cron notify_push
    
    log_warning "ACHTUNG: Die aktuelle Datenbank wird überschrieben!"
    read -p "Fortfahren? (y/N): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Datenbank-Wiederherstellung abgebrochen"
        rm -f "$temp_backup"
        start_services app web cron notify_push
        disable_maintenance_mode
        return 1
    fi
    
    if [[ "${DATABASE_TYPE:-docker}" == "docker" ]]; then
        # Docker PostgreSQL
        log_info "Stelle Datenbank in Docker-Container wieder her..."
        
        # Lösche aktuelle Datenbank und erstelle neue
        if docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T postgres \
            psql -U "$NEXTCLOUD_DB_USER" -c "DROP DATABASE IF EXISTS ${NEXTCLOUD_DB_NAME};" && \
           docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T postgres \
            psql -U "$NEXTCLOUD_DB_USER" -c "CREATE DATABASE ${NEXTCLOUD_DB_NAME};" && \
           gunzip -c "$temp_backup" | docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T postgres \
            psql -U "$NEXTCLOUD_DB_USER" -d "$NEXTCLOUD_DB_NAME"; then
            
            log_success "Datenbank erfolgreich wiederhergestellt"
        else
            log_error "Datenbank-Wiederherstellung fehlgeschlagen"
            rm -f "$temp_backup"
            start_services app web cron notify_push
            disable_maintenance_mode
            return 1
        fi
    else
        # Externe Datenbank
        log_info "Stelle externe Datenbank wieder her..."
        
        if command -v psql &> /dev/null; then
            local db_password
            db_password=$(cat secrets/postgres_password.txt 2>/dev/null || echo "")
            
            if [[ -n "$db_password" ]]; then
                if PGPASSWORD="$db_password" psql -h "$DB_HOST" -U "$NEXTCLOUD_DB_USER" \
                    -c "DROP DATABASE IF EXISTS ${NEXTCLOUD_DB_NAME};" && \
                   PGPASSWORD="$db_password" psql -h "$DB_HOST" -U "$NEXTCLOUD_DB_USER" \
                    -c "CREATE DATABASE ${NEXTCLOUD_DB_NAME};" && \
                   gunzip -c "$temp_backup" | PGPASSWORD="$db_password" psql -h "$DB_HOST" \
                    -U "$NEXTCLOUD_DB_USER" -d "$NEXTCLOUD_DB_NAME"; then
                    
                    log_success "Externe Datenbank erfolgreich wiederhergestellt"
                else
                    log_error "Externe Datenbank-Wiederherstellung fehlgeschlagen"
                    rm -f "$temp_backup"
                    start_services app web cron notify_push
                    disable_maintenance_mode
                    return 1
                fi
            else
                log_error "Konnte Datenbank-Passwort nicht lesen"
                rm -f "$temp_backup"
                start_services app web cron notify_push
                disable_maintenance_mode
                return 1
            fi
        else
            log_error "psql ist nicht verfügbar für externe Datenbank"
            rm -f "$temp_backup"
            start_services app web cron notify_push
            disable_maintenance_mode
            return 1
        fi
    fi
    
    # Cleanup
    rm -f "$temp_backup"
    
    # Services starten
    start_services postgres app web cron notify_push
    
    # Warte bis Services bereit sind
    log_info "Warte bis Services bereit sind..."
    sleep 10
    
    # Nextcloud-Wartung durchführen
    log_info "Führe Nextcloud-Wartung durch..."
    docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app php occ maintenance:repair || true
    docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app php occ db:add-missing-indices || true
    
    # Wartungsmodus deaktivieren
    disable_maintenance_mode
    
    log_success "Datenbank-Wiederherstellung abgeschlossen"
    return 0
}

restore_data() {
    local backup_file="$1"
    
    log_info "Starte Daten-Wiederherstellung..."
    
    # Lade Umgebungsvariablen
    source .env 2>/dev/null || {
        log_error "Konnte .env Datei nicht laden"
        return 1
    }
    
    local data_dir="${NEXTCLOUD_DATA_DIR:-./nextcloud-data}"
    
    if [[ ! -d "$data_dir" ]]; then
        log_error "Nextcloud-Daten-Verzeichnis nicht gefunden: $data_dir"
        return 1
    fi
    
    # Entschlüssele Backup falls nötig
    local temp_backup
    temp_backup=$(mktemp --suffix=.tar.gz)
    
    if ! decrypt_backup_if_needed "$backup_file" "$temp_backup"; then
        rm -f "$temp_backup"
        return 1
    fi
    
    # Wartungsmodus aktivieren
    enable_maintenance_mode
    
    # Services stoppen
    stop_services app web cron notify_push
    
    log_warning "ACHTUNG: Die aktuellen Nextcloud-Dateien werden überschrieben!"
    log_info "Aktuelles Daten-Verzeichnis: $data_dir"
    read -p "Fortfahren? (y/N): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Daten-Wiederherstellung abgebrochen"
        rm -f "$temp_backup"
        start_services app web cron notify_push
        disable_maintenance_mode
        return 1
    fi
    
    # Erstelle Backup der aktuellen Daten
    local current_backup
    current_backup="$data_dir.backup.$(date +%Y%m%d_%H%M%S)"
    log_info "Erstelle Backup der aktuellen Daten: $current_backup"
    if ! mv "$data_dir" "$current_backup"; then
        log_error "Konnte aktuelles Daten-Backup nicht erstellen"
        rm -f "$temp_backup"
        start_services app web cron notify_push
        disable_maintenance_mode
        return 1
    fi
    
    # Stelle Daten wieder her
    log_info "Extrahiere Backup..."
    mkdir -p "$(dirname "$data_dir")"
    
    if tar -xzf "$temp_backup" -C "$(dirname "$data_dir")"; then
        log_success "Daten erfolgreich wiederhergestellt"
        
        # Setze korrekte Berechtigungen
        local nc_uid="${NEXTCLOUD_USER_ID:-1000}"
        local nc_gid="${NEXTCLOUD_GROUP_ID:-1000}"
        log_info "Setze Dateiberechtigungen (UID:$nc_uid, GID:$nc_gid)..."
        sudo chown -R "$nc_uid:$nc_gid" "$data_dir" 2>/dev/null || \
            log_warning "Konnte Berechtigungen nicht setzen (sudo erforderlich)"
        
        # Entferne aktuelles Backup falls erfolgreich
        read -p "Aktuelles Daten-Backup löschen? ($current_backup) (y/N): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$current_backup"
            log_info "Aktuelles Daten-Backup gelöscht"
        fi
    else
        log_error "Daten-Wiederherstellung fehlgeschlagen"
        
        # Stelle ursprüngliche Daten wieder her
        log_info "Stelle ursprüngliche Daten wieder her..."
        mv "$current_backup" "$data_dir"
        
        rm -f "$temp_backup"
        start_services app web cron notify_push
        disable_maintenance_mode
        return 1
    fi
    
    # Cleanup
    rm -f "$temp_backup"
    
    # Services starten
    start_services app web cron notify_push
    
    # Warte bis Services bereit sind
    log_info "Warte bis Services bereit sind..."
    sleep 10
    
    # Nextcloud-Wartung durchführen
    log_info "Führe Nextcloud-Wartung durch..."
    docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app php occ files:scan --all || true
    docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" exec -T app php occ maintenance:repair || true
    
    # Wartungsmodus deaktivieren
    disable_maintenance_mode
    
    log_success "Daten-Wiederherstellung abgeschlossen"
    return 0
}

restore_config() {
    local backup_file="$1"
    
    log_info "Starte Konfigurations-Wiederherstellung..."
    
    # Entschlüssele Backup falls nötig
    local temp_backup
    temp_backup=$(mktemp --suffix=.tar.gz)
    
    if ! decrypt_backup_if_needed "$backup_file" "$temp_backup"; then
        rm -f "$temp_backup"
        return 1
    fi
    
    # Erstelle temporäres Verzeichnis
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Extrahiere Backup
    if ! tar -xzf "$temp_backup" -C "$temp_dir"; then
        log_error "Konnte Konfigurations-Backup nicht extrahieren"
        rm -rf "$temp_dir" "$temp_backup"
        return 1
    fi
    
    log_info "Konfigurations-Backup extrahiert"
    
    # Zeige verfügbare Konfigurationsdateien
    echo ""
    log_info "Verfügbare Konfigurationsdateien:"
    local config_files=()
    local i=1
    
    for file in "$temp_dir"/*; do
        if [[ -f "$file" ]] && [[ "$(basename "$file")" != "README.txt" ]]; then
            config_files+=("$file")
            echo "$i) $(basename "$file")"
            ((i++))
        fi
    done
    
    # Spezielle Behandlung für secrets
    if [[ -d "$temp_dir/secrets" ]]; then
        config_files+=("$temp_dir/secrets")
        echo "$i) secrets/ (Verzeichnis)"
        ((i++))
    fi
    
    if [[ ${#config_files[@]} -eq 0 ]]; then
        log_warning "Keine Konfigurationsdateien im Backup gefunden"
        rm -rf "$temp_dir" "$temp_backup"
        return 1
    fi
    
    echo ""
    echo "a) Alle Dateien wiederherstellen"
    echo "0) Abbruch"
    echo ""
    read -p "Auswahl (Nummer, a für alle, 0 für Abbruch): " -r selection
    
    if [[ "$selection" == "0" ]]; then
        log_info "Konfigurations-Wiederherstellung abgebrochen"
        rm -rf "$temp_dir" "$temp_backup"
        return 0
    fi
    
    local files_to_restore=()
    
    if [[ "$selection" == "a" ]]; then
        files_to_restore=("${config_files[@]}")
    elif [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#config_files[@]} ]]; then
        files_to_restore=("${config_files[$((selection-1))]}")
    else
        log_error "Ungültige Auswahl: $selection"
        rm -rf "$temp_dir" "$temp_backup"
        return 1
    fi
    
    # Wartungsmodus aktivieren
    enable_maintenance_mode
    
    # Stelle ausgewählte Dateien wieder her
    for file in "${files_to_restore[@]}"; do
        local basename_file
        basename_file=$(basename "$file")
        
        if [[ "$basename_file" == "secrets" ]]; then
            # Spezielle Behandlung für secrets
            log_info "Stelle secrets wieder her..."
            
            if [[ -d "secrets" ]]; then
                log_warning "Vorhandene secrets gefunden"
                read -p "Secrets überschreiben? (y/N): " -r
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log_info "Secrets übersprungen"
                    continue
                fi
            fi
            
            # Erstelle secrets Verzeichnis
            mkdir -p secrets
            
            # Kopiere secrets (GPG-verschlüsselt oder unverschlüsselt)
            if ls "$file"/*.gpg &>/dev/null; then
                log_info "GPG-verschlüsselte secrets gefunden"
                for gpg_file in "$file"/*.gpg; do
                    local secret_name
                    secret_name=$(basename "$gpg_file" .gpg)
                    local output_file="secrets/${secret_name}.txt"
                    
                    if gpg --quiet --decrypt --output "$output_file" "$gpg_file" 2>/dev/null; then
                        chmod 600 "$output_file"
                        log_success "Secret wiederhergestellt: $secret_name"
                    else
                        log_error "Konnte Secret nicht entschlüsseln: $secret_name"
                    fi
                done
            else
                # Unverschlüsselte secrets
                cp "$file"/*.txt secrets/ 2>/dev/null || true
                chmod 600 secrets/*.txt 2>/dev/null || true
                log_success "Secrets wiederhergestellt"
            fi
        else
            # Normale Konfigurationsdateien
            if [[ -f "$basename_file" ]]; then
                log_warning "Datei existiert bereits: $basename_file"
                read -p "Überschreiben? (y/N): " -r
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log_info "Datei übersprungen: $basename_file"
                    continue
                fi
            fi
            
            cp "$file" "./$basename_file"
            log_success "Konfigurationsdatei wiederhergestellt: $basename_file"
        fi
    done
    
    # Cleanup
    rm -rf "$temp_dir" "$temp_backup"
    
    # Wartungsmodus deaktivieren
    disable_maintenance_mode
    
    log_success "Konfigurations-Wiederherstellung abgeschlossen"
    log_info "Starten Sie die Container neu um Änderungen zu übernehmen"
    
    return 0
}

restore_volumes() {
    local backup_file="$1"
    
    log_info "Starte Volume-Wiederherstellung..."
    
    # Entschlüssele Backup falls nötig
    local temp_backup
    temp_backup=$(mktemp --suffix=.tar.gz)
    
    if ! decrypt_backup_if_needed "$backup_file" "$temp_backup"; then
        rm -f "$temp_backup"
        return 1
    fi
    
    # Bestimme Volume-Namen aus Dateiname
    local backup_basename
    backup_basename=$(basename "$backup_file")
    local volume_name
    volume_name=$(echo "$backup_basename" | sed -E 's/^([^-]+)-[0-9]{8}_[0-9]{6}\.tar\.gz(\.gpg)?$/\1/')
    
    if [[ -z "$volume_name" ]]; then
        log_error "Konnte Volume-Namen nicht aus Dateiname bestimmen: $backup_basename"
        rm -f "$temp_backup"
        return 1
    fi
    
    local full_volume_name="${COMPOSE_PROJECT}_${volume_name}"
    
    log_info "Volume-Wiederherstellung für: $full_volume_name"
    
    # Überprüfe ob Volume existiert
    if ! docker volume inspect "$full_volume_name" &>/dev/null; then
        log_warning "Volume existiert nicht: $full_volume_name"
        read -p "Volume erstellen? (y/N): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker volume create "$full_volume_name"
            log_info "Volume erstellt: $full_volume_name"
        else
            log_info "Volume-Wiederherstellung abgebrochen"
            rm -f "$temp_backup"
            return 1
        fi
    fi
    
    log_warning "ACHTUNG: Der Inhalt des Volumes wird überschrieben!"
    read -p "Fortfahren? (y/N): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Volume-Wiederherstellung abgebrochen"
        rm -f "$temp_backup"
        return 1
    fi
    
    # Stoppe Services die das Volume verwenden könnten
    case "$volume_name" in
        "nextcloud-data")
            stop_services app web cron
            ;;
        "redis-data")
            stop_services redis
            ;;
        "caddy-data"|"caddy-config")
            stop_services web proxy
            ;;
    esac
    
    # Stelle Volume wieder her
    log_info "Stelle Volume wieder her..."
    if docker run --rm -v "$full_volume_name:/data" -v "$(dirname "$temp_backup"):/backup" \
        alpine:latest sh -c "cd /data && rm -rf * && tar -xzf /backup/$(basename "$temp_backup")"; then
        
        log_success "Volume erfolgreich wiederhergestellt: $volume_name"
    else
        log_error "Volume-Wiederherstellung fehlgeschlagen"
        rm -f "$temp_backup"
        return 1
    fi
    
    # Services wieder starten
    case "$volume_name" in
        "nextcloud-data")
            start_services app web cron
            ;;
        "redis-data")
            start_services redis
            ;;
        "caddy-data"|"caddy-config")
            start_services web proxy
            ;;
    esac
    
    # Cleanup
    rm -f "$temp_backup"
    
    log_success "Volume-Wiederherstellung abgeschlossen"
    return 0
}

interactive_restore() {
    local restore_type="${1:-interactive}"
    
    echo ""
    log_info "Interaktive Nextcloud-Wiederherstellung"
    echo ""
    echo "Verfügbare Wiederherstellungsoptionen:"
    echo "1) Datenbank wiederherstellen"
    echo "2) Nextcloud-Dateien wiederherstellen"
    echo "3) Konfiguration wiederherstellen"
    echo "4) Docker Volumes wiederherstellen"
    echo "5) Vollständige Wiederherstellung (Datenbank + Dateien + Konfiguration)"
    echo "0) Abbruch"
    echo ""
    
    read -p "Auswahl (1-5, 0 für Abbruch): " -r selection
    
    case "$selection" in
        1)
            if list_available_backups "database"; then
                restore_database "$selected_backup"
            fi
            ;;
        2)
            if list_available_backups "data"; then
                restore_data "$selected_backup"
            fi
            ;;
        3)
            if list_available_backups "config"; then
                restore_config "$selected_backup"
            fi
            ;;
        4)
            if list_available_backups "volumes"; then
                restore_volumes "$selected_backup"
            fi
            ;;
        5)
            log_info "Vollständige Wiederherstellung gestartet..."
            
            # Datenbank
            echo ""
            log_info "1/3: Datenbank wiederherstellen"
            if list_available_backups "database"; then
                if ! restore_database "$selected_backup"; then
                    log_error "Datenbank-Wiederherstellung fehlgeschlagen"
                    return 1
                fi
            else
                log_warning "Keine Datenbank-Backups gefunden"
            fi
            
            # Dateien
            echo ""
            log_info "2/3: Nextcloud-Dateien wiederherstellen"
            if list_available_backups "data"; then
                if ! restore_data "$selected_backup"; then
                    log_error "Daten-Wiederherstellung fehlgeschlagen"
                    return 1
                fi
            else
                log_warning "Keine Daten-Backups gefunden"
            fi
            
            # Konfiguration
            echo ""
            log_info "3/3: Konfiguration wiederherstellen"
            if list_available_backups "config"; then
                if ! restore_config "$selected_backup"; then
                    log_error "Konfigurations-Wiederherstellung fehlgeschlagen"
                    return 1
                fi
            else
                log_warning "Keine Konfigurations-Backups gefunden"
            fi
            
            log_success "Vollständige Wiederherstellung abgeschlossen!"
            ;;
        0)
            log_info "Wiederherstellung abgebrochen"
            return 0
            ;;
        *)
            log_error "Ungültige Auswahl: $selection"
            return 1
            ;;
    esac
}

# Hauptfunktion
main() {
    local restore_type="${1:-interactive}"
    local backup_timestamp="${2:-}"
    
    echo -e "${BLUE}"
    cat << "EOF"
  _   _           _       _                 _   ____            _                
 | \ | |         | |     | |               | | |  _ \ ___  ___| |_ ___  _ __ ___ 
 |  \| | _____  _| |_ ___| | ___  _   _  __| | | |_) / _ \/ __| __/ _ \| '__/ _ \
 | |\  |  __/>  <| || (__| | (_) | |_| | (_| | |  _ <  __/\__ \ || (_) | | |  __/
 \_| \_/\___/_/\_\\__\___|_|\___/ \__,_|\__,_| |_| \_\___||___/\__\___/|_|  \___|
                                                                                 
EOF
    echo -e "${NC}"
    
    log_info "Nextcloud Restore gestartet (Typ: $restore_type)"
    
    # Überprüfungen
    check_prerequisites
    check_gpg_for_encrypted_backups
    
    case "$restore_type" in
        "interactive"|"")
            interactive_restore
            ;;
        "full")
            interactive_restore "full"
            ;;
        "database")
            if [[ -n "$backup_timestamp" ]]; then
                # Suche nach spezifischem Backup
                local backup_file
                backup_file=$(find "$BACKUP_BASE_DIR/database" -name "*${backup_timestamp}*" -type f | head -1)
                if [[ -n "$backup_file" ]]; then
                    restore_database "$backup_file"
                else
                    log_error "Datenbank-Backup mit Timestamp '$backup_timestamp' nicht gefunden"
                    exit 1
                fi
            else
                if list_available_backups "database"; then
                    restore_database "$selected_backup"
                fi
            fi
            ;;
        "data")
            if [[ -n "$backup_timestamp" ]]; then
                local backup_file
                backup_file=$(find "$BACKUP_BASE_DIR/data" -name "*${backup_timestamp}*" -type f | head -1)
                if [[ -n "$backup_file" ]]; then
                    restore_data "$backup_file"
                else
                    log_error "Daten-Backup mit Timestamp '$backup_timestamp' nicht gefunden"
                    exit 1
                fi
            else
                if list_available_backups "data"; then
                    restore_data "$selected_backup"
                fi
            fi
            ;;
        "config")
            if [[ -n "$backup_timestamp" ]]; then
                local backup_file
                backup_file=$(find "$BACKUP_BASE_DIR/config" -name "*${backup_timestamp}*" -type f | head -1)
                if [[ -n "$backup_file" ]]; then
                    restore_config "$backup_file"
                else
                    log_error "Konfigurations-Backup mit Timestamp '$backup_timestamp' nicht gefunden"
                    exit 1
                fi
            else
                if list_available_backups "config"; then
                    restore_config "$selected_backup"
                fi
            fi
            ;;
        "volumes")
            if list_available_backups "volumes"; then
                restore_volumes "$selected_backup"
            fi
            ;;
        "secrets")
            # Verwende das bestehende restore-secrets.sh falls verfügbar
            if [[ -x "./restore-secrets.sh" ]]; then
                log_info "Verwende spezielles Secrets-Restore-Script..."
                if list_available_backups "config"; then
                    ./restore-secrets.sh "$selected_backup"
                fi
            else
                log_error "Secrets-Restore nicht verfügbar"
                exit 1
            fi
            ;;
        *)
            log_error "Unbekannter Restore-Typ: $restore_type"
            show_usage
            exit 1
            ;;
    esac
    
    echo ""
    log_success "Nextcloud Restore abgeschlossen!"
    log_info "Überprüfen Sie die Anwendung unter: https://$(grep NEXTCLOUD_HOSTNAME .env 2>/dev/null | cut -d= -f2 || echo 'ihre-domain.com')"
}

# Script ausführen
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
