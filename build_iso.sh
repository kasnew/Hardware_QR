#!/bin/bash
set -e

WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${WORKSPACE_DIR}/iso_output"
ARCH_ENV_IMAGE="hardware-qr-arch-env"
RUNTIME_SCRIPT="${WORKSPACE_DIR}/scripts/hardware_qr.sh"

iso_build_stamp() {
    date +%Y.%m.%d-%H%M%S
}

resolve_docker() {
    if docker info >/dev/null 2>&1; then
        DOCKER="docker"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
        echo "Docker requires sudo. Prefixing docker commands with sudo..."
        DOCKER="sudo docker"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet docker; then
        echo "Docker daemon is not running."
        if command -v sudo >/dev/null 2>&1 && sudo -n systemctl start docker >/dev/null 2>&1; then
            echo "Docker started successfully."
            if docker info >/dev/null 2>&1; then
                DOCKER="docker"
                return 0
            fi
            if sudo -n docker info >/dev/null 2>&1; then
                DOCKER="sudo docker"
                return 0
            fi
        fi
    fi

    echo "Docker is not accessible from this user."
    echo "Start Docker and either add this user to the docker group or run this script with sudo."
    return 1
}

BUILD_STAMP="${ISO_BUILD_STAMP:-$(iso_build_stamp)}"
DEST_ISO="${WORKSPACE_DIR}/arch-hardware-qr-${BUILD_STAMP}.iso"

if [ ! -f "${RUNTIME_SCRIPT}" ]; then
    echo "Error: missing ${RUNTIME_SCRIPT}"
    exit 1
fi

mkdir -p "${OUT_DIR}"

echo "========================================"
echo " Building Arch Hardware QR ISO"
echo "========================================"
echo " Base profile: archiso baseline"
echo " Build stamp : ${BUILD_STAMP}"
echo " Output      : ${DEST_ISO}"
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
    -e BUILD_STAMP="${BUILD_STAMP}" \
    -v "${WORKSPACE_DIR}:/src:ro" \
    -v "${OUT_DIR}:/out" \
    "${ARCH_ENV_IMAGE}" \
    bash -eu -c '
set -euo pipefail
rm -rf /profile /tmp/work
cp -a /usr/share/archiso/configs/baseline /profile
cp /src/arch-config/qr/profiledef.sh /profile/profiledef.sh
sed -i "s/^iso_version=.*/iso_version=\"${BUILD_STAMP}\"/" /profile/profiledef.sh
sort -u /profile/packages.x86_64 /src/arch-config/qr/packages.extra > /tmp/packages.merged
mv /tmp/packages.merged /profile/packages.x86_64
cp -a /src/arch-config/qr/airootfs/. /profile/airootfs/
install -Dm755 /src/scripts/hardware_qr.sh /profile/airootfs/usr/local/bin/hardware_qr.sh
install -Dm755 /src/scripts/qr_fb_blit.py /profile/airootfs/usr/local/bin/qr_fb_blit.py
cp /src/arch-config/qr/customize_airootfs.sh /profile/customize_airootfs.sh
chmod 755 /profile/customize_airootfs.sh
chmod 755 /profile/airootfs/usr/local/bin/qr_fb_blit.py

# UEFI only: nomodeset+fixed mode keeps QR readable on Renoir/HiDPI (efifb).
# Do NOT add these to syslinux/BIOS — on Legacy they force broken vesafb
# (skewed UTF8 QR, clipped text). BIOS boots with normal KMS instead.
QR_VIDEO_CMDLINE="nomodeset video=1024x768@60"
for f in /profile/efiboot/loader/entries/*.conf; do
    [ -f "$f" ] || continue
    if ! grep -q "video=1024x768" "$f"; then
        sed -i "s/^options /options ${QR_VIDEO_CMDLINE} /" "$f"
    fi
done
# Strip the bad combo if a baseline/syslinux template ever carries it.
# (double quotes only — this block runs inside bash -c '...')
for f in /profile/syslinux/*.cfg; do
    [ -f "$f" ] || continue
    sed -i \
        -e "s/ *nomodeset//g" \
        -e "s/ *video=1024x768@60//g" \
        -e "s/ *video=1024x768//g" \
        "$f"
done

mkarchiso -v -w /tmp/work -o /out /profile
'

iso_file=$(find "${OUT_DIR}" -maxdepth 1 -type f -name '*.iso' | head -n 1)
if [ -z "$iso_file" ]; then
    echo "Error: no ISO file found in ${OUT_DIR}"
    exit 1
fi

mv -f "$iso_file" "${DEST_ISO}"
rm -rf "${OUT_DIR}"

ln -sfn "$(basename "${DEST_ISO}")" "${WORKSPACE_DIR}/arch-hardware-qr.iso"

echo "========================================"
echo " Arch build complete!"
echo " ISO: ${DEST_ISO}"
echo " Latest symlink: ${WORKSPACE_DIR}/arch-hardware-qr.iso"
echo "========================================"
