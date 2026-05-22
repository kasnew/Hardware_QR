#!/bin/sh -e

HOSTNAME="$1"
if [ -z "$HOSTNAME" ]; then
    echo "usage: $0 hostname"
    exit 1
fi

cleanup() {
    rm -rf "$tmp"
}

makefile() {
    OWNER="$1"
    PERMS="$2"
    FILENAME="$3"
    cat > "$FILENAME"
    chown "$OWNER" "$FILENAME"
    chmod "$PERMS" "$FILENAME"
}

rc_add() {
    mkdir -p "$tmp"/etc/runlevels/"$2"
    ln -sf /etc/init.d/"$1" "$tmp"/etc/runlevels/"$2"/"$1"
}

tmp="$(mktemp -d)"
trap cleanup EXIT

# 1. Basic Networking and Hostname
mkdir -p "$tmp"/etc/network
makefile root:root 0644 "$tmp"/etc/hostname <<\EOFSH
alpine-qr
EOFSH

makefile root:root 0644 "$tmp"/etc/network/interfaces <<\EOFSH
auto lo
iface lo inet loopback
EOFSH

mkdir -p "$tmp"/etc/apk
makefile root:root 0644 "$tmp"/etc/apk/world <<\EOFSH
alpine-base
kbd
coreutils
dmidecode
fbida
file
libqrencode-tools
lsblk
pciutils
smartmontools
util-linux
EOFSH

# Inject Custom Configuration Files
mkdir -p "$tmp"/etc "$tmp"/sbin "$tmp"/root "$tmp"/usr/local/bin
cp /src/inittab "$tmp"/etc/inittab
cp /src/autologin "$tmp"/sbin/autologin
cp /src/profile "$tmp"/root/.profile
cp /src/hardware_qr.sh "$tmp"/usr/local/bin/hardware_qr.sh

chown root:root "$tmp"/etc/inittab "$tmp"/sbin/autologin "$tmp"/root/.profile "$tmp"/usr/local/bin/hardware_qr.sh
chmod 0644 "$tmp"/etc/inittab "$tmp"/root/.profile
chmod 0755 "$tmp"/sbin/autologin "$tmp"/usr/local/bin/hardware_qr.sh

# Enable standard required services
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add networking boot

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

# Compress overlay
tar -c -C "$tmp" etc sbin root usr | gzip -9n > $HOSTNAME.apkovl.tar.gz
