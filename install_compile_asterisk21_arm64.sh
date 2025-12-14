cd /usr/src

# 1. Download dei sorgenti
echo "Scaricamento Asterisk 21..."
wget https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-21-current.tar.gz
tar xvf asterisk-21-current.tar.gz
cd asterisk-21.*

# 2. Download sorgenti MP3 (per Music on Hold)
contrib/scripts/get_mp3_source.sh

# 3. Configurazione (Bundled PJProject è la chiave qui)
echo "Configurazione build..."
./configure --libdir=/usr/lib --with-pjproject-bundled --with-jansson-bundled

# 4. Selezione Moduli (Menuselect)
# Abilitiamo il supporto MP3 e i suoni extra
make menuselect.makeopts
menuselect/menuselect --enable format_mp3 menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-WAV menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ULAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ALAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-GSM menuselect.makeopts
menuselect/menuselect --enable app_macro menuselect.makeopts # Utile per compatibilità vecchia

# 5. Compilazione (Questo impiegherà 15-20 minuti su T95 Max+)
echo "Inizio compilazione (vai a prenderti un caffè)..."
make -j4

# 6. Installazione
make install
make samples
make config
ldconfig

echo "Asterisk compilato e installato."
