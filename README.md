# Hardware QR (Arch-only)

Проєкт орієнтований на **Arch/Manjaro**: збір QR з уже запущеної системи або через **Arch Live ISO**.

## Скрипти (3 точки входу)

| Скрипт | Коли використовувати |
|--------|----------------------|
| **`install_deps.sh`** | Один раз: встановити пакети |
| **`scripts/linux_hardware_qr.sh`** | Збір QR на вже запущеній Arch/Manjaro |
| **`build_iso.sh`** | Збірка Arch Live ISO для флешки |

Усередині Live ISO автоматично стартує `scripts/hardware_qr.sh` (його не запускають вручну).

## Швидкий старт без ISO

```bash
sudo ./install_deps.sh
sudo ./scripts/linux_hardware_qr.sh
```

Опційно:

```bash
./scripts/linux_hardware_qr.sh --ticket 12345 --png hardware-qr.png --payload hardware-qr-payload.txt
```

## Збірка Arch Live ISO

```bash
sudo ./install_deps.sh
./build_iso.sh
```

Результат:

```text
arch-hardware-qr-2026.07.09-150312.iso
arch-hardware-qr.iso -> arch-hardware-qr-2026.07.09-150312.iso
```

Фіксований штамп:

```bash
ISO_BUILD_STAMP=2026.07.09-120000 ./build_iso.sh
```

Live ISO: `uk_UA.UTF-8`, шрифт `LatArCyrHeb-16`, розкладка `ua`, автозапуск на `tty1`.

## Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows_hardware_qr.ps1
```

## Формат QR

[docs/QR_SCHEMA_v1.md](docs/QR_SCHEMA_v1.md)
