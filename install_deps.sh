#!/bin/bash
# Скрипт для встановлення залежностей для Arch/Manjaro

if [ "$EUID" -ne 0 ]; then
  echo "Помилка: Будь ласка, запустіть цей скрипт від імені root (наприклад: sudo ./install_deps.sh)"
  exit 1
fi

echo "========================================"
echo " Встановлення залежностей для Arch-only"
echo "========================================"

if ! grep -qi "arch\|manjaro" /etc/os-release; then
    echo "Цей репозиторій підтримує лише Arch/Manjaro."
    echo "Поточний дистрибутив не підтримується."
    exit 1
fi

echo "Виявлено Arch/Manjaro Linux. Встановлюємо пакети через pacman..."
pacman -Sy --noconfirm \
    qrencode dmidecode smartmontools pciutils util-linux lshw \
    docker qemu-system-x86 qemu-ui-sdl qemu-ui-gtk archiso
systemctl start docker
systemctl enable docker

if [ -n "$SUDO_USER" ]; then
    echo "Додаємо користувача $SUDO_USER до групи docker..."
    usermod -aG docker "$SUDO_USER"
    echo "--------------------------------------------------------"
    echo "ВАЖЛИВО: Щоб ви могли використовувати Docker без sudo,"
    echo "вийдіть із системи і зайдіть знову (logout/login)."
    echo "--------------------------------------------------------"
fi

echo "Всі необхідні залежності успішно встановлено!"
