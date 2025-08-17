# Nextcloud mit Caddy Docker Compose Setup

Diese Konfiguration erstellt eine vollständige Nextcloud-Umgebung mit Caddy als Reverse Proxy und automatischen Let's Encrypt Zertifikaten.

## Features

- ✅ **Caddy Reverse Proxy** mit automatischen Let's Encrypt Zertifikaten
- ✅ **PHP-FPM basierte Nextcloud Installation** für bessere Performance
- ✅ **Redis Cache** für schnellere Antwortzeiten
- ✅ **Nextcloud Notify Push Service** für Real-time Synchronisation
- ✅ **PostgreSQL Datenbank** (Docker oder extern auf Host-System)
- ✅ **Imaginary Service** für Vorschaubilder
- ✅ **Automatische Backups** von Datenbank und Dateien
- ✅ **Cron Jobs** für Nextcloud Wartung
- ✅ **Docker Secrets** für sichere Passwort-Verwaltung
- ✅ **Konfigurierbare externe Datenbank** auf Host-System

## Schnellstart

### 1. Management-Script ausführen

Das konsolidierte Management-Script führt Sie durch die komplette Konfiguration:

```bash
./nextcloud-manager.sh setup
```

Das Script:
- Sammelt alle notwendigen Konfigurationsdaten
- Generiert sichere Passwörter
- Erstellt die `.env` Datei
- Richtet Docker Networks ein
- Bietet optional GPG-Setup an
- Startet optional direkt die Container

### 2. Interaktive Verwaltung

Für die tägliche Verwaltung verwenden Sie die interaktiven Menüs:

```bash
# Hauptverwaltung (Setup, GPG, Secrets, Status)
./nextcloud-manager.sh

# Backup-Verwaltung (Erstellen, Entschlüsseln, Auflisten)
./nextcloud-backup.sh

# Wiederherstellung (Interaktive Backup-Auswahl)
./nextcloud-restore.sh
```

### 3. Manuelle Konfiguration (Alternative)

Falls Sie die Konfiguration manuell vornehmen möchten:

```bash
# 1. Umgebungsvariablen konfigurieren
cp nextcloud-caddy.env .env
# Bearbeiten Sie .env mit Ihren Werten

# 2. Secrets erstellen
./nextcloud-manager.sh secure-secrets

# 3. Docker Networks erstellen
docker network create caddy-network
docker network create nextcloud-network

# 4. Container starten
# Mit Docker PostgreSQL:
docker-compose -f nextcloud-caddy-docker-compose.yml --profile docker-db up -d

# Oder ohne PostgreSQL (externe DB):
docker-compose -f nextcloud-caddy-docker-compose.yml up -d
```

## Datenbankoptionen

### Option 1: Docker PostgreSQL (Empfohlen)
- Setzen Sie `DATABASE_TYPE=docker` in der `.env`
- Starten Sie mit `--profile docker-db`
- Die PostgreSQL-Datenbank läuft in einem eigenen Container

### Option 2: Externe Datenbank auf Host-System
- Setzen Sie `DATABASE_TYPE=external` in der `.env`
- Konfigurieren Sie `DB_HOST` mit der IP/Hostname Ihres Datenbank-Servers
- Starten Sie ohne `--profile docker-db`
- Stellen Sie sicher, dass die externe Datenbank erreichbar ist

## Wichtige Konfigurationsdateien

| Datei | Zweck |
|-------|-------|
| `nextcloud-caddy-docker-compose.yml` | Hauptkonfiguration für alle Services |
| `.env` | Umgebungsvariablen (aus `nextcloud-caddy.env` kopiert) |
| `Caddyfile.proxy` | Caddy Reverse Proxy Konfiguration |
| `Caddyfile.nextcloud` | Caddy Webserver für Nextcloud FPM |
| `nextcloud.env` | Nextcloud-spezifische Einstellungen |
| `nextcloud-cron-host.sh` | Host-System Cron-Script (Standard) |
| `cron.sh` | Docker-Container Cron-Script (optional) |
| `secrets/` | Verzeichnis für Passwörter (Docker Secrets) |

## Services Übersicht

| Service | Zweck | Port | Abhängigkeiten |
|---------|-------|------|----------------|
| `postgres` | PostgreSQL Datenbank | 5432 | - |
| `redis` | Cache und Session Storage | 6379 | - |
| `app` | Nextcloud FPM Application | 9000 | postgres, redis |
| `web` | Caddy Webserver für FPM | 80 | app |
| `proxy` | Caddy Reverse Proxy | 80, 443 | web |
| `cron` | Nextcloud Cron Jobs | - | app |
| `notify_push` | Real-time Push Service | 7867 | app, redis |
| `imaginary` | Vorschaubild-Generator | 9000 | - |
| `backups` | Automatische Backups | - | postgres |

## Netzwerk-Architektur

```
Internet
    ↓
proxy:443 (Caddy Reverse Proxy)
    ↓
web:80 (Caddy Webserver)
    ↓
app:9000 (Nextcloud FPM)
    ↓
postgres:5432 & redis:6379
```

