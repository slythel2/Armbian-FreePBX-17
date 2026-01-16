#!/bin/bash

# ============================================================================
# PROJECT:   Armbian PBX "One-Click" Installer (T95 Max+ / ARM64)
# TARGET:    Debian 12 (Bookworm)
# STACK:     Asterisk 21 + FreePBX 17 + PHP 8.2
# DATE:      2025-01-16 (v0.9.2)
# ============================================================================

# --- 1. USER CONFIGURATION ---
ASTERISK_ARTIFACT_URL="https://github.com/slythel2/FreePBX-17-for-Armbian-12-Bookworm/releases/download/1.0/asterisk-21.12.0-arm64-debian12-v2.tar.gz"

# Database root password
# SECURITY WARNING: This password is hardcoded for installation convenience.
# It is highly recommended to change it after installation!
DB_ROOT_PASS="armbianpbx"

# --- END CONFIGURATION ---

LOG_FILE="/var/log/pbx_install.log"
DEBIAN_FRONTEND=noninteractive
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARNING] $1${NC}" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"; exit 1; }

if [[ $EUID -ne 0 ]]; then echo "Run as root!"; exit 1; fi

clear
echo "========================================================"
echo "   ARM64 PBX AUTO-INSTALLER (DEBIAN 12) (v0.9.2)        "
echo "========================================================"
sleep 3

# --- 2. SYSTEM PREP ---
log "Updating system and installing dependencies..."
apt-get update && apt-get upgrade -y

# Dependencies updated: added acl, pkg-config, libicu-dev, libedit2
apt-get install -y \
    git curl wget vim htop subversion sox pkg-config sngrep \
    apache2 mariadb-server mariadb-client \
    libxml2 libsqlite3-0 libjansson4 libedit2 libxslt1.1 \
    libopus0 libvorbis0a libspeex1 libspeexdsp1 libgsm1 \
    unixodbc odbcinst libltdl7 libicu-dev \
    nodejs npm acl \
    || error "Failed to install base packages"

# CRITICAL FIX: Install PM2 explicitly (Required by FreePBX 17 process manager)
log "Installing PM2..."
npm install -g pm2@latest || error "Failed to install PM2"

# --- 3. PHP 8.2 STACK & TUNING ---
log "Installing PHP 8.2..."
apt-get install -y \
    php php-cli php-common php-curl php-gd php-mbstring \
    php-mysql php-soap php-xml php-intl php-zip php-bcmath \
    php-ldap php-pear libapache2-mod-php \
    || error "Failed to install PHP"

log "Tuning PHP parameters..."
sed -i 's/memory_limit = .*/memory_limit = 256M/' /etc/php/8.2/apache2/php.ini
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 120M/' /etc/php/8.2/apache2/php.ini
sed -i 's/post_max_size = .*/post_max_size = 120M/' /etc/php/8.2/apache2/php.ini
sed -i 's/memory_limit = .*/memory_limit = 256M/' /etc/php/8.2/cli/php.ini
# Fix timeout for Network Detect on slow networks
sed -i 's/max_execution_time = .*/max_execution_time = 600/' /etc/php/8.2/apache2/php.ini

# --- 4. ASTERISK USER SETUP ---
log "Creating system user..."
if ! getent group asterisk >/dev/null; then groupadd asterisk; fi
if ! getent passwd asterisk >/dev/null; then
    useradd -r -d /var/lib/asterisk -g asterisk asterisk
    usermod -aG audio,dialout asterisk
fi

# --- 5. ASTERISK INSTALL (FROM ARTIFACT) ---
log "Downloading Asterisk Artifact..."
cd /tmp
wget -O asterisk_artifact.tar.gz "$ASTERISK_ARTIFACT_URL" || error "Artifact download failed"

log "Extracting files..."
tar -xzvf asterisk_artifact.tar.gz -C / || error "Extraction failed"
rm asterisk_artifact.tar.gz

# --- CRITICAL FIX: LIBRARIES & PERMISSIONS ---
log "Linking libraries and fixing permissions..."
echo "/usr/lib" > /etc/ld.so.conf.d/asterisk.conf
ldconfig

