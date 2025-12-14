#!/bin/bash

# ============================================================================
# PROJECT:  Armbian PBX "One-Click" Installer (T95 Max+ / ARM64)
# TARGET:   Debian 12 (Bookworm)
# STACK:    Asterisk 21 (Pre-compiled) + FreePBX 17 + PHP 8.2
# AUTHOR:   Gemini & slythel2
# DATE:     2025-12-14
# ============================================================================

# --- 1. USER CONFIGURATION ---
ASTERISK_ARTIFACT_URL="https://github.com/slythel2/FreePBX-17-for-Armbian-12-Bookworm/releases/download/1.0/asterisk-21.12.0-arm64-debian12.tar.gz"

# Database root password (auto-set)
DB_ROOT_PASS="armbianpbx"

# --- END CONFIGURATION ---

LOG_FILE="/var/log/pbx_install.log"
DEBIAN_FRONTEND=noninteractive

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"; exit 1; }

# Root check
if [[ $EUID -ne 0 ]]; then echo "Run as root!"; exit 1; fi

# URL validation
if [[ "$ASTERISK_ARTIFACT_URL" == *"INSERISCI_QUI"* ]]; then
    echo -e "${RED}ERROR: Please update the artifact URL in line 14!${NC}"
    exit 1
fi

clear
echo "========================================================"
echo "   ARM64 PBX AUTO-INSTALLER (DEBIAN 12)                 "
echo "========================================================"
sleep 3

# --- 2. SYSTEM PREP ---
log "Updating system and installing dependencies..."
apt-get update && apt-get upgrade -y

# Essential dependencies + Subversion + Runtime libs
apt-get install -y \
    git curl wget vim htop subversion sox \
    apache2 mariadb-server mariadb-client \
    libxml2 libsqlite3-0 libjansson4 libedit2 libxslt1.1 \
    libopus0 libvorbis0a libspeex1 libspeexdsp1 libgsm1 \
    unixodbc odbcinst libltdl7 \
    nodejs npm \
    || error "Failed to install base packages"

# --- 3. PHP 8.2 STACK & TUNING ---
log "Installing PHP 8.2 and modules..."
apt-get install -y \
    php php-cli php-common php-curl php-gd php-mbstring \
    php-mysql php-soap php-xml php-intl php-zip php-bcmath \
    php-ldap php-pear libapache2-mod-php \
    || error "Failed to install PHP"

log "Tuning PHP parameters (RAM & Upload)..."
# Apache php.ini
sed -i 's/memory_limit = .*/memory_limit = 256M/' /etc/php/8.2/apache2/php.ini
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 120M/' /etc/php/8.2/apache2/php.ini
sed -i 's/post_max_size = .*/post_max_size = 120M/' /etc/php/8.2/apache2/php.ini
sed -i 's/^max_execution_time = .*/max_execution_time = 360/' /etc/php/8.2/apache2/php.ini

# CLI php.ini (Critical for FreePBX installer)
sed -i 's/memory_limit = .*/memory_limit = 256M/' /etc/php/8.2/cli/php.ini

# --- 4. ASTERISK USER SETUP ---
log "Creating system user..."
if ! getent group asterisk >/dev/null; then groupadd asterisk; fi
if ! getent passwd asterisk >/dev/null; then
    useradd -r -d /var/lib/asterisk -g asterisk asterisk
    usermod -aG audio,dialout asterisk
fi

# --- 5. ASTERISK INSTALL (FROM ARTIFACT) ---
log "Downloading and installing pre-compiled Asterisk..."
cd /tmp
wget -O asterisk_artifact.tar.gz "$ASTERISK_ARTIFACT_URL" || error "Artifact download failed"

log "Extracting files..."
# Extract directly to root /
tar -xzvf asterisk_artifact.tar.gz -C / || error "Extraction failed"
rm asterisk_artifact.tar.gz

# Update cache and permissions
ldconfig
chown -R asterisk:asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /etc/asterisk /usr/lib/asterisk

# --- 6. SYSTEMD SERVICE SETUP ---
log "Configuring Asterisk service..."
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

# --- 7. APACHE & DATABASE SETUP ---
log "Configuring Apache..."
sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf
a2enmod rewrite
systemctl restart apache2

log "Configuring Database..."
# Set root password if not set
mysqladmin -u root password "$DB_ROOT_PASS" 2>/dev/null || true

# --- 8. FREEPBX 17 INSTALL ---
log "Downloading and Installing FreePBX 17..."
cd /usr/src
# Remove old downloads
rm -rf freepbx*

wget http://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz
tar xfz freepbx-17.0-latest.tgz
cd freepbx

log "Starting FreePBX Installer..."
# Non-interactive install
./install -n --db-root-pass "$DB_ROOT_PASS" --webroot /var/www/html --asterisk-user asterisk || error "FreePBX install failed"

# --- 9. CLEANUP & START ---
log "Finalizing..."
fwconsole ma installall
fwconsole chown
fwconsole reload

# Start Asterisk
systemctl start asterisk

echo ""
echo "========================================================"
echo "   INSTALLATION COMPLETE! (PHP RAM: 256M OK)            "
echo "========================================================"
echo "Web Access: http://$(hostname -I | cut -d' ' -f1)/admin"
echo "DB Root Credentials: $DB_ROOT_PASS"
echo "========================================================"
