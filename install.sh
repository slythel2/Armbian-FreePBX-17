#!/bin/bash

# ============================================================================
# PROJECT:   Armbian PBX Installer (Asterisk 22 + FreePBX 17)
# TARGET:    Armbian 12 Bookworm (ARM64 - s905x3)
# VERSION:   3.0 (Fresh Install & Webroot Hardening)
# ============================================================================

# --- 1. CONFIGURATION ---
REPO_OWNER="slythel2"
REPO_NAME="FreePBX-17-for-Armbian-12-Bookworm"
FALLBACK_ARTIFACT="https://github.com/slythel2/FreePBX-17-for-Armbian-12-Bookworm/releases/download/1.0/asterisk-22-current-arm64-debian12-v2.tar.gz"

DB_ROOT_PASS="armbianpbx"
LOG_FILE="/var/log/pbx_install.log"
DEBIAN_FRONTEND=noninteractive

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARNING] $1${NC}" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"; exit 1; }

if [[ $EUID -ne 0 ]]; then echo "Run as root!"; exit 1; fi

# --- UPDATER - Surgical Update Mode ---
if [[ "$1" == "--update" ]]; then
    log "Starting Asterisk 22 Surgical Update..."
    
    systemctl stop asterisk
    pkill -9 asterisk 2>/dev/null
    
    if ! command -v jq &> /dev/null; then apt-get update && apt-get install -y jq; fi
    LATEST_URL=$(curl -s "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest" | jq -r '.assets[] | select(.name | contains("asterisk")) | .browser_download_url' | head -n 1)
    [ -z "$LATEST_URL" ] && ASTERISK_ARTIFACT_URL="$FALLBACK_ARTIFACT" || ASTERISK_ARTIFACT_URL="$LATEST_URL"
    
    STAGE_DIR="/tmp/asterisk_update_stage"
    rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"
    wget -q -O /tmp/asterisk_update.tar.gz "$ASTERISK_ARTIFACT_URL"
    tar -xzf /tmp/asterisk_update.tar.gz -C "$STAGE_DIR"

    log "Deploying updated binaries and modules (Surgical)..."
    [ -d "$STAGE_DIR/usr/sbin" ] && cp -f "$STAGE_DIR/usr/sbin/asterisk" /usr/sbin/
    [ -d "$STAGE_DIR/usr/lib/asterisk/modules" ] && cp -rf "$STAGE_DIR/usr/lib/asterisk/modules"/* /usr/lib/asterisk/modules/
    
    rm -rf "$STAGE_DIR" /tmp/asterisk_update.tar.gz
    ldconfig
    systemctl start asterisk
    
    log "Update completed. Running FreePBX reload..."
    if command -v fwconsole &> /dev/null; then
        fwconsole reload
    fi
    exit 0
fi

# --- 2. MAIN INSTALLER (FRESH) ---
clear
echo "========================================================"
echo "   ARMBIAN PBX INSTALLER v3.0 (Asterisk 22 LTS)         "
echo "========================================================"

log "System upgrade and core dependencies..."
apt-get update && apt-get upgrade -y
apt-get install -y \
    git curl wget vim htop subversion sox pkg-config sngrep \
    apache2 mariadb-server mariadb-client odbc-mariadb \
    libxml2 libsqlite3-0 libjansson4 libedit2 libxslt1.1 \
    libopus0 libvorbis0a libspeex1 libspeexdsp1 libgsm1 \
    unixodbc unixodbc-dev odbcinst libltdl7 libicu-dev \
    liburiparser1 libjwt-dev liblua5.4-0 libtinfo6 \
    libsrtp2-1 libportaudio2 nodejs npm acl haveged jq \
    php php-cli php-common php-curl php-gd php-mbstring \
    php-mysql php-soap php-xml php-intl php-zip php-bcmath \
    php-ldap php-pear libapache2-mod-php

# PHP Optimization
for INI in /etc/php/8.2/apache2/php.ini /etc/php/8.2/cli/php.ini; do
    if [ -f "$INI" ]; then
        sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$INI"
        sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 120M/' "$INI"
        sed -i 's/^post_max_size = .*/post_max_size = 120M/' "$INI"
        sed -i 's/^;date.timezone =.*/date.timezone = UTC/' "$INI"
    fi
done

# --- 3. ASTERISK USER & ARTIFACT ---
log "Configuring Asterisk user..."
getent group asterisk >/dev/null || groupadd asterisk
if ! getent passwd asterisk >/dev/null; then
    useradd -r -d /var/lib/asterisk -s /bin/bash -g asterisk asterisk
    usermod -aG audio,dialout,www-data asterisk
fi

log "Downloading Asterisk artifact..."
wget -q -O /tmp/asterisk.tar.gz "$FALLBACK_ARTIFACT"
tar -xzf /tmp/asterisk.tar.gz -C /
rm /tmp/asterisk.tar.gz

# Ensure all directories exist
mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk /usr/lib/asterisk/modules
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk
ldconfig

