#!/bin/bash
# Скрипт для запуску та перевірки згенерованого образу в емуляторі QEMU

ISO_FILE="alpine-hardware-qr.iso"
WORKSPACE_DIR="$(pwd)"

if [ ! -f "$ISO_FILE" ]; then
    echo "Помилка: Файл $ISO_FILE не знайдено!"
    echo "Будь ласка, спочатку запустіть ./build_iso.sh для створення образу."
    exit 1
fi

echo "========================================"
echo " Запуск віртуальної машини QEMU..."
echo "========================================"
echo "Для виходу з QEMU закрийте вікно емулятора."
echo "Docker для цього кроку НЕ потрібен, ISO запускається безпосередньо."

# Перевірка наявності QEMU
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "Помилка: qemu-system-x86_64 не встановлено."
    echo "Встановіть його: sudo apt install qemu-system-x86"
    exit 1
fi

# Спроба запустити з KVM
if [ -e /dev/kvm ]; then
    if ! qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 1024 -cdrom "$ISO_FILE" -boot d -display sdl 2>/dev/null; then
        echo "Не вдалося запустити з інтерфейсом SDL. Спроба використати стандартний інтерфейс (GTK)..."
        qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 1024 -cdrom "$ISO_FILE" -boot d
    fi
else
    # Якщо KVM недоступний, запускаємо без прискорення
    echo "KVM не знайдено, запуск у режимі програмної емуляції..."
    if ! qemu-system-x86_64 -smp 2 -m 1024 -cdrom "$ISO_FILE" -boot d -display sdl 2>/dev/null; then
        qemu-system-x86_64 -smp 2 -m 1024 -cdrom "$ISO_FILE" -boot d
    fi
fi
