#!/bin/bash
# Скрипт для запуску та перевірки згенерованого образу в емуляторі QEMU

WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"
ALPINE_ISO="${WORKSPACE_DIR}/alpine-hardware-qr.iso"
ARCH_ISO="${WORKSPACE_DIR}/arch-hardware-qr.iso"

pick_iso() {
    local target="$1"

    case "$target" in
        alpine|1)
            ISO_FILE="$ALPINE_ISO"
            ;;
        arch|2)
            ISO_FILE="$ARCH_ISO"
            ;;
        *)
            if [ -f "$ALPINE_ISO" ] && [ -f "$ARCH_ISO" ]; then
                echo "========================================"
                echo " QEMU — select ISO"
                echo "========================================"
                echo "  1) alpine-hardware-qr.iso"
                echo "  2) arch-hardware-qr.iso"
                echo ""
                printf "Select ISO [1-2]: "
                read -r choice
                case "$choice" in
                    2) ISO_FILE="$ARCH_ISO" ;;
                    *) ISO_FILE="$ALPINE_ISO" ;;
                esac
            elif [ -f "$ARCH_ISO" ]; then
                ISO_FILE="$ARCH_ISO"
            elif [ -f "$ALPINE_ISO" ]; then
                ISO_FILE="$ALPINE_ISO"
            else
                echo "Помилка: ISO не знайдено."
                echo "Спочатку запустіть ./build_iso.sh (Alpine або Arch)."
                exit 1
            fi
            ;;
    esac
}

pick_iso "${1:-}"

if [ ! -f "$ISO_FILE" ]; then
    echo "Помилка: Файл $ISO_FILE не знайдено!"
    echo "Запустіть ./build_iso.sh і оберіть потрібну збірку."
    exit 1
fi

echo "========================================"
echo " Запуск віртуальної машини QEMU..."
echo " ISO: $(basename "$ISO_FILE")"
echo "========================================"
echo "Для виходу з QEMU закрийте вікно емулятора."
echo "Docker для цього кроку НЕ потрібен, ISO запускається безпосередньо."

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "Помилка: qemu-system-x86_64 не встановлено."
    echo "Встановіть його: sudo ./install_deps.sh"
    exit 1
fi

if [ -e /dev/kvm ]; then
    if ! qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 1024 -cdrom "$ISO_FILE" -boot d -display sdl 2>/dev/null; then
        echo "Не вдалося запустити з інтерфейсом SDL. Спроба використати стандартний інтерфейс (GTK)..."
        qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 1024 -cdrom "$ISO_FILE" -boot d
    fi
else
    echo "KVM не знайдено, запуск у режимі програмної емуляції..."
    if ! qemu-system-x86_64 -smp 2 -m 1024 -cdrom "$ISO_FILE" -boot d -display sdl 2>/dev/null; then
        qemu-system-x86_64 -smp 2 -m 1024 -cdrom "$ISO_FILE" -boot d
    fi
fi
