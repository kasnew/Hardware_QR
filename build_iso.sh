#!/bin/bash
set -e

WORKSPACE_DIR="$(pwd)"
OUT_DIR="${WORKSPACE_DIR}/iso_output"
mkdir -p "${OUT_DIR}"

echo "========================================"
echo " Building Custom Alpine Hardware QR ISO"
echo "========================================"

cat << 'EOF' > Dockerfile.build
FROM alpine:3.19
RUN apk update && apk add --no-cache \
    alpine-sdk build-base apk-tools alpine-conf \
    mtools dosfstools grub-efi xorriso syslinux

RUN git clone --depth=1 -b 3.19-stable https://gitlab.alpinelinux.org/alpine/aports.git /aports

# Copy our custom configuration and source files
COPY alpine-config/genapkovl-qr.sh /aports/scripts/genapkovl-qr.sh
COPY alpine-config/mkimg.qr.sh /aports/scripts/mkimg.qr.sh
COPY src /src

RUN chmod +x /aports/scripts/genapkovl-qr.sh /aports/scripts/mkimg.qr.sh

# Initialize abuild keys for apk repository signing
RUN abuild-keygen -a -n && cp /root/.abuild/*.rsa.pub /etc/apk/keys/

WORKDIR /aports/scripts
RUN mkdir -p /out
RUN sh mkimage.sh --profile qr --outdir /out --repository https://dl-cdn.alpinelinux.org/alpine/v3.19/main --repository https://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF

if ! sudo docker info >/dev/null 2>&1; then
    echo "Docker daemon is not running. Attempting to start it automatically..."
    sudo systemctl start docker || { echo "Failed to start docker. Please start it manually."; exit 1; }
    echo "Docker started successfully."
fi

if ! docker ps >/dev/null 2>&1; then
    echo "Docker requires sudo. Prefixing docker commands with sudo..."
    DOCKER="sudo docker"
else
    DOCKER="docker"
fi

echo "Building Docker image and compiling ISO (no-cache for config freshness)..."
$DOCKER build --no-cache -t alpine-iso-builder -f Dockerfile.build .

echo "Extracting ISO from container..."
CONTAINER_ID=$($DOCKER create alpine-iso-builder)
$DOCKER cp ${CONTAINER_ID}:/out/. ${OUT_DIR}/
$DOCKER rm ${CONTAINER_ID}

ISO_FILE=$(ls ${OUT_DIR}/*.iso | head -n 1)
mv -f "${ISO_FILE}" "${WORKSPACE_DIR}/alpine-hardware-qr.iso"
rm -rf "${OUT_DIR}"
rm -f Dockerfile.build

echo "========================================"
echo " Build Complete!"
echo " ISO: ${WORKSPACE_DIR}/alpine-hardware-qr.iso"
echo "========================================"
