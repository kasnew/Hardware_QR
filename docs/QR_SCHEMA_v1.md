# Hardware QR — схема v1 (парсинг для материнської програми)

## Обгортка QR (стиснення)

На екрані в QR-коді зазвичай **не** сирий v1-рядок, а стиснута обгортка:

```
V/1|Z/<base64(gzip(оригінальний v1 рядок))>
```

**Декодування перед парсингом v1:**

```python
import base64, gzip

def decode_qr_payload(qr_text: str) -> str:
    if qr_text.startswith("V/1|Z/"):
        b64 = qr_text[6:]  # після "V/1|Z/"
        return gzip.decompress(base64.b64decode(b64)).decode("utf-8")
    return qr_text  # без стиснення (рідко)
```

Далі парсіть повернутий рядок як v1 (сегменти `|`, поля `/`).

---

## Формат v1 (після розпакування)

QR містить **один текстовий рядок**. Розбиття в два кроки:

1. **Сегменти** — роздільник `|`
2. **Поля** в сегменті — роздільник `/`

Формат сегмента: `TAG/поле1/поле2/...`

- Перший сегмент завжди **`V/1`** (версія схеми).
- Символи `/` та `|` у значеннях на стороні Live ISO замінюються на `-`.

---

## Алгоритм

```
segments = qr_text.split("|")

for seg in segments:
    parts = seg.split("/")
    tag = parts[0]
    fields = parts[1:]

    зберегти або додати в колекцію за tag
```

---

## Скалярні теги

| Тег | Поля `fields` | Опис |
|-----|---------------|------|
| `V` | `[1]` | Версія схеми, очікуйте `"1"` |
| `T` | `[ticket]` | Номер заявки |
| `DT` | `[iso-utc]` | Час збору, напр. `2026-05-21T12:00:00Z` |
| `C` | `[cpu]` | Модель CPU |
| `CT` | `[cores, threads]` | Ядра та потоки |
| `R` | `[ram]` | Сумарна RAM, напр. `16Gi` |
| `SM` | `[manufacturer]` | Виробник системи |
| `PN` | `[product]` | Модель продукту |
| `SS` | `[serial]` | Серійник системи |
| `UUID` | `[uuid]` | UUID машини |
| `AT` | `[asset]` | Asset tag |
| `M` | `[board]` | Материнська плата |
| `MS` | `[board_sn]` | Серійник плати |
| `B` | `[bios]` | Версія BIOS |
| `BD` | `[date]` | Дата BIOS |
| `BF` | `[full]` | Повний рядок BIOS |
| `TPM` | `[status]` | `2.0`, `1.2`, `present`, `none` |

---

## Повторювані теги (списки)

Один елемент = один сегмент. Однаковий тег може повторюватись.

| Тег | К-сть полів | Порядок |
|-----|-------------|---------|
| `RM` | 5 | `slot`, `size`, `mhz`, `part`, `serial` |
| `G` | 1 | `name` |
| `D` | 6 | `model`, `serial`, `size`, `bus`, `media`, `smart` |
| `BAT` | 8 | `id`, `status`, `capacity`, `health`, `mfr`, `model`, `serial`, `cycles` |

Приклад: три диски → `D/...|D/...|D/...`.

---

## Приклад рядка

```
V/1|T/12345|DT/2026-05-21T12:00:00Z|C/Intel Core i7|CT/6/12|R/16Gi|SM/Lenovo|PN/ThinkPad|SS/PF123|UUID/...|AT/PC-01|M/ASUS B550|MS/...|B/1.42|BD/01/15/2024|BF/AMI 1.42 rev5.17|TPM/2.0|RM/DIMM0/8GB/3200MT/KVR/SN1|G/Intel UHD|G/NVIDIA RTX|D/Samsung/SN/512G/nvme/ssd/PASSED|BAT/BAT0/Discharging/72/Good/Lenovo/...
```

---

