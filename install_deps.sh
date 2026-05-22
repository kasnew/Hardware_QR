#!/bin/bash
# Скрипт для встановлення залежностей (Docker та QEMU) на різних дистрибутивах Linux

if [ "$EUID" -ne 0 ]; then
  echo "Помилка: Будь ласка, запустіть цей скрипт від імені root (наприклад: sudo ./install_deps.sh)"
  exit 1
fi

echo "========================================"
echo " Встановлення залежностей для збірки ISO"
echo "========================================"

echo "Визначення вашої операційної системи..."

if grep -qi "arch\|manjaro" /etc/os-release; then
    echo "Виявлено Arch/Manjaro Linux. Встановлюємо пакети через pacman..."
    pacman -Sy --noconfirm docker qemu-system-x86 qemu-ui-sdl qemu-ui-gtk
    systemctl start docker
    systemctl enable docker

elif grep -qi "ubuntu\|debian" /etc/os-release; then
    echo "Виявлено Ubuntu/Debian. Встановлюємо пакети через apt..."
    apt-get update
    apt-get install -y docker.io qemu-system-x86 qemu-utils
    systemctl start docker
    systemctl enable docker

elif grep -qi "fedora" /etc/os-release; then
    echo "Виявлено Fedora. Встановлюємо пакети через dnf..."
    dnf install -y docker qemu-system-x86 qemu-ui-sdl
    systemctl start docker
    systemctl enable docker

else
    echo "Ваш дистрибутив Linux не розпізнано автоматично."
    echo "Будь ласка, встановіть 'docker' та 'qemu-system-x86_64' вручну за допомогою вашого пакетного менеджера."
    exit 1
fi

# Налаштування прав доступу для Docker
if [ -n "$SUDO_USER" ]; then
    echo "Додаємо користувача $SUDO_USER до групи docker..."
    usermod -aG docker "$SUDO_USER"
    echo "--------------------------------------------------------"
    echo "ВАЖЛИВО: Щоб ви могли використовувати Docker без sudo,"
    echo "вам необхідно вийти з системи і зайти знову (logout/login),"
    echo "або перезавантажити ПК."
    echo "--------------------------------------------------------"
fi

echo "Всі необхідні залежності успішно встановлено!"
