#!/bin/bash
# Скрипт для запуску та перевірки згенерованого образу в емуляторі QEMU

ISO_FILE="alpine-hardware-qr.iso"

if [ ! -f "$ISO_FILE" ]; then
    echo "Помилка: Файл $ISO_FILE не знайдено!"
    echo "Будь ласка, спочатку запустіть ./build_iso.sh для створення образу."
    exit 1
fi

echo "========================================"
echo " Запуск віртуальної машини QEMU..."
echo "========================================"
echo "Для виходу з QEMU закрийте вікно емулятора."

# Спроба запустити з KVM та графічним інтерфейсом SDL
if ! qemu-system-x86_64 -enable-kvm -m 1024 -cdrom "$ISO_FILE" -boot d -display sdl 2>/dev/null; then
    echo "Не вдалося запустити з інтерфейсом SDL. Спроба використати стандартний інтерфейс..."
    # Фолбек, якщо SDL недоступний
    qemu-system-x86_64 -enable-kvm -m 1024 -cdrom "$ISO_FILE" -boot d
fi
