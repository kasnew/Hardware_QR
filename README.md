# Hardware QR (Arch-only)

Проєкт переведено в режим **тільки для Arch/Manjaro**.
Підтримку Alpine Live ISO видалено.

## Що робить проєкт

Скрипти збирають апаратні характеристики ПК (CPU, RAM, плата, BIOS, GPU, накопичувачі, батарея), формують payload у форматі `V/1|...` та генерують QR-код для швидкого перенесення даних у сервісну систему.

## Склад репозиторію

- `scripts/linux_hardware_qr.sh` - збір апаратних даних і генерація QR на Linux (основний сценарій для Arch/Manjaro).
- `scripts/windows_hardware_qr.ps1` - сумісний генератор payload/QR для Windows.
- `docs/QR_SCHEMA_v1.md` - схема парсингу QR payload.
- `install_deps.sh` - встановлення залежностей **лише** для Arch/Manjaro.

## Швидкий старт (Arch/Manjaro)

```bash
sudo ./install_deps.sh
chmod +x scripts/linux_hardware_qr.sh
sudo ./scripts/linux_hardware_qr.sh
```

Опційно:

```bash
./scripts/linux_hardware_qr.sh --ticket 12345 --png hardware-qr.png --payload hardware-qr-payload.txt
```

Результати: `hardware-qr.png` і `hardware-qr-payload.txt`.

## Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows_hardware_qr.ps1
```

Опційно:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows_hardware_qr.ps1 -Ticket 12345 -OutputPath .\hardware-qr.bmp
```

Результати: `hardware-qr.bmp` і `hardware-qr.payload.txt`.

## Формат QR для материнської програми

Інструкція з парсингу згенерованого QR-коду (схема v1): [docs/QR_SCHEMA_v1.md](docs/QR_SCHEMA_v1.md)
