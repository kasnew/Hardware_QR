#!/usr/bin/env bash
set -euo pipefail

# mkarchiso may copy overlay files without the execute bit; fix before squashfs.
if [ -f /usr/local/bin/hardware_qr.sh ]; then
    chmod 755 /usr/local/bin/hardware_qr.sh
fi

# Ukrainian UTF-8 locale for Cyrillic UI strings in hardware_qr.sh.
if [ -f /etc/locale.gen ]; then
    sed -i 's/^#\(uk_UA.UTF-8 UTF-8\)/\1/' /etc/locale.gen
    locale-gen
fi

install -Dm644 /dev/null /etc/locale.conf
cat > /etc/locale.conf <<'EOF'
LANG=uk_UA.UTF-8
LC_TIME=uk_UA.UTF-8
LC_NUMERIC=uk_UA.UTF-8
LC_MONETARY=uk_UA.UTF-8
LC_PAPER=uk_UA.UTF-8
LC_NAME=uk_UA.UTF-8
LC_ADDRESS=uk_UA.UTF-8
LC_TELEPHONE=uk_UA.UTF-8
LC_MEASUREMENT=uk_UA.UTF-8
LC_IDENTIFICATION=uk_UA.UTF-8
EOF

install -Dm644 /dev/null /etc/vconsole.conf
cat > /etc/vconsole.conf <<'EOF'
KEYMAP=ua
FONT=LatArCyrHeb-16
FONT_MAP=
FONT_UNIMAP=
EOF

if command -v localectl >/dev/null 2>&1; then
    localectl set-locale LANG=uk_UA.UTF-8 2>/dev/null || true
    localectl set-keymap ua 2>/dev/null || true
    localectl set-font LatArCyrHeb-16 2>/dev/null || true
fi

if command -v setfont >/dev/null 2>&1; then
    for _font in \
        /usr/share/kbd/consolefonts/LatArCyrHeb-16.psfu.gz \
        /usr/share/kbd/consolefonts/UniCyr_8x16.psfu.gz \
        /usr/share/kbd/consolefonts/Cyr_a8x16.psfu.gz; do
        if [ -f "$_font" ]; then
            setfont "$_font" 2>/dev/null && break
        fi
    done
fi
