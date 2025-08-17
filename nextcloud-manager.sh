#!/bin/bash

# Nextcloud Caddy Management Script
# Konsolidiertes Management für Setup, GPG und Secrets

set -euo pipefail

# Konfiguration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_banner() {
    echo -e "${BLUE}"
    cat << "EOF"
  _   _           _       _                 _   __  __                                   
 | \ | |         | |     | |               | | |  \/  |                                  
 |  \| | _____  _| |_ ___| | ___  _   _  __| | | .  . | __ _ _ __   __ _  __ _  ___ _ __ 
 | . ` |/ _ \ \/ / __/ __| |/ _ \| | | |/ _` | | |\/| |/ _` | '_ \ / _` |/ _` |/ _ \ '__|
 | |\  |  __/>  <| || (__| | (_) | |_| | (_| | | |  | | (_| | | | | (_| | (_| |  __/ |   
 \_| \_/\___/_/\_\\__\___|_|\___/ \__,_|\__,_| \_|  |_/\__,_|_| |_|\__,_|\__, |\___|_|   
                                                                          __/ |         
                                                                         |___/          
EOF
    echo -e "${NC}"
}

show_usage() {
    echo "Nextcloud Caddy Management Script"
    echo ""
    echo "Usage: $0 [action]"
    echo ""
    echo "=== SETUP & KONFIGURATION ==="
    echo "  setup           Vollständiges Nextcloud-Setup"
    echo "  setup-gpg       GPG-Verschlüsselung für Backups einrichten"
    echo "  import-keys     GPG-Schlüssel importieren"
    echo "  secure-secrets  Secrets-Management"
    echo "  setup-cron      Host-System Cron einrichten"
    echo ""
    echo "=== CONTAINER MANAGEMENT ==="
    echo "  start           Nextcloud Container starten"
    echo "  stop            Nextcloud Container stoppen"
    echo "  restart         Nextcloud Container neustarten"
    echo "  ps              Container Status anzeigen"
    echo "  logs            Container Logs anzeigen (live)"
    echo ""
    echo "=== SYSTEM & HILFE ==="
    echo "  status          System-Status anzeigen"
    echo "  test-config     Konfiguration testen"
    echo "  interactive     Interaktives Menü (Standard)"
    echo ""
    echo "Beispiele:"
    echo "  $0                    # Interaktives Menü"
    echo "  $0 setup              # Vollständiges Setup"
    echo "  $0 start              # Container starten"
    echo "  $0 stop               # Container stoppen"
    echo "  $0 logs               # Live-Logs anzeigen"
    echo "  $0 ps                 # Container Status"
    echo "  $0 status             # System-Status"
}

# =============================================================================
# HILFSFUNKTIONEN
# =============================================================================

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 ist nicht installiert. Bitte installieren Sie es zuerst."
        exit 1
    fi
}

generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# =============================================================================
# SECRETS MANAGEMENT
# =============================================================================

secure_secrets() {
    log_info "Secrets-Management wird gestartet..."

    # Überprüfe ob secrets Verzeichnis existiert
    SECRETS_DIR=${SECRETS_DIR:-./secrets}
    if [[ ! -d "$SECRETS_DIR" ]]; then
        mkdir -p "$SECRETS_DIR"
        log_info "Secrets-Verzeichnis erstellt: $SECRETS_DIR"
    fi

    # Generiere oder aktualisiere Passwörter
    declare -A passwords=(
        ["postgres_password"]="PostgreSQL Datenbank"
        ["redis_password"]="Redis Cache"
        ["nextcloud_admin_password"]="Nextcloud Admin"
    )

    for secret_name in "${!passwords[@]}"; do
        secret_file="${SECRETS_DIR:-./secrets}/${secret_name}.txt"
        
        if [[ -f "$secret_file" ]]; then
            log_warning "Secret ${secret_name} existiert bereits"
            read -p "Neues Passwort generieren? (y/N): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                continue
            fi
        fi

        # Generiere sicheres Passwort
        password=$(generate_password)
        echo "$password" > "$secret_file"
        
        log_success "Secret ${secret_name} erstellt (${passwords[$secret_name]})"
    done

    # Setze restriktive Berechtigungen
    log_info "Setze sichere Dateiberechtigungen..."
    
    # Secrets-Verzeichnis: nur Owner kann lesen/schreiben/ausführen
    SECRETS_DIR=${SECRETS_DIR:-./secrets}
    chmod 700 "$SECRETS_DIR/"
    
    # Secret-Dateien: nur Owner kann lesen/schreiben
    chmod 600 "$SECRETS_DIR"/*.txt
    
    # Überprüfe Berechtigungen
    log_info "Aktuelle Berechtigungen:"
    ls -la "$SECRETS_DIR/"
    
    # Zusätzliche Sicherheitsmaßnahmen
    log_info "Zusätzliche Sicherheitsmaßnahmen..."
    
    # Setze immutable bit (falls unterstützt)
    if command -v chattr &> /dev/null; then
        for file in "$SECRETS_DIR"/*.txt; do
            if chattr +i "$file" 2>/dev/null; then
                log_success "Immutable bit gesetzt für $(basename "$file")"
            else
                log_warning "Konnte immutable bit nicht setzen für $(basename "$file")"
            fi
        done
    fi
    
    # Erstelle .gitignore für secrets (falls nicht vorhanden)
    if [[ ! -f "$SECRETS_DIR/.gitignore" ]]; then
        echo "*" > "$SECRETS_DIR/.gitignore"
        echo "!.gitignore" >> "$SECRETS_DIR/.gitignore"
        log_success "Git-Ignore für Secrets erstellt"
    fi
    
    log_success "Secrets-Management abgeschlossen!"
}

# =============================================================================
# GPG FUNKTIONEN
# =============================================================================

check_gpg_installation() {
    if ! command -v gpg &> /dev/null; then
        log_error "GPG ist nicht installiert!"
        echo ""
        echo "Installation:"
        echo "  Ubuntu/Debian: sudo apt install gnupg"
        echo "  CentOS/RHEL:   sudo yum install gnupg2"
        echo "  macOS:         brew install gnupg"
        echo "  Arch:          sudo pacman -S gnupg"
        exit 1
    fi
    
    local gpg_version
    gpg_version=$(gpg --version | head -1 | awk '{print $3}')
    log_success "GPG gefunden: Version $gpg_version"
}

show_existing_keys() {
    log_info "Vorhandene GPG-Schlüssel:"
    echo ""
    
    if gpg --list-keys --keyid-format LONG 2>/dev/null | grep -q "pub"; then
        gpg --list-keys --keyid-format LONG --with-fingerprint
    else
        log_warning "Keine GPG-Schlüssel gefunden"
    fi
    echo ""
}

import_gpg_keys() {
    log_info "GPG-Schlüssel Import"
    
    local imported_keys=()
    
    while true; do
        echo ""
        echo "Schlüssel-Import Optionen:"
        echo "1) Schlüssel aus Datei importieren"
        echo "2) Schlüssel von Keyserver laden"
        echo "3) Schlüssel aus Zwischenablage einfügen (Copy & Paste)"
        echo "4) Mehrere Schlüssel aus Zwischenablage (einer nach dem anderen)"
        echo "5) Aktuell importierte Schlüssel anzeigen"
        echo "6) Import beenden"
        
        read -p "Auswahl (1-6): " import_choice
        
        case $import_choice in
            1)
                read -p "Pfad zur Schlüssel-Datei: " key_file
                if [[ -f "$key_file" ]]; then
                    if gpg --import "$key_file" 2>/dev/null; then
                        local new_keys
                        new_keys=$(gpg --import --import-options show-only "$key_file" 2>/dev/null | grep -E "^pub" | awk '{print $2}' | cut -d'/' -f2)
                        imported_keys+=($new_keys)
                        log_success "Schlüssel aus Datei importiert: $key_file"
                    else
                        log_error "Import fehlgeschlagen"
                    fi
                else
                    log_error "Datei nicht gefunden: $key_file"
                fi
                ;;
            2)
                read -p "Email-Adresse oder Key-ID: " key_identifier
                read -p "Keyserver (Standard: keys.openpgp.org): " keyserver
                keyserver=${keyserver:-keys.openpgp.org}
                
                if gpg --keyserver "$keyserver" --recv-keys "$key_identifier" 2>/dev/null; then
                    imported_keys+=("$key_identifier")
                    log_success "Schlüssel vom Keyserver importiert: $key_identifier"
                else
                    log_error "Import vom Keyserver fehlgeschlagen"
                fi
                ;;
            3)
                echo ""
                log_info "Fügen Sie den öffentlichen GPG-Schlüssel ein:"
                echo "Beispiel Format:"
                echo "-----BEGIN PGP PUBLIC KEY BLOCK-----"
                echo "..."
                echo "-----END PGP PUBLIC KEY BLOCK-----"
                echo ""
                echo "Beenden mit Ctrl+D auf einer leeren Zeile:"
                echo ""
                
                local key_data
                key_data=$(cat)
                
                if [[ -n "$key_data" ]]; then
                    local temp_key_file
                    temp_key_file=$(mktemp)
                    echo "$key_data" > "$temp_key_file"
                    
                    if gpg --import "$temp_key_file" 2>/dev/null; then
                        local key_info
                        key_info=$(gpg --import --import-options show-only "$temp_key_file" 2>/dev/null | grep -E "^(pub|uid)")
                        
                        if [[ -n "$key_info" ]]; then
                            echo ""
                            log_success "Schlüssel erfolgreich importiert:"
                            echo "$key_info"
                            
                            local key_id
                            key_id=$(echo "$key_info" | grep "^pub" | awk '{print $2}' | cut -d'/' -f2)
                            if [[ -n "$key_id" ]]; then
                                imported_keys+=("$key_id")
                            fi
                        else
                            log_success "Schlüssel importiert"
                        fi
                    else
                        log_error "Import fehlgeschlagen - überprüfen Sie das Schlüssel-Format"
                    fi
                    
                    rm -f "$temp_key_file"
                else
                    log_info "Kein Schlüssel eingegeben"
                fi
                ;;
            4)
                log_info "Mehrere Schlüssel nacheinander importieren"
                echo "Geben Sie jeden Schlüssel einzeln ein, beenden Sie jeden mit Ctrl+D"
                echo ""
                
                local key_count=1
                while true; do
                    echo "Schlüssel #$key_count (oder leer lassen um zu beenden):"
                    local key_data
                    key_data=$(cat)
                    
                    if [[ -z "$key_data" ]] || [[ "$key_data" == *"quit"* ]]; then
                        log_info "Multi-Key-Import beendet"
                        break
                    fi
                    
                    local temp_key_file
                    temp_key_file=$(mktemp)
                    echo "$key_data" > "$temp_key_file"
                    
                    if gpg --import "$temp_key_file" 2>/dev/null; then
                        local key_info
                        key_info=$(gpg --import --import-options show-only "$temp_key_file" 2>/dev/null | grep -E "^(pub|uid)" | head -2)
                        log_success "Schlüssel #$key_count importiert:"
                        echo "$key_info"
                        
                        local key_id
                        key_id=$(echo "$key_info" | grep "^pub" | awk '{print $2}' | cut -d'/' -f2)
                        if [[ -n "$key_id" ]]; then
                            imported_keys+=("$key_id")
                        fi
                    else
                        log_error "Import von Schlüssel #$key_count fehlgeschlagen"
                    fi
                    
                    rm -f "$temp_key_file"
                    ((key_count++))
                    echo ""
                done
                ;;
            5)
                echo ""
                log_info "Aktuell importierte Schlüssel:"
                if [[ ${#imported_keys[@]} -eq 0 ]]; then
                    echo "Keine Schlüssel in dieser Session importiert"
                else
                    for key in "${imported_keys[@]}"; do
                        echo "  - $key"
                    done
                fi
                
                echo ""
                log_info "Alle verfügbaren öffentlichen Schlüssel:"
                gpg --list-keys --keyid-format LONG | grep -E "^(pub|uid)" || echo "Keine Schlüssel verfügbar"
                ;;
            6)
                log_info "Schlüssel-Import beendet"
                break
                ;;
            *)
                log_error "Ungültige Auswahl"
                ;;
        esac
    done
    
    # Zeige Zusammenfassung
    if [[ ${#imported_keys[@]} -gt 0 ]]; then
        echo ""
        log_success "Import-Session abgeschlossen. Importierte Schlüssel:"
        for key in "${imported_keys[@]}"; do
            echo "  ✓ $key"
        done
    fi
}

configure_gpg_backup() {
    log_info "Konfiguriere GPG-Einstellungen für Backups..."
    
    # Lade aktuelle .env oder erstelle sie
    if [[ ! -f ".env" ]]; then
        if [[ -f "nextcloud-caddy.env" ]]; then
            cp "nextcloud-caddy.env" ".env"
            log_info ".env aus Template erstellt"
        else
            log_error ".env Datei nicht gefunden"
            return 1
        fi
    fi
    
    # Liste verfügbare Schlüssel mit Auswahlmöglichkeit
    echo ""
    log_info "Verfügbare Schlüssel für Backup-Verschlüsselung:"
    
    # Sammle alle verfügbaren Keys
    local available_keys=()
    local key_info=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^pub ]]; then
            local key_id
            key_id=$(echo "$line" | awk '{print $2}' | cut -d'/' -f2)
            available_keys+=("$key_id")
            key_info+=("$line")
        elif [[ "$line" =~ ^uid ]] && [[ ${#available_keys[@]} -gt 0 ]]; then
            # Füge uid zur letzten Key-Info hinzu
            local last_idx=$((${#key_info[@]} - 1))
            key_info[$last_idx]="${key_info[$last_idx]}"$'\n'"$line"
        fi
    done < <(gpg --list-keys --keyid-format LONG --with-fingerprint)
    
    if [[ ${#available_keys[@]} -eq 0 ]]; then
        log_warning "Keine Schlüssel verfügbar"
        return 1
    fi
    
    # Zeige Keys mit Nummern
    for i in "${!available_keys[@]}"; do
        echo "$((i+1))) ${key_info[$i]}"
        echo ""
    done
    
    echo ""
    echo "Empfänger-Auswahl Optionen:"
    echo "1) Interaktive Auswahl (Nummern eingeben)"
    echo "2) Manuelle Eingabe (Email-Adressen/Key-IDs)"
    echo "3) Alle verfügbaren Schlüssel verwenden"
    
    read -p "Auswahl (1-3): " selection_method
    
    local recipients=""
    
    case $selection_method in
        1)
            echo ""
            echo "Wählen Sie Schlüssel aus (Nummern komma-separiert, z.B. 1,3,4):"
            read -p "Auswahl: " key_numbers
            
            IFS=',' read -ra selected_nums <<< "$key_numbers"
            local selected_recipients=()
            
            for num in "${selected_nums[@]}"; do
                # Entferne Leerzeichen
                num="${num// /}"
                if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -ge 1 ]] && [[ "$num" -le ${#available_keys[@]} ]]; then
                    local idx=$((num - 1))
                    selected_recipients+=("${available_keys[$idx]}")
                    log_info "Ausgewählt: ${available_keys[$idx]}"
                else
                    log_warning "Ungültige Auswahl ignoriert: $num"
                fi
            done
            
            if [[ ${#selected_recipients[@]} -gt 0 ]]; then
                recipients=$(IFS=','; echo "${selected_recipients[*]}")
            else
                log_error "Keine gültigen Schlüssel ausgewählt"
                return 1
            fi
            ;;
        2)
            echo ""
            echo "Geben Sie die Empfänger manuell ein:"
            echo "(Email-Adressen oder Key-IDs, komma-separiert)"
            echo "Beispiel: admin@example.com,backup@company.com,ABCD1234EFGH5678"
            read -p "GPG-Empfänger: " recipients
            ;;
        3)
            recipients=$(IFS=','; echo "${available_keys[*]}")
            log_info "Alle verfügbaren Schlüssel als Empfänger ausgewählt"
            ;;
        *)
            log_error "Ungültige Auswahl"
            return 1
            ;;
    esac
    
    if [[ -z "$recipients" ]]; then
        log_warning "Keine Empfänger angegeben, GPG-Verschlüsselung deaktiviert"
        recipients=""
        encryption_enabled="false"
    else
        encryption_enabled="true"
    fi
    
    # Wähle zu verschlüsselnde Backup-Typen
    echo ""
    echo "Welche Backup-Typen sollen verschlüsselt werden?"
    echo "1) Nur Secrets und Datenbank (empfohlen)"
    echo "2) Alle Backups"
    echo "3) Nur Secrets"
    echo "4) Nur Datenbank"
    echo "5) Benutzerdefiniert"
    echo "6) Keine Verschlüsselung"
    
    read -p "Auswahl (1-6): " encrypt_choice
    
    case $encrypt_choice in
        1) encrypt_types="database,secrets" ;;
        2) encrypt_types="all" ;;
        3) encrypt_types="secrets" ;;
        4) encrypt_types="database" ;;
        5) 
            echo "Verfügbare Typen: database, secrets, data, config, volumes, logs"
            read -p "Typen (komma-separiert): " encrypt_types
            ;;
        6) 
            encrypt_types="none"
            encryption_enabled="false"
            ;;
        *) 
            log_warning "Ungültige Auswahl, verwende Standard"
            encrypt_types="database,secrets"
            ;;
    esac
    
    # Aktualisiere .env
    sed -i.bak "s/^BACKUP_GPG_ENCRYPTION=.*/BACKUP_GPG_ENCRYPTION=$encryption_enabled/" .env
    sed -i.bak "s/^BACKUP_GPG_RECIPIENTS=.*/BACKUP_GPG_RECIPIENTS=\"$recipients\"/" .env
    sed -i.bak "s/^BACKUP_GPG_ENCRYPT_TYPES=.*/BACKUP_GPG_ENCRYPT_TYPES=\"$encrypt_types\"/" .env
    
    # Entferne Backup-Datei
    rm -f .env.bak
    
    log_success "GPG-Konfiguration in .env aktualisiert"
    
    # Zeige Konfiguration
    echo ""
    log_info "Aktuelle GPG-Konfiguration:"
    grep "BACKUP_GPG_" .env
}

test_gpg_encryption() {
    log_info "Teste GPG-Verschlüsselung..."
    
    # Lade Konfiguration
    source .env 2>/dev/null || {
        log_error "Konnte .env nicht laden"
        return 1
    }
    
    if [[ "${BACKUP_GPG_ENCRYPTION:-false}" != "true" ]]; then
        log_warning "GPG-Verschlüsselung ist deaktiviert"
        return 0
    fi
    
    if [[ -z "${BACKUP_GPG_RECIPIENTS:-}" ]]; then
        log_error "Keine GPG-Empfänger konfiguriert"
        return 1
    fi
    
    # Erstelle Test-Datei
    local test_file
    test_file=$(mktemp)
    echo "GPG Backup Encryption Test - $(date)" > "$test_file"
    
    # Teste Verschlüsselung
    local encrypted_file="${test_file}.gpg"
    
    IFS=',' read -ra recipients <<< "${BACKUP_GPG_RECIPIENTS}"
    local gpg_recipients=()
    for recipient in "${recipients[@]}"; do
        gpg_recipients+=("-r" "${recipient// /}")
    done
    
    if gpg --trust-model always --compress-algo "${BACKUP_GPG_COMPRESSION:-6}" \
        --cipher-algo "${BACKUP_GPG_CIPHER:-AES256}" \
        --encrypt "${gpg_recipients[@]}" \
        --output "$encrypted_file" "$test_file"; then
        
        log_success "Test-Verschlüsselung erfolgreich"
        
        # Teste Entschlüsselung
        local decrypted_file="${test_file}.dec"
        if gpg --quiet --decrypt --output "$decrypted_file" "$encrypted_file" 2>/dev/null; then
            log_success "Test-Entschlüsselung erfolgreich"
            
            # Vergleiche Dateien
            if cmp -s "$test_file" "$decrypted_file"; then
                log_success "GPG-Verschlüsselung funktioniert korrekt!"
            else
                log_error "Entschlüsselte Datei stimmt nicht mit Original überein"
            fi
        else
            log_error "Test-Entschlüsselung fehlgeschlagen"
        fi
        
        # Cleanup
        rm -f "$test_file" "$encrypted_file" "$decrypted_file"
    else
        log_error "Test-Verschlüsselung fehlgeschlagen"
        rm -f "$test_file"
        return 1
    fi
}

setup_gpg() {
    log_info "GPG-Setup für Backup-Verschlüsselung wird gestartet..."
    
    # Überprüfungen
    check_gpg_installation
    show_existing_keys
    
    # Hauptmenü
    echo "Was möchten Sie tun?"
    echo "1) GPG-Schlüssel importieren"
    echo "2) GPG-Backup-Konfiguration einrichten"
    echo "3) GPG-Verschlüsselung testen"
    echo "4) Alles (Import + Konfiguration + Test)"
    
    read -p "Auswahl (1-4): " gpg_choice
    
    case $gpg_choice in
        1)
            import_gpg_keys
            ;;
        2)
            configure_gpg_backup
            ;;
        3)
            test_gpg_encryption
            ;;
        4)
            log_info "Führe vollständiges GPG-Setup durch..."
            import_gpg_keys
            echo ""
            configure_gpg_backup
            echo ""
            test_gpg_encryption
            ;;
        *)
            log_error "Ungültige Auswahl"
            exit 1
            ;;
    esac
    
    echo ""
    log_success "GPG-Setup abgeschlossen!"
}

# =============================================================================
# HOST-CRON SETUP
# =============================================================================

setup_host_cron() {
    log_info "Host-System Cron Setup wird gestartet..."
    
    # Überprüfe ob bereits ein Nextcloud-Cron existiert
    if crontab -l 2>/dev/null | grep -q "nextcloud-cron"; then
        log_warning "Nextcloud Cron-Job bereits vorhanden"
        echo ""
        echo "Aktuelle Cron-Jobs:"
        crontab -l | grep "nextcloud-cron" || true
        echo ""
        read -p "Bestehenden Cron-Job ersetzen? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cron-Setup abgebrochen"
            return 0
        fi
        
        # Entferne alte Nextcloud-Cron-Jobs
        log_info "Entferne alte Nextcloud-Cron-Jobs..."
        (crontab -l 2>/dev/null | grep -v "nextcloud-cron") | crontab -
    fi
    
    # Erstelle Log-Verzeichnis
    mkdir -p "$SCRIPT_DIR/logs"
    
    # Füge neuen Cron-Job hinzu
    log_info "Füge Host-Cron-Job hinzu (alle 5 Minuten)..."
    (crontab -l 2>/dev/null; echo "# Nextcloud Host Cron (OCC method)") | crontab -
    (crontab -l 2>/dev/null; echo "*/5 * * * * $SCRIPT_DIR/nextcloud-cron-host.sh # nextcloud-cron") | crontab -
    
    log_success "Host-Cron erfolgreich eingerichtet!"
    
    # Zeige aktuellen Cron-Job
    echo ""
    echo "Aktueller Cron-Job:"
    crontab -l | grep "nextcloud-cron" || true
    
    echo ""
    echo "Cron-Script: $SCRIPT_DIR/nextcloud-cron-host.sh"
    echo "Logs: $SCRIPT_DIR/logs/nextcloud-cron.log"
}

# =============================================================================
# USER SETUP FUNKTIONEN
# =============================================================================

# Funktion: Nextcloud User Setup mit Sicherheitsprüfungen
setup_nextcloud_user() {
    echo ""
    log_info "Benutzer-Konfiguration für Nextcloud..."
    
    CURRENT_UID=$(id -u)
    CURRENT_GID=$(id -g)
    CURRENT_USER=$(whoami)
    
    # Warnung bei Root-Ausführung
    if [[ $CURRENT_UID -eq 0 ]]; then
        echo ""
        log_warning "⚠️  Das Script läuft als ROOT!"
        echo "   Für bessere Sicherheit wird ein dedizierter Nextcloud-User empfohlen."
        echo ""
        echo "Optionen:"
        echo "1) Dedizierten 'nextcloud' User erstellen (EMPFOHLEN)"
        echo "2) Bestehenden User verwenden"
        echo "3) Als root weitermachen (NICHT EMPFOHLEN)"
        echo ""
        
        while true; do
            read -p "Auswahl [1-3]: " user_choice
            case $user_choice in
                1)
                    create_dedicated_nextcloud_user
                    break
                    ;;
                2)
                    select_existing_user
                    break
                    ;;
                3)
                    log_warning "⚠️  Verwende ROOT - Sicherheitsrisiko!"
                    NC_UID=0
                    NC_GID=0
                    NC_USER="root"
                    NC_HOME="/root"
                    break
                    ;;
                *)
                    echo "Bitte 1, 2 oder 3 wählen."
                    ;;
            esac
        done
    else
        # Nicht-Root: Aktuellen User als Standard anbieten
        echo "Aktueller Benutzer: $CURRENT_USER (UID: $CURRENT_UID, GID: $CURRENT_GID)"
        echo ""
        echo "Optionen:"
        echo "1) Aktuellen User verwenden (Standard)"
        echo "2) Dedizierten 'nextcloud' User erstellen"
        echo "3) Anderen User wählen"
        echo ""
        
        read -p "Auswahl [1-3, Standard=1]: " user_choice
        user_choice=${user_choice:-1}
        
        case $user_choice in
            1)
                NC_UID=$CURRENT_UID
                NC_GID=$CURRENT_GID
                NC_USER=$CURRENT_USER
                NC_HOME=$(eval echo "~$CURRENT_USER")
                log_info "Verwende aktuellen User: $NC_USER"
                ;;
            2)
                create_dedicated_nextcloud_user
                ;;
            3)
                select_existing_user
                ;;
            *)
                log_info "Verwende Standard: aktueller User"
                NC_UID=$CURRENT_UID
                NC_GID=$CURRENT_GID
                NC_USER=$CURRENT_USER
                NC_HOME=$(eval echo "~$CURRENT_USER")
                ;;
        esac
    fi
    
    # Aktualisiere Standard-Pfade basierend auf User-Home
    update_default_paths
    
    echo ""
    log_info "Gewählte Konfiguration:"
    echo "   User: $NC_USER (UID: $NC_UID, GID: $NC_GID)"
    echo "   Home: $NC_HOME"
    echo "   Daten: $DATA_DIR"
    echo ""
}

# Funktion: Dedizierten Nextcloud User erstellen
create_dedicated_nextcloud_user() {
    log_info "Erstelle dedizierten 'nextcloud' User..."
    
    # Prüfe ob User bereits existiert
    if id "nextcloud" &>/dev/null; then
        log_info "User 'nextcloud' existiert bereits."
        NC_USER="nextcloud"
        NC_UID=$(id -u nextcloud)
        NC_GID=$(id -g nextcloud)
        NC_HOME=$(eval echo "~nextcloud")
    else
        # Erstelle User mit eigenem Home-Verzeichnis
        if command -v useradd &>/dev/null; then
            # Linux (useradd)
            sudo useradd -r -m -s /bin/bash -c "Nextcloud Service User" nextcloud
        elif command -v adduser &>/dev/null; then
            # Alternative (adduser)
            sudo adduser --system --group --home /home/nextcloud --shell /bin/bash nextcloud
        else
            log_error "Kann keinen User erstellen - weder 'useradd' noch 'adduser' verfügbar!"
            exit 1
        fi
        
        # User zu Docker-Gruppe hinzufügen (falls vorhanden)
        if getent group docker &>/dev/null; then
            sudo usermod -aG docker nextcloud
            log_info "User 'nextcloud' zu Docker-Gruppe hinzugefügt."
        fi
        
        NC_USER="nextcloud"
        NC_UID=$(id -u nextcloud)
        NC_GID=$(id -g nextcloud)
        NC_HOME="/home/nextcloud"
        
        log_success "User 'nextcloud' erfolgreich erstellt!"
    fi
}

# Funktion: Bestehenden User auswählen
select_existing_user() {
    echo ""
    echo "Verfügbare Benutzer (UID >= 1000):"
    
    # Liste verfügbare User
    local users=()
    while IFS=: read -r username _ uid gid _ _ home _; do
        if [[ $uid -ge 1000 && $uid -lt 65534 ]]; then
            users+=("$username:$uid:$gid:$home")
            echo "   $username (UID: $uid, GID: $gid, Home: $home)"
        fi
    done < /etc/passwd
    
    if [[ ${#users[@]} -eq 0 ]]; then
        log_error "Keine geeigneten Benutzer gefunden!"
        exit 1
    fi
    
    echo ""
    read -p "Benutzername eingeben: " selected_user
    
    if id "$selected_user" &>/dev/null; then
        NC_USER="$selected_user"
        NC_UID=$(id -u "$selected_user")
        NC_GID=$(id -g "$selected_user")
        NC_HOME=$(eval echo "~$selected_user")
        log_info "Gewählter User: $NC_USER"
    else
        log_error "User '$selected_user' existiert nicht!"
        exit 1
    fi
}

# Funktion: Standard-Pfade basierend auf User-Home aktualisieren
update_default_paths() {
    # Standard-Pfade in User-Home setzen
    DATA_DIR="$NC_HOME/nextcloud-data"
    SECRETS_DIR="$NC_HOME/nextcloud-secrets"
    BACKUP_DIR="$NC_HOME/nextcloud-backups"
    
    # Falls bereits lokale Verzeichnisse existieren, diese bevorzugen
    if [[ -d "./secrets" ]]; then
        SECRETS_DIR="$(pwd)/secrets"
        log_info "Lokales secrets-Verzeichnis gefunden, wird verwendet"
    fi
    
    if [[ -d "./backups" ]]; then
        BACKUP_DIR="$(pwd)/backups"
        log_info "Lokales backups-Verzeichnis gefunden, wird verwendet"
    fi
    
    if [[ -d "./nextcloud-data" ]]; then
        log_info "Lokales nextcloud-data-Verzeichnis gefunden"
        echo "   Lokal: $(pwd)/nextcloud-data"
        echo "   User-Home: $DATA_DIR"
        read -p "Lokales Verzeichnis verwenden? (y/N): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            DATA_DIR="$(pwd)/nextcloud-data"
            log_info "Lokales Daten-Verzeichnis wird verwendet"
        fi
    fi
}

# =============================================================================
# NEXTCLOUD SETUP
# =============================================================================

nextcloud_setup() {
    log_info "Nextcloud-Setup wird gestartet..."

    # Überprüfe erforderliche Programme
    log_info "Überprüfe erforderliche Programme..."
    check_command "docker"
    # Docker Compose (check both docker-compose and docker compose)
    if command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
        log_warning "Verwende veraltetes 'docker-compose'. Empfehlung: Verwende 'docker compose'"
    elif docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
    else
        log_error "Docker Compose ist nicht verfügbar (weder docker-compose noch docker compose)"
        exit 1
    fi
    check_command "openssl"

    # Überprüfe ob bereits eine .env existiert
    if [[ -f ".env" ]]; then
        log_warning "Eine .env Datei existiert bereits."
        read -p "Möchten Sie sie überschreiben? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Setup abgebrochen."
            return 0
        fi
    fi

    # Sammle Konfigurationsinformationen
    echo ""
    log_info "Konfiguration sammeln..."

    # Domain
    read -p "Nextcloud Domain (z.B. cloud.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        log_error "Domain ist erforderlich!"
        exit 1
    fi

    # Email für Let's Encrypt
    read -p "Email für Let's Encrypt Zertifikate: " EMAIL
    if [[ -z "$EMAIL" ]]; then
        log_error "Email ist erforderlich!"
        exit 1
    fi

    # Datenbanktyp
    echo ""
    log_info "Datenbanktyp auswählen:"
    echo "1) Docker PostgreSQL (empfohlen für neue Installationen)"
    echo "2) Externe Datenbank auf Host-System"
    read -p "Auswahl (1-2): " DB_CHOICE

    case $DB_CHOICE in
        1)
            DATABASE_TYPE="docker"
            DB_HOST="postgres"
            USE_DOCKER_DB=true
            ;;
        2)
            DATABASE_TYPE="external"
            read -p "Datenbank Host (IP oder Hostname): " DB_HOST
            if [[ -z "$DB_HOST" ]]; then
                log_error "Datenbank Host ist erforderlich!"
                exit 1
            fi
            USE_DOCKER_DB=false
            ;;
        *)
            log_error "Ungültige Auswahl!"
            exit 1
            ;;
    esac

    # Datenbank Credentials
    read -p "Datenbank Name [nextcloud]: " DB_NAME
    DB_NAME=${DB_NAME:-nextcloud}

    read -p "Datenbank Benutzer [nextcloud]: " DB_USER
    DB_USER=${DB_USER:-nextcloud}

    # Admin User
    read -p "Nextcloud Admin Benutzername [admin]: " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}

    # User IDs - mit Sicherheitsprüfung und dediziertem User
    setup_nextcloud_user

    # Data Directory - NACH User-Bestimmung mit intelligentem Standard
    echo ""
    log_info "Daten-Verzeichnis konfigurieren..."
    echo "Empfohlener Pfad basierend auf User '$NC_USER': $DATA_DIR"
    read -p "Nextcloud Daten Verzeichnis [$DATA_DIR]: " USER_DATA_DIR
    if [[ -n "$USER_DATA_DIR" ]]; then
        DATA_DIR="$USER_DATA_DIR"
        log_info "Benutzerdefiniertes Verzeichnis gewählt: $DATA_DIR"
    else
        log_info "Standard-Verzeichnis verwendet: $DATA_DIR"
    fi

    # Erstelle Verzeichnisse
    log_info "Erstelle erforderliche Verzeichnisse..."
    mkdir -p "$SECRETS_DIR"
    mkdir -p "$DATA_DIR"
    mkdir -p "$BACKUP_DIR/postgres"
    mkdir -p "$BACKUP_DIR/data"
    
    # Erstelle Symlink zu Secrets für Docker Compose
    if [[ "$SECRETS_DIR" != "$(pwd)/secrets" ]]; then
        log_info "Erstelle Symlink für Docker Compose Secrets..."
        # Entferne existierenden Symlink oder Verzeichnis
        rm -rf ./secrets
        # Erstelle Symlink zum echten Secrets-Verzeichnis
        ln -sf "$SECRETS_DIR" ./secrets
        log_success "Symlink erstellt: ./secrets -> $SECRETS_DIR"
    fi
    
    # Setze korrekte Berechtigungen für User-Verzeichnisse
    if [[ "$NC_USER" != "root" && "$NC_USER" != "$CURRENT_USER" ]]; then
        sudo chown -R "$NC_UID:$NC_GID" "$DATA_DIR" "$BACKUP_DIR" "$SECRETS_DIR" 2>/dev/null || true
    fi

    # Generiere Passwörter
    log_info "Generiere sichere Passwörter..."
    DB_PASSWORD=$(generate_password)
    REDIS_PASSWORD=$(generate_password)
    ADMIN_PASSWORD=$(generate_password)

    # Speichere Passwörter in secrets
    echo "$DB_PASSWORD" > "$SECRETS_DIR/postgres_password.txt"
    echo "$REDIS_PASSWORD" > "$SECRETS_DIR/redis_password.txt"
    echo "$ADMIN_PASSWORD" > "$SECRETS_DIR/nextcloud_admin_password.txt"

    # Setze Berechtigungen für secrets
    chmod 600 "$SECRETS_DIR"/*.txt

    # Erstelle .env Datei
    log_info "Erstelle .env Datei..."
    cat > .env << EOF
# Nextcloud Caddy Docker Compose Environment Variables
# Generiert von nextcloud-manager.sh am $(date)

# =============================================================================
# ALLGEMEINE KONFIGURATION
# =============================================================================

NEXTCLOUD_HOSTNAME=$DOMAIN
NEXTCLOUD_URL=https://$DOMAIN
ACME_EMAIL=$EMAIL

# =============================================================================
# DATENBANK KONFIGURATION
# =============================================================================

DATABASE_TYPE=$DATABASE_TYPE
DB_HOST=$DB_HOST
NEXTCLOUD_POSTGRES_IMAGE_TAG=postgres:16-alpine

NEXTCLOUD_DB_NAME=$DB_NAME
NEXTCLOUD_DB_USER=$DB_USER

# =============================================================================
# NEXTCLOUD KONFIGURATION
# =============================================================================

NEXTCLOUD_FPM_IMAGE_TAG=nextcloud:29-fpm-alpine
CADDY_IMAGE_TAG=caddy:2-alpine
NEXTCLOUD_REDIS_IMAGE_TAG=redis:7-alpine
NOTIFY_PUSH_IMAGE_TAG=nextcloud/notify_push:v0.6.9
IMAGINARY_IMAGE_TAG=nextcloud/aio-imaginary:latest

NEXTCLOUD_ADMIN_USERNAME=$ADMIN_USER
NEXTCLOUD_DATA_DIR=$DATA_DIR

NEXTCLOUD_USER_ID=$NC_UID
NEXTCLOUD_GROUP_ID=$NC_GID
REDIS_USER_ID=1001
REDIS_GROUP_ID=1001

# Pfade
SECRETS_DIR=$SECRETS_DIR
BACKUP_DIR=$BACKUP_DIR

TRUSTED_PROXIES=172.16.0.0/12

# =============================================================================
# BACKUP KONFIGURATION
# =============================================================================

DATA_PATH=/var/www/html/data
POSTGRES_BACKUPS_PATH=$BACKUP_DIR/postgres
DATA_BACKUPS_PATH=$BACKUP_DIR/data

POSTGRES_BACKUP_NAME=nextcloud-postgres-backup
DATA_BACKUP_NAME=nextcloud-data-backup

BACKUP_INIT_SLEEP=30m
BACKUP_INTERVAL=1d
POSTGRES_BACKUP_PRUNE_DAYS=7
DATA_BACKUP_PRUNE_DAYS=7

# =============================================================================
# GPG VERSCHLÜSSELUNG
# =============================================================================

BACKUP_GPG_ENCRYPTION=false
BACKUP_GPG_RECIPIENTS=""
BACKUP_GPG_ENCRYPT_TYPES="database,secrets"
BACKUP_GPG_HOMEDIR=""
BACKUP_GPG_COMPRESSION=6
BACKUP_GPG_CIPHER="AES256"

# =============================================================================
# ERWEITERTE EINSTELLUNGEN
# =============================================================================

# HINWEIS: PHP-Einstellungen sind in nextcloud.env konfiguriert
# HINWEIS: Caddy-Logging wird über Caddyfile konfiguriert
EOF

    # Erstelle Docker Networks
    log_info "Erstelle Docker Networks..."
    docker network create caddy-network 2>/dev/null || log_warning "Network 'caddy-network' existiert bereits"
    docker network create nextcloud-network 2>/dev/null || log_warning "Network 'nextcloud-network' existiert bereits"

    # Setze Berechtigungen für Data Directory
    log_info "Setze Berechtigungen für Daten-Verzeichnis..."
    sudo chown -R "$NC_UID:$NC_GID" "$DATA_DIR" 2>/dev/null || log_warning "Konnte Berechtigungen nicht setzen (sudo erforderlich)"

    # Zeige Zusammenfassung
    echo ""
    log_success "Nextcloud-Setup abgeschlossen!"
    echo ""
    echo -e "${YELLOW}=== KONFIGURATION ZUSAMMENFASSUNG ===${NC}"
    echo "Domain: $DOMAIN"
    echo "Email: $EMAIL"
    echo "Datenbanktyp: $DATABASE_TYPE"
    echo "Datenbank Host: $DB_HOST"
    echo "Datenbank Name: $DB_NAME"
    echo "Datenbank Benutzer: $DB_USER"
    echo "Admin Benutzer: $ADMIN_USER"
    echo "Data Directory: $DATA_DIR"
    echo ""
    echo -e "${YELLOW}=== GENERIERTE PASSWÖRTER ===${NC}"
    echo "Datenbank Passwort: $DB_PASSWORD"
    echo "Redis Passwort: $REDIS_PASSWORD"
    echo "Admin Passwort: $ADMIN_PASSWORD"
    echo ""
    echo -e "${YELLOW}=== NÄCHSTE SCHRITTE ===${NC}"

    if [[ "$DATABASE_TYPE" == "external" ]]; then
        echo "1. Stellen Sie sicher, dass die externe Datenbank läuft und erreichbar ist"
        echo "2. Erstellen Sie die Datenbank '$DB_NAME' und den Benutzer '$DB_USER'"
        echo "3. Starten Sie Nextcloud ohne PostgreSQL: docker compose -f nextcloud-caddy-docker-compose.yml up -d"
    else
        echo "1. Starten Sie Nextcloud mit PostgreSQL: docker compose -f nextcloud-caddy-docker-compose.yml --profile docker-db up -d"
    fi

    echo "2. Warten Sie bis alle Container gestartet sind ($DOCKER_COMPOSE logs -f)"
    echo "3. Installieren und konfigurieren Sie Notify Push für bessere Performance:"
    echo "   $DOCKER_COMPOSE exec app php occ app:install notify_push"
    echo "   $DOCKER_COMPOSE exec app php occ notify_push:setup https://$DOMAIN/push"
    echo "   $DOCKER_COMPOSE exec app php occ notify_push:self-test"
    echo "4. Öffnen Sie https://$DOMAIN in Ihrem Browser"
    echo "5. Loggen Sie sich mit Benutzername '$ADMIN_USER' und dem generierten Passwort ein"
    echo ""
    echo -e "${GREEN}Passwörter wurden in $SECRETS_DIR/ gespeichert - bewahren Sie diese sicher auf!${NC}"

    # Optional: GPG-Setup
    echo ""
    read -p "Möchten Sie GPG-Verschlüsselung für Backups einrichten? (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        setup_gpg
    fi

    # Host-Cron einrichten
    echo ""
    read -p "Host-System Cron für Nextcloud einrichten? (Y/n): " -r
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        log_info "Richte Host-System Cron ein..."
        
        # Füge Cron-Job hinzu
        (crontab -l 2>/dev/null; echo "# Nextcloud Host Cron (OCC method)") | crontab -
        (crontab -l 2>/dev/null; echo "*/5 * * * * $SCRIPT_DIR/nextcloud-cron-host.sh # nextcloud-cron") | crontab -
        
        log_success "Host-Cron eingerichtet (alle 5 Minuten)"
        echo "Cron-Script: $SCRIPT_DIR/nextcloud-cron-host.sh"
        echo "Logs: $SCRIPT_DIR/logs/nextcloud-cron.log"
    else
        log_warning "Host-Cron übersprungen. Du kannst ihn später einrichten mit:"
        echo "./nextcloud-manager.sh setup-cron"
    fi

    # Optional: Starte direkt
    echo ""
    read -p "Möchten Sie Nextcloud jetzt starten? (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Starte Nextcloud..."
        if [[ "$USE_DOCKER_DB" == true ]]; then
            $DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml --profile docker-db up -d
        else
            $DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml up -d
        fi
        
        log_success "Nextcloud wird gestartet. Überprüfen Sie den Status mit:"
        echo "$DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml logs -f"
        
        # Teste Host-Cron falls eingerichtet
        if crontab -l 2>/dev/null | grep -q "nextcloud-cron"; then
            echo ""
            log_info "Teste Host-Cron-Setup..."
            sleep 5  # Warte bis Container gestartet sind
            if "$SCRIPT_DIR/nextcloud-cron-host.sh"; then
                log_success "Host-Cron funktioniert!"
            else
                log_warning "Host-Cron-Test fehlgeschlagen - prüfe später manuell"
            fi
        fi
    fi
}

# =============================================================================
# STATUS UND TEST FUNKTIONEN
# =============================================================================

show_status() {
    log_info "System-Status wird überprüft..."
    
    # Docker Compose Command detection
    local DOCKER_COMPOSE=""
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
    fi
    
    # Docker Status
    echo ""
    echo "=== DOCKER STATUS ==="
    if command -v docker &> /dev/null; then
        echo "Docker: $(docker --version)"
        if [[ -n "$DOCKER_COMPOSE" ]]; then
            echo "Docker Compose: $($DOCKER_COMPOSE --version)"
        else
            echo "Docker Compose: Nicht verfügbar"
        fi
        
        # Container Status
        if [[ -f "nextcloud-caddy-docker-compose.yml" ]] && [[ -n "$DOCKER_COMPOSE" ]]; then
            echo ""
            echo "Container Status:"
            $DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml ps || echo "Keine Container gefunden"
        fi
    else
        echo "Docker: Nicht installiert"
    fi
    
    # GPG Status
    echo ""
    echo "=== GPG STATUS ==="
    if command -v gpg &> /dev/null; then
        echo "GPG: $(gpg --version | head -1)"
        local key_count
        key_count=$(gpg --list-keys 2>/dev/null | grep -c "^pub" || echo "0")
        echo "Verfügbare Schlüssel: $key_count"
    else
        echo "GPG: Nicht installiert"
    fi
    
    # Konfiguration Status
    echo ""
    echo "=== KONFIGURATION STATUS ==="
    if [[ -f ".env" ]]; then
        echo ".env: Vorhanden"
        if grep -q "BACKUP_GPG_ENCRYPTION=true" .env 2>/dev/null; then
            echo "GPG-Verschlüsselung: Aktiviert"
        else
            echo "GPG-Verschlüsselung: Deaktiviert"
        fi
    else
        echo ".env: Nicht gefunden"
    fi
    
    SECRETS_DIR=${SECRETS_DIR:-"./secrets"}
    if [[ -d "$SECRETS_DIR" ]]; then
        local secret_count
        secret_count=$(find "$SECRETS_DIR" -name "*.txt" | wc -l)
        echo "Secrets: $secret_count Dateien"
    else
        echo "Secrets: Verzeichnis nicht gefunden ($SECRETS_DIR)"
    fi
    
    # Backup Status
    echo ""
    echo "=== BACKUP STATUS ==="
    BACKUP_DIR=${BACKUP_DIR:-"./backups"}
    if [[ -d "$BACKUP_DIR" ]]; then
        for backup_type in database data config volumes logs; do
            if [[ -d "$BACKUP_DIR/$backup_type" ]]; then
                local count
                count=$(find "$BACKUP_DIR/$backup_type" -type f | wc -l)
                echo "$backup_type: $count Backups"
            fi
        done
    else
        echo "Backup-Verzeichnis: Nicht gefunden ($BACKUP_DIR)"
    fi
}

test_configuration() {
    log_info "Teste Konfiguration..."
    
    local tests_passed=0
    local tests_total=0
    
    # Test 1: .env Datei
    ((tests_total++))
    if [[ -f ".env" ]]; then
        log_success "✓ .env Datei vorhanden"
        ((tests_passed++))
    else
        log_error "✗ .env Datei fehlt"
    fi
    
    # Test 2: Secrets
    ((tests_total++))
    SECRETS_DIR=${SECRETS_DIR:-"./secrets"}
    if [[ -d "$SECRETS_DIR" ]] && ls "$SECRETS_DIR"/*.txt &>/dev/null; then
        log_success "✓ Secrets vorhanden"
        ((tests_passed++))
    else
        log_error "✗ Secrets fehlen"
    fi
    
    # Test 3: Docker Networks
    ((tests_total++))
    if command -v docker &>/dev/null; then
        if docker network inspect caddy-network &>/dev/null && docker network inspect nextcloud-network &>/dev/null; then
            log_success "✓ Docker Networks vorhanden"
            ((tests_passed++))
        else
            log_error "✗ Docker Networks fehlen"
        fi
    else
        log_warning "✗ Docker nicht verfügbar - Networks können nicht geprüft werden"
    fi
    
    # Test 4: GPG (falls aktiviert)
    if [[ -f ".env" ]] && grep -q "BACKUP_GPG_ENCRYPTION=true" .env 2>/dev/null; then
        ((tests_total++))
        if command -v gpg &>/dev/null && [[ -n "$(gpg --list-keys 2>/dev/null)" ]]; then
            log_success "✓ GPG konfiguriert"
            ((tests_passed++))
        else
            log_error "✗ GPG nicht konfiguriert"
        fi
    fi
    
    # Test 5: Docker Compose Datei
    ((tests_total++))
    if [[ -f "nextcloud-caddy-docker-compose.yml" ]]; then
        log_success "✓ Docker Compose Datei vorhanden"
        ((tests_passed++))
    else
        log_error "✗ Docker Compose Datei fehlt"
    fi
    
    echo ""
    if [[ $tests_passed -eq $tests_total ]]; then
        log_success "Alle Tests bestanden ($tests_passed/$tests_total)"
    else
        log_warning "Tests bestanden: $tests_passed/$tests_total"
    fi
}

# =============================================================================
# CONTAINER MANAGEMENT FUNKTIONEN
# =============================================================================

# Funktion: Nextcloud starten
start_nextcloud() {
    log_info "Starte Nextcloud Container..."
    
    # Docker Compose Command detection
    local DOCKER_COMPOSE=""
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
    else
        log_error "Docker Compose ist nicht verfügbar!"
        return 1
    fi
    
    # Prüfe ob .env existiert
    if [[ ! -f ".env" ]]; then
        log_error ".env Datei nicht gefunden! Führe erst das Setup aus."
        return 1
    fi
    
    # Lade .env um USE_DOCKER_DB zu prüfen
    source .env
    
    # Prüfe und erstelle Secrets-Symlink falls nötig
    if [[ ! -e "./secrets" ]]; then
        if [[ -n "${SECRETS_DIR:-}" && -d "$SECRETS_DIR" ]]; then
            log_info "Erstelle fehlenden Secrets-Symlink..."
            ln -sf "$SECRETS_DIR" ./secrets
        else
            log_error "Secrets-Verzeichnis nicht gefunden! Führe erst das Setup aus."
            return 1
        fi
    fi
    
    # Starte Container basierend auf DB-Konfiguration
    if [[ "${USE_DOCKER_DB:-false}" == "true" ]]; then
        log_info "Starte mit Docker PostgreSQL..."
        $DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml --profile docker-db up -d
    else
        log_info "Starte ohne Docker PostgreSQL (externe DB)..."
        $DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml up -d
    fi
    
    if [[ $? -eq 0 ]]; then
        log_success "Nextcloud Container gestartet!"
        echo ""
        echo "Überwachen Sie die Logs mit:"
        echo "$DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml logs -f"
        echo ""
        echo "Status prüfen mit:"
        echo "$DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml ps"
    else
        log_error "Fehler beim Starten der Container!"
        return 1
    fi
}

# Funktion: Nextcloud stoppen
stop_nextcloud() {
    log_info "Stoppe Nextcloud Container..."
    
    # Docker Compose Command detection
    local DOCKER_COMPOSE=""
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
    else
        log_error "Docker Compose ist nicht verfügbar!"
        return 1
    fi
    
    # Stoppe alle Container
    $DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml --profile docker-db down
    
    if [[ $? -eq 0 ]]; then
        log_success "Nextcloud Container gestoppt!"
    else
        log_error "Fehler beim Stoppen der Container!"
        return 1
    fi
}

# Funktion: Nextcloud neustarten
restart_nextcloud() {
    log_info "Starte Nextcloud Container neu..."
    
    stop_nextcloud
    if [[ $? -eq 0 ]]; then
        sleep 3
        start_nextcloud
    else
        log_error "Neustart fehlgeschlagen - Stoppen nicht erfolgreich!"
        return 1
    fi
}

# Funktion: Container Status anzeigen
show_container_status() {
    log_info "Container Status..."
    
    # Docker Compose Command detection
    local DOCKER_COMPOSE=""
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
    else
        log_error "Docker Compose ist nicht verfügbar!"
        return 1
    fi
    
    echo ""
    echo "=== CONTAINER STATUS ==="
    $DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml ps
    
    echo ""
    echo "=== CONTAINER LOGS (letzte 20 Zeilen) ==="
    $DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml logs --tail=20
}

# Funktion: Container Logs anzeigen
show_logs() {
    log_info "Zeige Container Logs..."
    
    # Docker Compose Command detection
    local DOCKER_COMPOSE=""
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
    else
        log_error "Docker Compose ist nicht verfügbar!"
        return 1
    fi
    
    echo ""
    echo "Verwende Ctrl+C zum Beenden"
    echo ""
    $DOCKER_COMPOSE -f nextcloud-caddy-docker-compose.yml logs -f
}

# =============================================================================
# INTERAKTIVES MENÜ
# =============================================================================

interactive_menu() {
    while true; do
        show_banner
        echo "Nextcloud Caddy Management"
        echo ""
        echo "=== SETUP & KONFIGURATION ==="
        echo "1) Vollständiges Nextcloud-Setup"
        echo "2) GPG-Verschlüsselung einrichten"
        echo "3) GPG-Schlüssel importieren"
        echo "4) Secrets verwalten"
        echo "5) Host-System Cron einrichten"
        echo ""
        echo "=== CONTAINER MANAGEMENT ==="
        echo "6) Nextcloud starten"
        echo "7) Nextcloud stoppen" 
        echo "8) Nextcloud neustarten"
        echo "9) Container Status anzeigen"
        echo "10) Container Logs anzeigen"
        echo ""
        echo "=== SYSTEM & HILFE ==="
        echo "11) System-Status anzeigen"
        echo "12) Konfiguration testen"
        echo "13) Hilfe anzeigen"
        echo "0) Beenden"
        echo ""
        
        read -p "Auswahl (0-13): " choice
        
        case $choice in
            1)
                nextcloud_setup
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            2)
                setup_gpg
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            3)
                check_gpg_installation
                import_gpg_keys
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            4)
                secure_secrets
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            5)
                setup_host_cron
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            6)
                start_nextcloud
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            7)
                stop_nextcloud
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            8)
                restart_nextcloud
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            9)
                show_container_status
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            10)
                show_logs
                # Keine "Enter"-Aufforderung nach Logs, da interaktiv
                ;;
            11)
                show_status
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            12)
                test_configuration
                read -p "Drücken Sie Enter um fortzufahren..."
                ;;
            13)
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
        setup)
            show_banner
            nextcloud_setup
            ;;
        setup-gpg)
            show_banner
            setup_gpg
            ;;
        import-keys)
            show_banner
            check_gpg_installation
            import_gpg_keys
            ;;
        secure-secrets)
            show_banner
            secure_secrets
            ;;
        setup-cron)
            show_banner
            setup_host_cron
            ;;
        status)
            show_banner
            show_status
            ;;
        start)
            show_banner
            start_nextcloud
            ;;
        stop)
            show_banner
            stop_nextcloud
            ;;
        restart)
            show_banner
            restart_nextcloud
            ;;
        ps|status-containers)
            show_banner
            show_container_status
            ;;
        logs)
            show_banner
            show_logs
            ;;
        test-config)
            show_banner
            test_configuration
            ;;
        interactive|"")
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