# Create a clean asterisk.conf (CRITICAL)
cat > /etc/asterisk/asterisk.conf <<'EOF'
[directories]
astetcdir => /etc/asterisk
astmoddir => /usr/lib/asterisk/modules
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /var/run/asterisk
astlogdir => /var/log/asterisk
[options]
runuser = asterisk
rungroup = asterisk
EOF
chown asterisk:asterisk /etc/asterisk/asterisk.conf

# Systemd Service Fix
cat > /etc/systemd/system/asterisk.service <<'EOF'
[Unit]
Description=Asterisk PBX
After=network.target mariadb.service
[Service]
Type=simple
User=asterisk
Group=asterisk
ExecStart=/usr/sbin/asterisk -f -C /etc/asterisk/asterisk.conf
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable asterisk mariadb apache2

# --- 4. DATABASE SETUP ---
log "Initializing MariaDB..."
systemctl start mariadb
mysqladmin -u root password "$DB_ROOT_PASS" 2>/dev/null || true

mysql -u root -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS asterisk; CREATE DATABASE IF NOT EXISTS asteriskcdrdb;"
mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';"
mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'localhost';"
mysql -u root -p"$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;"

# --- 5. APACHE CONFIGURATION ---
log "Hardening Apache configuration..."
# Update DocumentRoot block to allow .htaccess
cat > /etc/apache2/sites-available/freepbx.conf <<EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
a2enmod rewrite
a2ensite freepbx.conf
a2dissite 000-default.conf
systemctl restart apache2

# --- 6. START ASTERISK BEFORE FREEPBX ---
log "Starting Asterisk and waiting for readiness..."
systemctl restart asterisk
sleep 5

# Validation loop
ASTERISK_READY=0
for i in {1..10}; do
    if asterisk -rx "core show version" &>/dev/null; then
        ASTERISK_READY=1
        log "Asterisk is responding to CLI."
        break
    fi
    warn "Waiting for Asterisk... ($i/10)"
    sleep 3
done

if [ $ASTERISK_READY -eq 0 ]; then
    error "Asterisk failed to respond. Check /var/log/asterisk/messages"
fi

# --- 7. FREEPBX INSTALLATION ---
log "Installing FreePBX 17..."
cd /usr/src
wget -q http://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz
tar xfz freepbx-17.0-latest.tgz
cd freepbx
./install -n --dbuser asterisk --dbpass "$DB_ROOT_PASS" --webroot /var/www/html --user asterisk --group asterisk

# --- 8. FINAL FIXES ---
log "Finalizing permissions and CDR setup..."
REAL_SOCKET=$(find /run /var/run -name mysqld.sock 2>/dev/null | head -n 1)
[ -n "$REAL_SOCKET" ] && ln -sf "$REAL_SOCKET" /tmp/mysql.sock

# ODBC Fix (Needs variables expansion)
ODBC_DRIVER=$(find /usr/lib -name "libmaodbc.so" | head -n 1)
if [ -n "$ODBC_DRIVER" ]; then
cat > /etc/odbcinst.ini <<EOF
[MariaDB]
Description=ODBC for MariaDB
Driver=$ODBC_DRIVER
Setup=$ODBC_DRIVER
UsageCount=1
EOF

cat > /etc/odbc.ini <<EOF
[MySQL-asteriskcdrdb]
Description=MySQL connection to 'asteriskcdrdb' database
Driver=MariaDB
Server=localhost
Database=asteriskcdrdb
Port=3306
Socket=$REAL_SOCKET
Option=3
EOF
fi

if command -v fwconsole &> /dev/null; then
    fwconsole chown
    fwconsole ma remove firewall 2>/dev/null
    fwconsole reload
fi

# Persistence Service
cat > /usr/local/bin/fix_free_perm.sh <<'EOF'
#!/bin/bash
DYN_SOCKET=$(find /run /var/run -name mysqld.sock 2>/dev/null | head -n 1)
[ -n "$DYN_SOCKET" ] && ln -sf "$DYN_SOCKET" /tmp/mysql.sock
mkdir -p /var/run/asterisk /var/log/asterisk
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /etc/asterisk
if [ -x /usr/sbin/fwconsole ]; then
    /usr/sbin/fwconsole chown &>/dev/null
fi
exit 0
EOF
chmod +x /usr/local/bin/fix_free_perm.sh

cat > /etc/systemd/system/free-perm-fix.service <<'EOF'
[Unit]
Description=FreePBX Permission Fix
After=asterisk.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix_free_perm.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl enable free-perm-fix.service

# MOTD Banner
cat > /etc/update-motd.d/99-pbx-status <<'EOF'
#!/bin/bash
BLUE='\033[0;34m'
NC='\033[0m'
IP_ADDR=$(hostname -I | cut -d' ' -f1)
echo -e "${BLUE}================================================================${NC}"
echo -e "   ARMBIAN PBX - Web GUI: http://$IP_ADDR/admin"
echo -e "${BLUE}================================================================${NC}"
EOF
chmod +x /etc/update-motd.d/99-pbx-status

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}            FREEPBX INSTALLATION COMPLETE!              ${NC}"
echo -e "${GREEN}   Access: http://$(hostname -I | cut -d' ' -f1)/admin  ${NC}"
echo -e "${GREEN}========================================================${NC}"
