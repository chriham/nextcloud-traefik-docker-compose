# Nextcloud Docker Compose Setup

Dieses Repository enthält zwei verschiedene Nextcloud Docker Compose Setups:

- **Traefik-Version** (Original): `nextcloud-traefik-docker-compose.yml`
- **Caddy-Version** (Neu): `nextcloud-caddy-docker-compose.yml` - **Empfohlen!**

## 🚀 Caddy-Setup (Empfohlen)

Das neue Caddy-Setup bietet erweiterte Features und eine bessere Wartbarkeit. Siehe [README-Caddy.md](README-Caddy.md) für Details.

### Schnellstart Caddy:
```bash
./nextcloud-manager.sh setup
```

## 📊 System-Architektur

### 🌐 Hauptkommunikationsfluss (Request-Response)

```mermaid
graph LR
    CLIENT[👤 Client] -->|HTTPS :443| PROXY[📡 Caddy Proxy]
    PROXY -->|HTTP :80| WEB[🌍 Caddy Web]
    WEB -->|FastCGI :9000| APP[🚀 Nextcloud FPM]
    APP -->|SQL :5432| DB[🗄️ PostgreSQL]
    APP -->|Cache :6379| REDIS[⚡ Redis]
    
    LETSENCRYPT[🔒 Let's Encrypt] -.->|SSL Certs| PROXY
    
    classDef client fill:#f9f,stroke:#333,stroke-width:2px
    classDef proxy fill:#bbf,stroke:#333,stroke-width:2px
    classDef app fill:#bfb,stroke:#333,stroke-width:2px
    classDef data fill:#fbb,stroke:#333,stroke-width:2px
    
    class CLIENT client
    class PROXY,WEB proxy
    class APP app
    class DB,REDIS data
```

### 🐳 Container-Services & Netzwerke

```mermaid
graph TB
    subgraph "🌐 caddy-network (öffentlich)"
        PROXY[📡 proxy<br/>:80, :443]
        WEB[🌍 web<br/>:80 internal]
        NOTIFY[📱 notify_push<br/>:7867]
    end
    
    subgraph "🔒 nextcloud-network (intern)"
        APP[🚀 app<br/>:9000]
        POSTGRES[🗄️ postgres<br/>:5432]
        REDIS[⚡ redis<br/>:6379]
        CRON[⏰ cron]
        IMAGINARY[🖼️ imaginary<br/>:9000]
        BACKUPS[💾 backups]
    end
    
    PROXY --> WEB
    WEB --> APP
    NOTIFY --> APP
    APP --> POSTGRES
    APP --> REDIS
    APP --> IMAGINARY
    CRON --> APP
    BACKUPS --> POSTGRES
    
    classDef public fill:#e3f2fd,stroke:#1976d2,stroke-width:2px
    classDef private fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    
    class PROXY,WEB,NOTIFY public
    class APP,POSTGRES,REDIS,CRON,IMAGINARY,BACKUPS private
```

### 💾 Datenpersistierung & Volumes

```mermaid
graph TB
    subgraph "🖥️ Host System"
        HOSTDATA[📁 nextcloud-data/<br/>User Files]
        SECRETS[🔐 secrets/<br/>Passwords]
        BACKUPDIR[💿 backups/<br/>Archives]
        CONFIGS[⚙️ Config Files<br/>.env, Caddyfiles]
    end
    
    subgraph "🐳 Docker Volumes"
        VOLAPP[nextcloud-data]
        VOLCADDY[caddy-data]
        VOLDB[postgres-data]
        VOLREDIS[redis-data]
    end
    
    subgraph "📦 Container"
        APP[🚀 Nextcloud]
        PROXY[📡 Caddy]
        DB[🗄️ PostgreSQL]
        REDIS[⚡ Redis]
    end
    
    HOSTDATA --> APP
    SECRETS --> APP
    CONFIGS --> APP
    CONFIGS --> PROXY
    
    VOLAPP --> APP
    VOLCADDY --> PROXY
    VOLDB --> DB
    VOLREDIS --> REDIS
    
    classDef host fill:#e8f5e8,stroke:#2e7d32,stroke-width:2px
    classDef volume fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    classDef container fill:#e1f5fe,stroke:#0277bd,stroke-width:2px
    
    class HOSTDATA,SECRETS,BACKUPDIR,CONFIGS host
    class VOLAPP,VOLCADDY,VOLDB,VOLREDIS volume
    class APP,PROXY,DB,REDIS container
```

### 🛠️ Management & Scripts

```mermaid
graph LR
    subgraph "🎛️ Management Scripts"
        MANAGER[nextcloud-manager.sh<br/>Setup • GPG • Status]
        BACKUP[nextcloud-backup.sh<br/>Create • Encrypt • List]
        RESTORE[nextcloud-restore.sh<br/>Interactive Restore]
        UPDATE[nextcloud-update.sh<br/>Zero-Downtime Updates]
    end
    
    subgraph "💾 Storage"
        CONFIGS[Config Files]
        SECRETS[Secrets]
        BACKUPS[Backup Archives]
    end
    
    subgraph "🐳 Services"
        CONTAINERS[Docker Containers]
    end
    
    MANAGER --> CONFIGS
    MANAGER --> SECRETS
    BACKUP --> BACKUPS
    RESTORE --> BACKUPS
    UPDATE --> CONTAINERS
    
    classDef script fill:#fff3e0,stroke:#e65100,stroke-width:2px
    classDef storage fill:#e8f5e8,stroke:#1b5e20,stroke-width:2px
    classDef service fill:#e1f5fe,stroke:#01579b,stroke-width:2px
    
    class MANAGER,BACKUP,RESTORE,UPDATE script
    class CONFIGS,SECRETS,BACKUPS storage
    class CONTAINERS service
```

## 📋 Komponenten-Übersicht

### 🐳 Container Services:
- **proxy**: Caddy Reverse Proxy (HTTPS, Let's Encrypt)
- **web**: Caddy Webserver (FastCGI zu PHP-FPM)
- **app**: Nextcloud FPM Application
- **postgres**: PostgreSQL Datenbank
- **redis**: Cache und Session Storage
- **cron**: Nextcloud Background Jobs
- **notify_push**: Real-time Push Service
- **imaginary**: Preview Generator
- **backups**: Automated Backup Service

### 🛠️ Management Scripts:
- **nextcloud-manager.sh**: Setup, GPG, Secrets, Status
- **nextcloud-backup.sh**: Backup-Management mit GPG-Verschlüsselung
- **nextcloud-restore.sh**: Interaktive Wiederherstellung
- **nextcloud-update.sh**: Zero-Downtime Updates

### 🔐 Sicherheitsfeatures:
- Docker Secrets für Passwörter
- GPG-Verschlüsselung für Backups
- Network Segmentierung
- Automatische SSL-Zertifikate

## 🔧 Legacy Traefik-Setup

Das ursprüngliche Traefik-Setup ist weiterhin verfügbar:

```bash
docker-compose -f nextcloud-traefik-docker-compose.yml up -d
```

**Hinweis**: Das Caddy-Setup wird für neue Installationen empfohlen, da es erweiterte Features und bessere Wartbarkeit bietet.
