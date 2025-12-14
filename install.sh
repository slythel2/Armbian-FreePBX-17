#!/bin/bash

# ============================================================================
# PROJECT:  Armbian PBX "One-Click" Installer (T95 Max+ / ARM64)
# TARGET:   Debian 12 (Bookworm)
# STACK:    Asterisk 21 (Pre-compiled) + FreePBX 17 + PHP 8.2
# AUTHOR:   Gemini & User
# DATE:     2025-12-14
# ============================================================================

# --- 1. CONFIGURAZIONE UTENTE ---
ASTERISK_ARTIFACT_URL="https://github.com/slythel2/Armbian-FreePBX-17/releases/download/1.0/asterisk-21.12.0-arm64-debian12.tar.gz"

# Password per il database (verrà impostata automaticamente)
DB_ROOT_PASS="armbianpbx"

# --- FINE CONFIGURAZIONE ---

LOG_FILE="/var/log/pbx_install.log"
DEBIAN_FRONTEND=noninteractive

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"; exit 1; }

# Controllo Root
if [[ $EUID -ne 0 ]]; then echo "Esegui come root!"; exit 1; fi

# Controllo URL inserito
if [[ "$ASTERISK_ARTIFACT_URL" == *"INSERISCI_QUI"* ]]; then
    echo -e "${RED}ERRORE: Devi modificare lo script inserendo l'URL del file tar.gz alla riga 14!${NC}"
    exit 1
fi

clear
echo "========================================================"
echo "   INSTALLATORE AUTOMATICO PBX ARM64 (DEBIAN 12)        "
echo "========================================================"
sleep 3

# --- 2. PREPARAZIONE SISTEMA ---
log "Aggiornamento sistema e installazione dipendenze..."
apt-get update && apt-get upgrade -y

# Dipendenze essenziali + Subversion + Librerie runtime Asterisk
apt-get install -y \
    git curl wget vim htop subversion sox \
    apache2 mariadb-server mariadb-client \
    libxml2 libsqlite3-0 libjansson4 libedit2 libxslt1.1 \
    libopus0 libvorbis0a libspeex1 libspeexdsp1 libgsm1 \
    unixodbc odbcinst libltdl7 \
    nodejs npm \
    || error "Fallita installazione pacchetti base"

# --- 3. STACK PHP 8.2 & TUNING MEMORIA ---
log "Installazione PHP 8.2 e moduli..."
apt-get install -y \
    php php-cli php-common php-curl php-gd php-mbstring \
    php-mysql php-soap php-xml php-intl php-zip php-bcmath \
    php-ldap php-pear libapache2-mod-php \
    || error "Fallita installazione PHP"

log "Ottimizzazione parametri PHP (RAM & Upload)..."
# Modifica php.ini per Apache
sed -i 's/memory_limit = .*/memory_limit = 256M/' /etc/php/8.2/apache2/php.ini
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 120M/' /etc/php/8.2/apache2/php.ini
sed -i 's/post_max_size = .*/post_max_size = 120M/' /etc/php/8.2/apache2/php.ini
sed -i 's/^max_execution_time = .*/max_execution_time = 360/' /etc/php/8.2/apache2/php.ini

# Modifica php.ini per CLI (Critico per l'installazione FreePBX)
sed -i 's/memory_limit = .*/memory_limit = 256M/' /etc/php/8.2/cli/php.ini

# --- 4. SETUP UTENTE ASTERISK ---
log "Creazione utente di sistema..."
if ! getent group asterisk >/dev/null; then groupadd asterisk; fi
if ! getent passwd asterisk >/dev/null; then
    useradd -r -d /var/lib/asterisk -g asterisk asterisk
    usermod -aG audio,dialout asterisk
fi

# --- 5. INSTALLAZIONE ASTERISK (DA ARTIFACT) ---
log "Scaricamento e installazione Asterisk Pre-compilato..."
cd /tmp
wget -O asterisk_artifact.tar.gz "$ASTERISK_ARTIFACT_URL" || error "Download Artifact fallito"

log "Estrazione file nel sistema..."
# Estraiamo direttamente nella root /
tar -xzvf asterisk_artifact.tar.gz -C / || error "Estrazione fallita"
rm asterisk_artifact.tar.gz

# Aggiorniamo cache librerie e permessi iniziali
ldconfig
chown -R asterisk:asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /etc/asterisk /usr/lib/asterisk

# --- 6. SETUP SERVIZIO SYSTEMD ---
log "Configurazione servizio Asterisk..."
cat <<EOF > /etc/systemd/system/asterisk.service
[Unit]
Description=Asterisk PBX
Documentation=man:asterisk(8)
Wants=network.target
After=network.target network-online.target

[Service]
Type=simple
User=asterisk
Group=asterisk
ExecStart=/usr/sbin/asterisk -f -C /etc/asterisk/asterisk.conf
ExecStop=/usr/sbin/asterisk -rx 'core stop now'
ExecReload=/usr/sbin/asterisk -rx 'core reload'
Restart=on-failure
RestartSec=5
LimitCORE=infinity
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable asterisk

# --- 7. CONFIGURAZIONE APACHE E DATABASE ---
log "Configurazione Apache..."
sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf
a2enmod rewrite
systemctl restart apache2

log "Configurazione Database..."
# Imposta password root se non impostata
mysqladmin -u root password "$DB_ROOT_PASS" 2>/dev/null || true

# --- 8. INSTALLAZIONE FREEPBX 17 ---
log "Scaricamento e Installazione FreePBX 17..."
cd /usr/src
# Rimuoviamo eventuali vecchi download
rm -rf freepbx*

wget http://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz
tar xfz freepbx-17.0-latest.tgz
cd freepbx

log "Avvio Installer FreePBX..."
# Installazione non interattiva
./install -n --db-root-pass "$DB_ROOT_PASS" --webroot /var/www/html --asterisk-user asterisk || error "Installazione FreePBX fallita"

# --- 9. PULIZIA E AVVIO FINALE ---
log "Finalizzazione..."
fwconsole ma installall
fwconsole chown
fwconsole reload

# Avvio Asterisk
systemctl start asterisk

echo ""
echo "========================================================"
echo "   INSTALLAZIONE COMPLETATA! (PHP RAM: 256M OK)         "
echo "========================================================"
echo "IP Accesso: http://$(hostname -I | cut -d' ' -f1)/admin"
echo "Credenziali Database Root: $DB_ROOT_PASS"
echo "========================================================"
