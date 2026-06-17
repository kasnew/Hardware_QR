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