mkdir -p /var/run/asterisk
chown -R asterisk:asterisk /var/run/asterisk
chown -R asterisk:asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /etc/asterisk /usr/lib/asterisk

# --- 6. SYSTEMD SERVICE & BOOT SETUP ---
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

log "Enabling services at boot..."
systemctl enable mariadb
systemctl enable apache2
systemctl enable asterisk
systemctl start asterisk

# --- 7. APACHE & DATABASE SETUP ---
log "Configuring Apache..."
sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf

if [ -f /etc/apache2/mods-enabled/dir.conf ]; then
    sed -i 's/DirectoryIndex index.html/DirectoryIndex index.php index.html/' /etc/apache2/mods-enabled/dir.conf
fi

a2enmod rewrite
systemctl restart apache2

log "Configuring Database..."
systemctl start mariadb
sleep 2

# --- FIX: MARIADB STRICT MODE (CRITICAL FOR DEBIAN 12) ---
# Disables Strict SQL Mode to prevent crashes when FreePBX writes partial data
if [ ! -f /etc/mysql/conf.d/freepbx.cnf ]; then
    log "Applying MariaDB 'Strict Mode' Fix..."
    cat <<EOF > /etc/mysql/conf.d/freepbx.cnf
[mysqld]
sql_mode = ""
innodb_strict_mode = 0
EOF
    systemctl restart mariadb
    sleep 2
fi
# --------------------------------------------------------------

mysqladmin -u root password "$DB_ROOT_PASS" 2>/dev/null || true

mysql -u root -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS asterisk;"
mysql -u root -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS asteriskcdrdb;"
mysql -u root -p"$DB_ROOT_PASS" -e "CREATE USER IF NOT EXISTS 'asterisk'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';"
mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'localhost';"
mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'localhost';"
mysql -u root -p"$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;"

# --- 8. FREEPBX 17 INSTALL ---
log "Downloading FreePBX 17..."
cd /usr/src
rm -rf freepbx*
wget http://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz
tar xfz freepbx-17.0-latest.tgz
cd freepbx

log "Running FreePBX Installer..."
./install -n \
    --dbuser asterisk \
    --dbpass "$DB_ROOT_PASS" \
    --webroot /var/www/html \
    --user asterisk \
    --group asterisk

# --- 9. PHP 8.2 CRITICAL COMPILATION FIXES ---
log "Applying critical PHP 8.2 compilation patches..."

# FIX 1: Less.php (array_merge fix)
LESS_FILE="/var/www/html/admin/libraries/less/Less.php"
if [ -f "$LESS_FILE" ]; then
    sed -i 's/array_merge(\$this->rules, \$this->GetRules(\$file_path))/array_merge(\$this->rules, (array)\$this->GetRules(\$file_path))/' "$LESS_FILE"
    sed -i 's/\$this->GetCachedVariable(\$import))/(array)\$this->GetCachedVariable(\$import))/' "$LESS_FILE"
    log "Patched Less.php."
fi

# FIX 2: Cache.php (int vs array fix)
CACHE_FILE="/var/www/html/admin/libraries/less/Cache.php"
if [ -f "$CACHE_FILE" ]; then
    sed -i "s/return \$value;/return (array)\$value;/" "$CACHE_FILE"
    log "Patched Cache.php."
fi

# --- 10. MODULE MITIGATION & FINAL SETUP ---
log "Finalizing configuration..."

fwconsole ma remove sysadmin || warn "Sysadmin not found/removed."
fwconsole ma remove firewall || warn "Firewall not found/removed."
fwconsole ma disable dashboard || warn "Dashboard disabled."
fwconsole ma disable sms || warn "SMS disabled."
fwconsole ma disable ucp || warn "UCP disabled."

