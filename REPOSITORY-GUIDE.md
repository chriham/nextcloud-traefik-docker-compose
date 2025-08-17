# Repository Guide - Was gehört ins Git?

## ✅ **WIRD COMMITTET** (Template/Code)

### 📋 **Konfigurationsvorlagen:**
- `nextcloud-caddy.env` - Template für Umgebungsvariablen
- `nextcloud.env` - Nextcloud-App-Konfiguration
- `Caddyfile.*` - Webserver-Konfiguration

### 🐳 **Docker-Setup:**
- `nextcloud-caddy-docker compose.yml` - Container-Orchestrierung
- `nextcloud-traefik-docker compose.yml` - Legacy-Setup

### 🛠️ **Management-Scripts:**
- `nextcloud-manager.sh` - Haupt-Management
- `nextcloud-backup.sh` - Backup-System
- `nextcloud-restore.sh` - Wiederherstellung
- `nextcloud-update.sh` - Updates
- `nextcloud-cron-host.sh` - Host-Cron-Script

### 📚 **Dokumentation:**
- `README.md` - Haupt-Dokumentation
- `README-Caddy.md` - Caddy-Setup-Guide
- `LICENSE` - Lizenz

### 🔧 **Repository-Management:**
- `.gitignore` - Git-Ignore-Regeln
- `REPOSITORY-GUIDE.md` - Diese Datei

---

## ❌ **WIRD NICHT COMMITTET** (Lokale Daten)

### 🔐 **Sensitive Daten:**
- `.env` - **Persönliche Konfiguration mit Domains/Emails**
- `secrets/` - **Passwörter und Schlüssel**
- `*.key`, `*.pem`, `*.crt` - **Zertifikate**

### 💾 **Runtime-Daten:**
- `nextcloud-data/` - **Benutzer-Dateien**
- `backups/` - **Backup-Archive**
- `logs/` - **Log-Dateien**

### 🖥️ **System-spezifisch:**
- `.DS_Store` - macOS-Dateien
- `Thumbs.db` - Windows-Dateien
- `.vscode/`, `.idea/` - Editor-Konfiguration

---

## 🎯 **Warum diese Aufteilung?**

### **Templates vs. Persönliche Konfiguration:**
```bash
nextcloud-caddy.env  # ✅ Template mit Beispielwerten
.env                 # ❌ Deine echte Domain/Email
```

### **Code vs. Daten:**
```bash
nextcloud-manager.sh     # ✅ Code für alle
nextcloud-data/          # ❌ Deine persönlichen Dateien
```

### **Öffentlich vs. Privat:**
```bash
README-Caddy.md          # ✅ Anleitung für alle
secrets/passwords.txt    # ❌ Deine Passwörter
```

---

## 🚀 **Setup für neuen Benutzer:**

1. **Repository klonen:**
   ```bash
   git clone <repository-url>
   cd nextcloud-docker-setup
   ```

2. **Setup ausführen:**
   ```bash
   ./nextcloud-manager.sh setup
   # Erstellt automatisch .env, secrets/, etc.
   ```

3. **Lokale Dateien sind automatisch ignoriert:**
   ```bash
   git status
   # Zeigt nur Code-Änderungen, keine lokalen Daten
   ```

---

## 🔍 **Git-Status prüfen:**

### **Erwartete Ausgabe nach Setup:**
```bash
$ git status
On branch main
nothing to commit, working tree clean
```

### **Falls ungewollte Dateien angezeigt werden:**
```bash
# Prüfe .gitignore
cat .gitignore

# Entferne versehentlich committete Dateien
git rm --cached .env
git rm -r --cached secrets/
```

---

## 🛡️ **Sicherheits-Checkliste:**

- ✅ `.env` ist in `.gitignore`
- ✅ `secrets/` ist in `.gitignore` 
- ✅ `backups/` ist in `.gitignore`
- ✅ Keine echten Passwörter in Template-Dateien
- ✅ Nur Beispiel-Domains in Templates

---

## 📤 **Beitragen zum Repository:**

### **Erwünschte Beiträge:**
- 🐛 Bug-Fixes in Scripts
- ✨ Neue Features
- 📚 Dokumentations-Verbesserungen
- 🔧 Template-Optimierungen

### **Vor dem Commit prüfen:**
```bash
# Keine sensitiven Daten?
git diff --cached

# Nur Code-Änderungen?
git status

# Tests durchgeführt?
./nextcloud-manager.sh test-config
```

---

## 🔄 **Repository-Updates:**

### **Updates holen:**
```bash
git pull origin main
```

### **Lokale Konfiguration bleibt erhalten:**
- Deine `.env` wird nicht überschrieben
- Deine `secrets/` bleiben unverändert  
- Deine Backups bleiben erhalten

### **Nur Code wird aktualisiert:**
- Management-Scripts
- Docker-Compose-Dateien
- Dokumentation
