#!/bin/bash
set -e

ISO_FILE="alpine-hardware-qr.iso"

if [ ! -f "$ISO_FILE" ]; then
    echo "Помилка: $ISO_FILE не знайдено! Будь ласка, запустіть build_iso.sh спочатку."
    exit 1
fi

echo "========================================================="
echo " Витягнення ядра та initramfs з $ISO_FILE..."
echo "========================================================="
mkdir -p /tmp/alpine_iso_mnt

# Використовуємо sudo для монтування loop
sudo mount -o loop "$ISO_FILE" /tmp/alpine_iso_mnt
cp /tmp/alpine_iso_mnt/boot/vmlinuz-lts ./vmlinuz-lts
cp /tmp/alpine_iso_mnt/boot/initramfs-lts ./initramfs-lts
sudo umount /tmp/alpine_iso_mnt

echo "✅ Ядро та initramfs успішно витягнуто."
echo ""
echo "========================================================="
echo " Запуск QEMU для профілювання завантаження"
echo "========================================================="
echo "ОБОВ'ЯЗКОВО ЗВЕРНІТЬ УВАГУ на таймстемпи (наприклад, [ 2.1234 ])."
echo "Якщо ви бачите раптовий стрибок часу на 60 секунд,"
echo "попередній рядок покаже модуль або процес, який завис."
echo "========================================================="
echo ""

# Читаємо параметри з нашого конфігу або використовуємо ті ж, що ми щойно додали
APPEND_ARGS="modules=loop,squashfs,sd-mod,usb-storage,nvme,vfat nomodeset video=1024x768@60 modprobe.blacklist=floppy usbdelay=1 edd=off nopnp"

# Перевіряємо чи підтримує хост KVM для швидшої роботи QEMU
if [ -e /dev/kvm ]; then
    KVM_ARG="-enable-kvm"
else
    KVM_ARG=""
fi

qemu-system-x86_64 \
    -m 2048 \
    $KVM_ARG \
    -kernel vmlinuz-lts \
    -initrd initramfs-lts \
    -cdrom "$ISO_FILE" \
    -append "$APPEND_ARGS"

echo ""
echo "Тест завершено!"
