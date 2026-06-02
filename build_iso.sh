#!/bin/bash
set -e

WORKSPACE_DIR="$(pwd)"
OUT_DIR="${WORKSPACE_DIR}/iso_output"
MODLOOP_COMPRESSOR="${MODLOOP_COMPRESSOR:-zstd}"
MODLOOP_ZSTD_LEVEL="${MODLOOP_ZSTD_LEVEL:-1}"
mkdir -p "${OUT_DIR}"

echo "========================================"
echo " Building Custom Alpine Hardware QR ISO"
echo "========================================"
echo " Modloop compression: ${MODLOOP_COMPRESSOR}"
if [ "${MODLOOP_COMPRESSOR}" = "zstd" ]; then
    echo " Zstd level: ${MODLOOP_ZSTD_LEVEL}"
    case "${MODLOOP_ZSTD_LEVEL}" in
        ''|*[!0-9]*)
            echo "MODLOOP_ZSTD_LEVEL must be a positive number"
            exit 1
            ;;
    esac
fi

case "${MODLOOP_COMPRESSOR}" in
    zstd|gzip|lzo|xz)
        ;;
    *)
        echo "Unsupported MODLOOP_COMPRESSOR='${MODLOOP_COMPRESSOR}'"
        echo "Use one of: zstd, gzip, lzo, xz"
        exit 1
        ;;
esac

cat << 'EOF' > Dockerfile.build
FROM alpine:3.19
ARG MODLOOP_COMPRESSOR=zstd
ARG MODLOOP_ZSTD_LEVEL=1

RUN apk update && apk add --no-cache \
    alpine-sdk build-base apk-tools alpine-conf \
    mtools dosfstools grub-efi xorriso syslinux

RUN git clone --depth=1 -b 3.19-stable https://gitlab.alpinelinux.org/alpine/aports.git /aports

RUN set -eux; \
    update_kernel="$(command -v update-kernel)"; \
    mksquashfs_opts_ref='$MKSQUASHFS_OPTS'; \
    mksfs_ref='$mksfs'; \
    case "$MODLOOP_COMPRESSOR" in \
        zstd) modloop_comp="-comp zstd -Xcompression-level ${MODLOOP_ZSTD_LEVEL} -exit-on-error" ;; \
        gzip) modloop_comp="-comp gzip -exit-on-error" ;; \
        lzo) modloop_comp="-comp lzo -exit-on-error" ;; \
        xz) modloop_comp="-comp xz -exit-on-error" ;; \
        *) echo "Unsupported MODLOOP_COMPRESSOR=$MODLOOP_COMPRESSOR" >&2; exit 1 ;; \
    esac; \
    if [ "$MODLOOP_COMPRESSOR" != xz ]; then \
        mksquashfs_opts_ref='$(printf "%s" "$MKSQUASHFS_OPTS" | sed "s/-Xbcj[[:space:]][^[:space:]]*//g")'; \
        mksfs_ref='$(printf "%s" "$mksfs" | sed "s/-Xbcj[[:space:]][^[:space:]]*//g")'; \
    fi; \
    grep -F -- "-comp xz -exit-on-error" "$update_kernel"; \
    sed -i "s|-comp xz -exit-on-error|${modloop_comp}|" "$update_kernel"; \
    sed -i "s@\\\$MKSQUASHFS_OPTS -comp@${mksquashfs_opts_ref} -comp@" "$update_kernel"; \
    sed -i "s@ -exit-on-error \\\$mksfs@ -exit-on-error ${mksfs_ref}@" "$update_kernel"; \
    grep -F -- "$modloop_comp" "$update_kernel"; \
    grep -n 'mksquashfs' "$update_kernel"

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

if docker info >/dev/null 2>&1; then
    DOCKER="docker"
elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    echo "Docker requires sudo. Prefixing docker commands with sudo..."
    DOCKER="sudo docker"
else
    if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet docker; then
        echo "Docker daemon is not running."
        if command -v sudo >/dev/null 2>&1 && sudo -n systemctl start docker >/dev/null 2>&1; then
            echo "Docker started successfully."
            if docker info >/dev/null 2>&1; then
                DOCKER="docker"
            elif sudo -n docker info >/dev/null 2>&1; then
                DOCKER="sudo docker"
            fi
        fi
    fi

    if [ -z "${DOCKER:-}" ]; then
        echo "Docker is not accessible from this user."
        echo "Start Docker and either add this user to the docker group or run this script with sudo."
        exit 1
    fi
fi

echo "Building Docker image and compiling ISO (no-cache for config freshness)..."
$DOCKER build --no-cache \
    --build-arg MODLOOP_COMPRESSOR="${MODLOOP_COMPRESSOR}" \
    --build-arg MODLOOP_ZSTD_LEVEL="${MODLOOP_ZSTD_LEVEL}" \
    -t alpine-iso-builder \
    -f Dockerfile.build .

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
