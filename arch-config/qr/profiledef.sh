#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="arch-hardware-qr"
iso_label="HARDWARE_QR"
iso_publisher="Hardware QR Project <https://github.com/kasnew/Hardware_QR>"
iso_application="Hardware QR Live ISO (uk_UA)"
iso_version="0.0.0"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.systemd-boot')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
bootstrap_packages=(arch-install-scripts)
