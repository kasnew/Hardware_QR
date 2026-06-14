#!/usr/bin/env bash
set -euo pipefail

# mkarchiso may copy overlay files without the execute bit; fix before squashfs.
if [ -f /usr/local/bin/hardware_qr.sh ]; then
    chmod 755 /usr/local/bin/hardware_qr.sh
fi