## Приклад (Python)

```python
def parse_hardware_qr(qr_text: str) -> dict:
    qr_text = decode_qr_payload(qr_text)
    data = {
        "version": None,
        "ticket": None,
        "scanned_at": None,
        "cpu": None,
        "cpu_cores": None,
        "cpu_threads": None,
        "ram_total": None,
        "system_manufacturer": None,
        "product_name": None,
        "system_serial": None,
        "uuid": None,
        "asset_tag": None,
        "motherboard": None,
        "motherboard_serial": None,
        "bios": None,
        "bios_date": None,
        "bios_full": None,
        "tpm": None,
        "ram_modules": [],
        "gpus": [],
        "disks": [],
        "batteries": [],
    }

    for seg in qr_text.split("|"):
        parts = seg.split("/")
        if not parts:
            continue
        tag, *fields = parts

        if tag == "V":
            data["version"] = fields[0] if fields else None
        elif tag == "T":
            data["ticket"] = fields[0] if fields else None
        elif tag == "DT":
            data["scanned_at"] = fields[0] if fields else None
        elif tag == "C":
            data["cpu"] = fields[0] if fields else None
        elif tag == "CT" and len(fields) >= 2:
            data["cpu_cores"], data["cpu_threads"] = fields[0], fields[1]
        elif tag == "R":
            data["ram_total"] = fields[0] if fields else None
        elif tag == "SM":
            data["system_manufacturer"] = fields[0] if fields else None
        elif tag == "PN":
            data["product_name"] = fields[0] if fields else None
        elif tag == "SS":
            data["system_serial"] = fields[0] if fields else None
        elif tag == "UUID":
            data["uuid"] = fields[0] if fields else None
        elif tag == "AT":
            data["asset_tag"] = fields[0] if fields else None
        elif tag == "M":
            data["motherboard"] = fields[0] if fields else None
        elif tag == "MS":
            data["motherboard_serial"] = fields[0] if fields else None
        elif tag == "B":
            data["bios"] = fields[0] if fields else None
        elif tag == "BD":
            data["bios_date"] = fields[0] if fields else None
        elif tag == "BF":
            data["bios_full"] = fields[0] if fields else None
        elif tag == "TPM":
            data["tpm"] = fields[0] if fields else None
        elif tag == "RM" and len(fields) >= 5:
            data["ram_modules"].append({
                "slot": fields[0], "size": fields[1], "mhz": fields[2],
                "part": fields[3], "serial": fields[4],
            })
        elif tag == "G" and fields:
            data["gpus"].append(fields[0])
        elif tag == "D" and len(fields) >= 6:
            data["disks"].append({
                "model": fields[0], "serial": fields[1], "size": fields[2],
                "bus": fields[3], "media": fields[4], "smart": fields[5],
            })
        elif tag == "BAT" and len(fields) >= 8:
            data["batteries"].append({
                "id": fields[0], "status": fields[1], "capacity": fields[2],
                "health": fields[3], "mfr": fields[4], "model": fields[5],
                "serial": fields[6], "cycles": fields[7],
            })

    if data["version"] != "1":
        raise ValueError(f"Unsupported schema version: {data['version']}")

    return data
```

---

## Рекомендації

1. **`V != 1`** — не парсити як v1; показати помилку або окремий обробник.
2. **Відсутні `RM` / `G` / `D` / `BAT`** — означає «не знайдено», не помилку парсера.
3. **Плейсхолдери** — `UNKNOWN_*`, `unk`, `NOSMART` трактуйте як «невідомо».
4. **Невідомі теги** — ігноруйте (forward compatibility).
5. **Старий формат** (`T:123|C:...|RM:a:b@c`) — не підтримується; лише v1 з `/` та `|`.
6. **Обгортка `V/1|Z/`** — завжди розпаковуйте gzip+base64 перед `split("|")` по v1.

---

Джерело генерації: `scripts/hardware_qr.sh`
