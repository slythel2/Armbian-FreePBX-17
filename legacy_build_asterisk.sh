#!/bin/bash

# ============================================================================
# DEPRECATED / ARCHIVE ONLY
# ============================================================================
# This script is NO LONGER USED in the production installation workflow.
# It is preserved here for safekeeping and reference purposes only.
#
# It documents the manual process used to compile Asterisk 21 from source
# to create the artifacts used by the main installer.
# ============================================================================

# Stop execution on any error
set -e

cd /usr/src

# 1. Clean & Download Source
echo "Cleaning old sources and downloading Asterisk 21..."
rm -rf asterisk-21*
wget https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-21-current.tar.gz
tar xvf asterisk-21-current.tar.gz
cd asterisk-21.*

# 2. Download MP3 Source (Required for Music on Hold)
echo "Downloading MP3 sources..."
contrib/scripts/get_mp3_source.sh

# 3. Configure Build
# --libdir=/usr/lib is crucial for our specific artifact structure
# --with-pjproject-bundled ensures we don't rely on system PJLIB which can be outdated
echo "Configuring build environment..."
./configure --libdir=/usr/lib --with-pjproject-bundled --with-jansson-bundled

# 4. Module Selection via Menuselect
echo "Selecting modules..."
make menuselect.makeopts

# Enable MP3 Support
menuselect/menuselect --enable format_mp3 menuselect.makeopts

# Enable Sound Packages (Standard & GSM)
menuselect/menuselect --enable CORE-SOUNDS-EN-WAV menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ULAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ALAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-GSM menuselect.makeopts

# NOTE: 'app_macro' has been removed in Asterisk 21. 
# Do not attempt to enable it, or the build script will fail.
# Use app_stack (GoSub) instead in dialplans.

# 5. Compile
# Uses $(nproc) to automatically detect available CPU cores for faster build
echo "Starting compilation on $(nproc) cores..."
make -j$(nproc)

# 6. Install & Link
echo "Installing binaries..."
make install
make samples
make config

# 7. CRITICAL FIX: Library Linking
# Ensures the system knows where to find the custom libraries in /usr/lib
echo "Configuring dynamic linker..."
echo "/usr/lib" > /etc/ld.so.conf.d/asterisk.conf
ldconfig

# 8. Verification
echo "Build Complete. Verifying version..."
asterisk -V
