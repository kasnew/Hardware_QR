#!/bin/bash
set -e

WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${WORKSPACE_DIR}/iso_output"
DEST_ISO="${WORKSPACE_DIR}/arch-hardware-qr.iso"
ARCH_ENV_IMAGE="hardware-qr-arch-env"

# shellcheck source=build/lib.sh
source "${WORKSPACE_DIR}/build/lib.sh"

mkdir -p "${OUT_DIR}"

echo "========================================"
echo " Building Arch Hardware QR ISO"
echo "========================================"
echo " Base profile: archiso baseline"
echo " Output: ${DEST_ISO}"
echo " Note: mkarchiso runs in a privileged container (needs mount/chroot)."

cat << 'EOF' > Dockerfile.build
FROM archlinux:latest
RUN pacman -Sy --noconfirm archiso squashfs-tools openssl \
    && pacman -Scc --noconfirm
EOF

resolve_docker

echo "Preparing Arch build environment image..."
$DOCKER build -t "${ARCH_ENV_IMAGE}" -f Dockerfile.build "${WORKSPACE_DIR}"
rm -f Dockerfile.build

echo "Running mkarchiso (privileged)..."
$DOCKER run --rm --privileged \
    -v "${WORKSPACE_DIR}:/src:ro" \
    -v "${OUT_DIR}:/out" \
    "${ARCH_ENV_IMAGE}" \
    bash -eu -c '
set -euo pipefail
rm -rf /profile /tmp/work
cp -a /usr/share/archiso/configs/baseline /profile
cp /src/arch-config/qr/profiledef.sh /profile/profiledef.sh
sort -u /profile/packages.x86_64 /src/arch-config/qr/packages.extra > /tmp/packages.merged
mv /tmp/packages.merged /profile/packages.x86_64
cp -a /src/arch-config/qr/airootfs/. /profile/airootfs/
install -Dm755 /src/src/hardware_qr.sh /profile/airootfs/usr/local/bin/hardware_qr.sh
cp /src/arch-config/qr/customize_airootfs.sh /profile/customize_airootfs.sh
chmod 755 /profile/customize_airootfs.sh
mkarchiso -v -w /tmp/work -o /out /profile
'

iso_file=$(find "${OUT_DIR}" -maxdepth 1 -type f -name '*.iso' | head -n 1)
if [ -z "$iso_file" ]; then
    echo "Error: no ISO file found in ${OUT_DIR}"
    exit 1
fi

mv -f "$iso_file" "${DEST_ISO}"
rm -rf "${OUT_DIR}"

echo "========================================"
echo " Arch build complete!"
echo " ISO: ${DEST_ISO}"
echo "========================================"