## Post-Installation Setup

### 1. Nextcloud konfigurieren

Nach dem ersten Start:

1. Öffnen Sie `https://ihre-domain.com`
2. Loggen Sie sich mit den generierten Credentials ein
3. Konfigurieren Sie Nextcloud nach Ihren Wünschen

### 2. Notify Push aktivieren

```bash
# In den Nextcloud Container wechseln
docker-compose -f nextcloud-caddy-docker-compose.yml exec app bash

# Notify Push konfigurieren
php occ notify_push:setup https://ihre-domain.com/push

# Test der Konfiguration
php occ notify_push:self-test
```

### 3. Imaginary für Vorschaubilder aktivieren

```bash
# Imaginary in Nextcloud konfigurieren
docker-compose -f nextcloud-caddy-docker-compose.yml exec app bash
php occ config:system:set preview_imaginary_url --value="http://imaginary:9000"
```

## Wartung und Verwaltung

### Container verwalten

```bash
# Status anzeigen
docker-compose -f nextcloud-caddy-docker-compose.yml ps

# Logs anzeigen
docker-compose -f nextcloud-caddy-docker-compose.yml logs -f

# Container neustarten
docker-compose -f nextcloud-caddy-docker-compose.yml restart

# Container stoppen
docker-compose -f nextcloud-caddy-docker-compose.yml down
```

### Konsolidierte Management-Scripts

Das Nextcloud Caddy System verwendet **4 Haupt-Scripts** für alle Verwaltungsaufgaben:

#### 🎛️ **Hauptverwaltung**: `nextcloud-manager.sh`
```bash
# Interaktives Management-Menü
./nextcloud-manager.sh

# Spezifische Aktionen
./nextcloud-manager.sh setup           # Vollständiges Nextcloud-Setup
./nextcloud-manager.sh setup-gpg       # GPG-Verschlüsselung einrichten  
./nextcloud-manager.sh import-keys     # GPG-Schlüssel importieren
./nextcloud-manager.sh secure-secrets  # Secrets verwalten
./nextcloud-manager.sh status          # System-Status anzeigen
./nextcloud-manager.sh test-config     # Konfiguration testen
```

#### 💾 **Backup-Management**: `nextcloud-backup.sh`
```bash
# Interaktives Backup-Menü
./nextcloud-backup.sh

# Backup-Operationen
./nextcloud-backup.sh create full      # Vollständiges Backup
./nextcloud-backup.sh create database  # Nur Datenbank
./nextcloud-backup.sh create data      # Nur Nextcloud-Dateien
./nextcloud-backup.sh create config    # Nur Konfiguration

# Backup-Verwaltung
./nextcloud-backup.sh decrypt backup.sql.gz  # Backup entschlüsseln
./nextcloud-backup.sh list database          # Backups auflisten
./nextcloud-backup.sh cleanup                # Alte Backups bereinigen
./nextcloud-backup.sh status                 # Backup-Status
```

#### 🔄 **Wiederherstellung**: `nextcloud-restore.sh`
```bash
# Interaktive Wiederherstellung
./nextcloud-restore.sh

# Spezifische Wiederherstellung  
./nextcloud-restore.sh database    # Nur Datenbank
./nextcloud-restore.sh data        # Nur Nextcloud-Dateien
./nextcloud-restore.sh config      # Nur Konfiguration
./nextcloud-restore.sh full        # Vollständige Wiederherstellung

# Spezifisches Backup wiederherstellen
./nextcloud-restore.sh database 20241217_143022
```

#### 🚀 **System-Updates**: `nextcloud-update.sh`
```bash
# Zero-Downtime Updates
./nextcloud-update.sh all          # Vollständiges System-Update
./nextcloud-update.sh nextcloud    # Nur Nextcloud
./nextcloud-update.sh proxy        # Nur Caddy Proxy
./nextcloud-update.sh database     # Nur PostgreSQL

# Erzwungenes Update
./nextcloud-update.sh all true
```

### Nextcloud OCC Befehle

```bash
# In den App-Container wechseln
docker-compose -f nextcloud-caddy-docker-compose.yml exec app bash

# Wartungsmodus aktivieren/deaktivieren
php occ maintenance:mode --on
php occ maintenance:mode --off

# Dateien scannen
php occ files:scan --all

# System reparieren
php occ maintenance:repair

# Apps verwalten
php occ app:list
php occ app:enable app_name
php occ app:disable app_name
```

### Erweiterte Backup-Funktionen

Das `backup-nextcloud.sh` Script bietet umfassende Backup-Funktionen:

#### 📋 **Backup-Komponenten**
- **Datenbank**: PostgreSQL Dumps (Docker oder extern)
- **Nextcloud-Daten**: Vollständige Datei-Backups
- **Konfiguration**: Docker Compose, Nextcloud config.php, Secrets (verschlüsselt)
- **Docker Volumes**: Alle persistenten Volumes
- **Container-Logs**: Für Debugging und Audit

