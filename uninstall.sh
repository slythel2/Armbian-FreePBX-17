#!/bin/bash

# FIX CRLF: Auto-correction for Windows line endings
# If CR (\r) characters are detected, clean the file and restart.
if grep -q $'\r' "$0"; then
    sed -i 's/\r$//' "$0"
    exec "$0" "$@"
fi

# ============================================================================
# SCRIPT: uninstall.sh (v0.6)
# PURPOSE: COMPLETELY remove Asterisk, FreePBX, LAMP stack
# TARGET:  Armbian 12
# ============================================================================

# Output Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}========================================================${NC}"
echo -e "${RED}   WARNING: FREEPBX UNINSTALLATION SCRIPT (v0.6)            ${NC}"
echo -e "${RED}========================================================${NC}"
echo "This script will delete EVERYTHING related to PBX."
echo ""
read -p "Are you SURE? (type 'yes' to confirm): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Cancelled."
    exit 1
fi

echo ""
echo -e "${YELLOW}[1/9] Stopping services & Killing processes...${NC}"

# 1. Kill FreePBX Console first to avoid DB connection errors
fwconsole stop &> /dev/null || true

# 2. Stop Services
systemctl stop asterisk &> /dev/null
systemctl stop freepbx &> /dev/null
systemctl stop apache2 &> /dev/null
systemctl stop mariadb &> /dev/null

# 3. Aggressive Process Kill
killall -9 asterisk &> /dev/null || true
killall -9 safe_asterisk &> /dev/null || true
pkill -u asterisk &> /dev/null || true
pm2 kill &> /dev/null || true

echo -e "${YELLOW}[2/9] Removing Systemd Services...${NC}"
systemctl disable asterisk &> /dev/null
systemctl disable free-perm-fix.service &> /dev/null
rm -f /etc/systemd/system/asterisk.service
rm -f /etc/systemd/system/free-perm-fix.service
rm -f /usr/local/bin/fix_free_perm.sh
systemctl daemon-reload

echo -e "${YELLOW}[3/9] Deep Cleaning Directories...${NC}"
rm -rf /etc/asterisk
rm -rf /var/lib/asterisk
rm -rf /var/log/asterisk
rm -rf /var/spool/asterisk
rm -rf /var/run/asterisk
rm -rf /usr/lib/asterisk
rm -rf /usr/sbin/asterisk
rm -rf /var/www/html/* rm -rf /home/asterisk

# Clean Logs & Configs for LAMP Stack
rm -rf /etc/apache2
rm -rf /var/log/apache2
rm -rf /var/lib/apache2
rm -rf /etc/php
rm -rf /var/lib/php
rm -rf /var/lib/mysql
rm -rf /var/log/mysql

echo -e "${YELLOW}[4/9] Removing Users and Groups...${NC}"
deluser --remove-home asterisk &> /dev/null || true
delgroup asterisk &> /dev/null || true

echo -e "${YELLOW}[5/9] Removing NodeJS & PM2...${NC}"
npm uninstall -g pm2 &> /dev/null
rm -rf /usr/lib/node_modules
rm -rf /etc/npm
rm -rf ~/.npm

echo -e "${YELLOW}[6/9] Purging Main Packages...${NC}"
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
    apache2* \
    mariadb* \
    php* \
    nodejs npm \
    unixodbc* odbcinst* \
    libasterisk* \
    xmlstarlet &> /dev/null

echo -e "${YELLOW}[7/9] Removing Dependency Libraries...${NC}"
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
    libopus0 libvorbis0a libspeex1 libspeexdsp1 libgsm1 \
    libltdl7 libicu-dev &> /dev/null

echo -e "${YELLOW}[8/9] Cleaning up Package Manager...${NC}"
apt-get autoremove -y &> /dev/null
apt-get clean &> /dev/null

echo -e "${YELLOW}[9/9] Final Sweep...${NC}"
rm -rf /etc/apache2 2>/dev/null
rm -rf /etc/php 2>/dev/null
rm -rf /etc/asterisk 2>/dev/null
rm -rf /etc/mysql 2>/dev/null
# Remove Status Banner
rm -f /etc/update-motd.d/99-pbx-status 2>/dev/null

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}   SYSTEM CLEANED                                       ${NC}"
echo -e "${GREEN}========================================================${NC}"
echo "Reboot recommended."
