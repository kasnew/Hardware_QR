#!/bin/bash
set -e

WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"

print_build_menu() {
    echo "========================================"
    echo " Hardware QR — ISO Build Menu"
    echo "========================================"
    echo ""
    echo "  1) Alpine Linux"
    echo "     ~200 MB, швидкий старт, мінімальний образ"
    echo "     -> alpine-hardware-qr.iso"
    echo ""
    echo "  2) Arch Linux"
    echo "     ~500 MB, кращі драйвери/GPU, стабільніший QR на екрані"
    echo "     -> arch-hardware-qr.iso"
    echo ""
    echo "  3) Exit"
    echo ""
}

run_build_target() {
    local target="$1"
    case "$target" in
        alpine|1)
            exec "${WORKSPACE_DIR}/build_iso_alpine.sh"
            ;;
        arch|2)
            exec "${WORKSPACE_DIR}/build_iso_arch.sh"
            ;;
        exit|quit|q|3)
            echo "Cancelled."
            exit 0
            ;;
        *)
            echo "Unknown target: $target"
            echo "Use: alpine | arch"
            exit 1
            ;;
    esac
}

if [ -n "${1:-}" ]; then
    run_build_target "$1"
fi

if [ -n "${BUILD_TARGET:-}" ]; then
    run_build_target "$BUILD_TARGET"
fi

print_build_menu
printf "Select build [1-3]: "
read -r choice

case "$choice" in
    1) run_build_target alpine ;;
    2) run_build_target arch ;;
    3|"") echo "Cancelled."; exit 0 ;;
    *)
        echo "Invalid choice: $choice"
        exit 1
        ;;
esac