# --- FIX: SAFE SIP DEFAULTS (ANTI-CRASH) ---
log "Enforcing Safe SIP Defaults (Prevents 'Detect Network' crashes)..."
mysql -u root -p"$DB_ROOT_PASS" -D asterisk -e "UPDATE sipsettings SET data = 'no' WHERE keyword = 'nat';"
mysql -u root -p"$DB_ROOT_PASS" -D asterisk -e "UPDATE sipsettings SET data = '0.0.0.0' WHERE keyword = 'bindaddr';"
mysql -u root -p"$DB_ROOT_PASS" -D asterisk -e "UPDATE sipsettings SET data = '' WHERE keyword = 'externip';"
mysql -u root -p"$DB_ROOT_PASS" -D asterisk -e "UPDATE sipsettings SET data = '' WHERE keyword = 'localnets';"
# ------------------------------------------------

fwconsole ma installall
fwconsole chown
rm -f /var/www/html/index.html
rm -rf /var/www/html/admin/assets/less/cache/*

# --- 11. REBOOT-PROOF FIX (Systemd Service) ---
log "Implementing systemd service for reboot-proof stability..."

cat > /usr/local/bin/fix_free_perm.sh << EOF
#!/bin/bash
# Script to correct permissions on boot
# Also recreates volatile directories on Armbian
mkdir -p /var/run/asterisk /var/log/asterisk
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk
fwconsole chown &>/dev/null
rm -rf /var/www/html/admin/assets/less/cache/*
exit 0
EOF

chmod +x /usr/local/bin/fix_free_perm.sh

cat > /etc/systemd/system/free-perm-fix.service << EOF
[Unit]
Description=FreePBX Critical Permission Fix on Boot
Requires=asterisk.service
After=network.target asterisk.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix_free_perm.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable free-perm-fix.service
systemctl start free-perm-fix.service

# --- 12. INSTALL SSH LOGIN BANNER (EMBEDDED) ---
log "Generating Status Banner..."

# Create the banner script directly (Self-contained, no wget dependency)
cat << 'EOF' > /etc/update-motd.d/99-pbx-status
#!/bin/bash
# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Info
UPTIME=$(uptime -p | cut -d " " -f 2-)
IP_ADDR=$(hostname -I | cut -d' ' -f1)
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}')
RAM_USAGE=$(free -m | awk 'NR==2 {printf "%.1f%%", $3*100/$2 }')

# Status
check_service() {
    systemctl is-active --quiet $1 && echo -e "${GREEN}ONLINE${NC}" || echo -e "${RED}OFFLINE${NC}"
}

ASTERISK_STATUS=$(check_service asterisk)
MARIADB_STATUS=$(check_service mariadb)
APACHE_STATUS=$(check_service apache2)

echo -e "${BLUE}"
echo "================================================================"
echo "   ARMBIAN PBX - ASTERISK 21 + FREEPBX 17 (ARM64)"
echo "================================================================"
echo -e "${NC}"
echo -e " System IP:    ${YELLOW}$IP_ADDR${NC}"
echo -e " Web GUI:      ${YELLOW}http://$IP_ADDR/admin${NC}"
echo -e " Uptime:       $UPTIME"
echo -e " Disk / RAM:   $DISK_USAGE / $RAM_USAGE"
echo -e ""
echo -e " Asterisk:     $ASTERISK_STATUS"
echo -e " MariaDB:      $MARIADB_STATUS"
echo -e " Apache Web:   $APACHE_STATUS"
echo -e "${BLUE}"
echo "================================================================"
echo -e "${NC}"
EOF

chmod +x /etc/update-motd.d/99-pbx-status
rm -f /etc/motd # Removes static motd to avoid duplication
log "Banner installed successfully."

# --- 13. FINAL RELOAD ---
log "Performing final successful reload..."
fwconsole reload

echo ""
echo "========================================================"
echo "   INSTALLATION COMPLETE! (v0.9.2)        "
echo "========================================================"
echo "Web Access: http://$(hostname -I | cut -d' ' -f1)/admin"
echo "--------------------------------------------------------"
echo "DB Root Password: $DB_ROOT_PASS"
echo "--------------------------------------------------------"
echo "NOTE: Configure NAT/IP Settings manually in the GUI."
echo "      Follow the on-screen wizard to create your Admin User."
echo "========================================================"