#### 🔄 **Automatische Features**
- **Wartungsmodus**: Automatisch während Daten-Backup
- **GPG-Verschlüsselung**: Sichere Verschlüsselung mit öffentlichen Schlüsseln
- **Selektive Verschlüsselung**: Konfigurierbar welche Backup-Typen verschlüsselt werden
- **Komprimierung**: Alle Backups als .tar.gz
- **Retention**: Automatische Bereinigung alter Backups
- **Verifikation**: Backup-Validierung nach Erstellung

#### 📊 **Backup-Struktur**
```
backups/
├── database/     # PostgreSQL Dumps
├── data/         # Nextcloud Dateien
├── config/       # Konfigurationsdateien
├── volumes/      # Docker Volumes
└── logs/         # Container Logs
```

#### 🚀 **GPG-Verschlüsselung & Remote-Backup**

**GPG-Setup:**
```bash
# 1. GPG-Schlüssel für Backups einrichten
./setup-gpg-backup.sh

# 2. Konfiguration in .env:
BACKUP_GPG_ENCRYPTION=true
BACKUP_GPG_RECIPIENTS="admin@example.com,backup@company.com"
BACKUP_GPG_ENCRYPT_TYPES="database,secrets"  # oder "all"
```

**Backup-Entschlüsselung:**
```bash
# Verschlüsselte Backups entschlüsseln
./decrypt-backup.sh backups/database/nextcloud-db-20241217_143022.sql.gz
```

**Remote-Integration:**
Alle Backups sind optimiert für:
- **Rsync**: Inkrementelle Synchronisation (auch verschlüsselt)
- **Restic**: Deduplizierte Repository-Backups
- **Remote Storage**: S3, SFTP, etc.

```bash
# Beispiel: Rsync zu Remote-Server (verschlüsselte Backups)
rsync -avz --delete ./backups/ user@backup-server:/nextcloud-backups/

# Beispiel: Restic Repository
restic -r /path/to/restic-repo backup ./backups/

# Entschlüsselung auf Remote-System
./decrypt-backup.sh /remote/backups/nextcloud-db-20241217_143022.sql.gz
```

## Troubleshooting

### Häufige Probleme

1. **Container starten nicht**
   ```bash
   # Logs überprüfen
   docker-compose -f nextcloud-caddy-docker-compose.yml logs
   
   # Networks überprüfen
   docker network ls
   ```

2. **Let's Encrypt Zertifikat-Probleme**
   ```bash
   # Caddy Logs überprüfen
   docker-compose -f nextcloud-caddy-docker-compose.yml logs proxy
   
   # DNS-Auflösung testen
   nslookup ihre-domain.com
   ```

3. **Datenbank-Verbindungsfehler**
   ```bash
   # Datenbank-Status überprüfen
   docker-compose -f nextcloud-caddy-docker-compose.yml exec postgres pg_isready -U nextcloud
   
   # Netzwerk-Konnektivität testen
   docker-compose -f nextcloud-caddy-docker-compose.yml exec app ping postgres
   ```

4. **Performance-Probleme**
   - Überprüfen Sie die PHP Memory Limits in `nextcloud.env`
   - Stellen Sie sicher, dass Redis läuft und konfiguriert ist
   - Aktivieren Sie OPcache (bereits in `nextcloud.env` konfiguriert)

### Debug-Modus

Für detaillierte Logs:

```bash
# In nextcloud.env ändern:
loglevel=0  # DEBUG Level

# Container neustarten
docker-compose -f nextcloud-caddy-docker-compose.yml restart app
```

## Sicherheitshinweise

1. **Passwörter**: Alle Passwörter werden in Docker Secrets gespeichert
2. **Firewall**: Stellen Sie sicher, dass nur Port 80 und 443 öffentlich zugänglich sind
3. **Updates**: Halten Sie alle Container-Images aktuell
4. **Backups**: Testen Sie regelmäßig Ihre Backup-Wiederherstellung
5. **SSL/TLS**: Caddy verwendet automatisch sichere TLS-Konfigurationen

## Erweiterte Konfiguration

### Subpath Installation

Für eine Installation unter einem Subpath (z.B. `https://domain.com/nextcloud`):

1. Setzen Sie `OVERWRITEWEBROOT=/nextcloud` in der `.env`
2. Passen Sie die Caddy-Konfiguration entsprechend an

### Externe Services

Sie können zusätzliche Services wie Collabora Office oder OnlyOffice hinzufügen, indem Sie weitere Container zur `docker-compose.yml` hinzufügen.

## Support

Bei Problemen:

1. Überprüfen Sie die offiziellen Nextcloud Docker Dokumentation
2. Konsultieren Sie die Caddy Dokumentation für Proxy-Konfigurationen
3. Überprüfen Sie die Container-Logs für detaillierte Fehlermeldungen

## Lizenz

Dieses Setup basiert auf der ursprünglichen Traefik-Konfiguration und wurde für Caddy angepasst. Alle verwendeten Docker Images unterliegen ihren jeweiligen Lizenzen.
