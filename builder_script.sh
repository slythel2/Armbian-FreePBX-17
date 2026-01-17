#!/bin/bash

# ============================================================================
# AUTOMATED BUILD SCRIPT (Executed inside the ARM64 container)
# TARGET: Asterisk 22 LTS for Debian 12 (Bookworm)
# ============================================================================

# Stop execution on any error
set -e

ASTERISK_VER="$1"
[ -z "$ASTERISK_VER" ] && ASTERISK_VER="22-current"

BUILD_DIR="/usr/src/asterisk_build"
OUTPUT_DIR="/workspace"
DEBIAN_FRONTEND=noninteractive

echo ">>> [BUILDER] Starting build for version: $ASTERISK_VER"

# 1. Install Build Dependencies (inside the container)
echo ">>> [BUILDER] Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive

# For debugging, avoid -qq so we can see any package install failures in the logs.
apt-get update

# Install explicit libc dev packages and compilers in addition to build-essential
apt-get install -y --no-install-recommends \
    build-essential libc6-dev linux-libc-dev gcc g++ \
    git curl wget subversion pkg-config \
    autoconf automake libtool binutils \
    libncurses5-dev libncursesw5-dev libxml2-dev libsqlite3-dev \
    libssl-dev uuid-dev libjansson-dev libedit-dev libxslt1-dev \
    libicu-dev libsrtp2-dev libopus-dev libvorbis-dev libspeex-dev \
    libspeexdsp-dev libgsm1-dev portaudio19-dev \
    unixodbc unixodbc-dev odbcinst libltdl-dev

# Verification/debugging: ensure headers and compiler exist
echo ">>> [BUILDER] Verifying toolchain and headers..."
gcc --version || true
g++ --version || true
ls -l /usr/include/sys/socket.h || true
dpkg -l libc6-dev linux-libc-dev build-essential || true

if [ ! -f /usr/include/sys/socket.h ]; then
    echo ">>> [BUILDER][ERROR] /usr/include/sys/socket.h not present. Reinstalling libc6-dev..."
    apt-get install -y --reinstall libc6-dev linux-libc-dev || {
        echo ">>> [BUILDER][FATAL] Reinstall failed. See previous apt output."
        exit 1
    }
fi

mkdir -p $BUILD_DIR
cd $BUILD_DIR

# 2. Download Sources
echo ">>> [BUILDER] Downloading Asterisk sources..."
wget -qO asterisk.tar.gz "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VER}.tar.gz"
tar -xzf asterisk.tar.gz --strip-components=1
rm asterisk.tar.gz

# 3. Download MP3 Sources
echo ">>> [BUILDER] Downloading MP3 resources..."
contrib/scripts/get_mp3_source.sh

# 4. Configuration
# REMOVED: --with-jansson-bundled (Using system libjansson is safer on Debian 12)
# KEPT: --with-pjproject-bundled (Required for Asterisk stability)
echo ">>> [BUILDER] Configuring..."
./configure --libdir=/usr/lib --with-pjproject-bundled --without-x11 --without-gtk2

# 5. Module Selection (Headless)
echo ">>> [BUILDER] Selecting modules..."
make menuselect.makeopts
menuselect/menuselect --enable format_mp3 menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-WAV menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ULAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ALAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-GSM menuselect.makeopts
# Disable BUILD_NATIVE to prevent CPU instruction errors on different ARM chips
menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts

# 6. Compilation
# MODIFIED: Limited to -j2 to prevent race conditions/crashes in QEMU emulation
echo ">>> [BUILDER] Compiling (Limited to 2 cores for stability)..."
make -j2

# 7. Install to temporary directory (Staging)
echo ">>> [BUILDER] Creating installation structure..."
make install DESTDIR=$BUILD_DIR/staging
make samples DESTDIR=$BUILD_DIR/staging
make config DESTDIR=$BUILD_DIR/staging

# 8. Artifact Creation (.tar.gz)
echo ">>> [BUILDER] Final packaging..."
cd $BUILD_DIR/staging
TAR_NAME="asterisk-${ASTERISK_VER}-arm64-debian12.tar.gz"
tar -czvf "$OUTPUT_DIR/$TAR_NAME" .

echo ">>> [BUILDER] Success! Artifact created: $TAR_NAME"
