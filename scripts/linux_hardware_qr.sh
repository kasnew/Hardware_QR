#!/bin/sh

ticket=""
png_file="hardware-qr.png"
payload_file="hardware-qr-payload.txt"
show_terminal=1

usage() {
    echo "Usage: $0 [--ticket TICKET] [--png FILE] [--payload FILE] [--no-terminal]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--ticket)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            ticket="$2"
            shift 2
            ;;
        --png)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            png_file="$2"
            shift 2
            ;;
        --payload)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            payload_file="$2"
            shift 2
            ;;
        --no-terminal)
            show_terminal=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 2
            ;;
    esac
done

trim() {
    awk '{$1=$1};1'
}

bad_value() {
    case "$1" in
        ""|"Not Specified"|"Not Specified By O.E.M."|"To Be Filled By O.E.M."|"Default string"|"Unknown"|"None")
            return 0
            ;;
    esac
    return 1
}

clean_or() {
    _value=$(printf '%s' "$1" | tr -d '\000-\037\177' | trim)
    if bad_value "$_value"; then
        printf '%s' "$2"
    else
        printf '%s' "$_value"
    fi
}

read_file_value() {
    if [ -r "$1" ]; then
        cat "$1" 2>/dev/null | tr -d '\n' | trim
    fi
}

qr_enc() {
    printf '%s' "$1" | tr '/|' '-' | tr -d '\000-\037\177' | trim
}

qr_add() {
    _tag=$(qr_enc "$1")
    shift
    _seg="$_tag"
    for _v in "$@"; do
        _seg="${_seg}/$(qr_enc "$_v")"
    done
    if [ -z "$output" ]; then
        output="$_seg"
    else
        output="${output}|${_seg}"
    fi
}

qr_add_base() {
    _tag=$(qr_enc "$1")
    shift
    _seg="$_tag"
    for _v in "$@"; do
        _seg="${_seg}/$(qr_enc "$_v")"
    done
    if [ -z "$base_output" ]; then
        base_output="$_seg"
    else
        base_output="${base_output}|${_seg}"
    fi
}

qr_append_base_segment() {
    [ -n "$1" ] || return
    if [ -z "$base_output" ]; then
        base_output="$1"
    else
        base_output="${base_output}|${1}"
    fi
}

build_qr_payload() {
    output=""
    qr_add V 1
    qr_add T "$ticket"
    [ -n "$base_output" ] && output="${output}|${base_output}"

    qr_b64=$(printf '%s' "$output" | gzip -9c 2>/dev/null | base64 2>/dev/null | tr -d '\n')
    qr_wrapped="V/1|Z/${qr_b64}"
    if [ -n "$qr_b64" ] && [ "${#qr_wrapped}" -lt "${#output}" ]; then
        qr_payload="$qr_wrapped"
        qr_payload_mode="gzip+base64"
    else
        qr_payload="$output"
        qr_payload_mode="raw"
    fi
}

if [ -z "$ticket" ]; then
    printf "Введіть номер заявки: "
    IFS= read -r ticket
fi
[ -n "$ticket" ] || ticket="NO_TICKET"

scan_dt=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
[ -n "$scan_dt" ] || scan_dt="UNKNOWN_DT"

cpu=""
if command -v lscpu >/dev/null 2>&1; then
    cpu=$(lscpu | awk -F: '/Model name/ {sub(/^[ \t]+/, "", $2); print $2; exit}')
fi
[ -n "$cpu" ] || cpu=$(awk -F: '/model name/ {sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
cpu=$(clean_or "$cpu" "UNKNOWN_CPU")

cpu_ct="UNKNOWN_CT"
if command -v lscpu >/dev/null 2>&1; then
    cpu_ct=$(lscpu 2>/dev/null | awk -F: '
        /^CPU\(s\):/              { gsub(/^[ \t]+/, "", $2); threads = $2 }
        /^Core\(s\) per socket:/ { gsub(/^[ \t]+/, "", $2); cps = $2 }
        /^Socket\(s\):/           { gsub(/^[ \t]+/, "", $2); socks = $2 }
        END {
            if (threads == "") { print "UNKNOWN_CT"; exit }
            cores = threads
            if (cps != "" && socks != "" && cps + 0 == cps && socks + 0 == socks)
                cores = cps * socks
            gsub(/ /, "", cores)
            gsub(/ /, "", threads)
            print cores "/" threads
        }')
elif [ -r /proc/cpuinfo ]; then
    threads=$(awk '/^processor[ \t]*:/ {c++} END {print c+0}' /proc/cpuinfo)
    [ "$threads" -gt 0 ] && cpu_ct="${threads}/${threads}"
fi
[ -n "$cpu_ct" ] || cpu_ct="UNKNOWN_CT"
cpu_cores=${cpu_ct%/*}
cpu_threads=${cpu_ct#*/}

ram=""
if command -v free >/dev/null 2>&1; then
    ram=$(free -h | awk '/^Mem:/ {print $2; exit}')
fi
if [ -z "$ram" ] && [ -r /proc/meminfo ]; then
    ram=$(awk '/^MemTotal:/ {printf "%dGi", int(($2 + 1048575) / 1048576); exit}' /proc/meminfo)
fi
ram=$(clean_or "$ram" "UNKNOWN_RAM")

sys_manufacturer=$(clean_or "$(read_file_value /sys/class/dmi/id/sys_vendor)" "UNKNOWN_SM")
product_name=$(clean_or "$(read_file_value /sys/class/dmi/id/product_name)" "UNKNOWN_PN")
system_serial=$(clean_or "$(read_file_value /sys/class/dmi/id/product_serial)" "UNKNOWN_SS")
system_uuid=$(clean_or "$(read_file_value /sys/class/dmi/id/product_uuid)" "UNKNOWN_UUID")
asset_tag=$(clean_or "$(read_file_value /sys/class/dmi/id/chassis_asset_tag)" "UNKNOWN_AT")

mb_vendor=$(clean_or "$(read_file_value /sys/class/dmi/id/board_vendor)" "")
mb_model=$(clean_or "$(read_file_value /sys/class/dmi/id/board_name)" "")
mb_vendor_model=$(printf '%s %s' "$mb_vendor" "$mb_model" | trim)
[ -n "$mb_vendor_model" ] || mb_vendor_model="UNKNOWN_MB"
mb_serial=$(clean_or "$(read_file_value /sys/class/dmi/id/board_serial)" "UNKNOWN_MB_SN")

bios=$(clean_or "$(read_file_value /sys/class/dmi/id/bios_version)" "UNKNOWN_BIOS")
bios_date=$(clean_or "$(read_file_value /sys/class/dmi/id/bios_date)" "UNKNOWN_BD")
bios_vendor=$(clean_or "$(read_file_value /sys/class/dmi/id/bios_vendor)" "")
bios_full=$(clean_or "$(printf '%s %s' "$bios_vendor" "$bios" | trim)" "UNKNOWN_BF")

tpm_status="none"
if [ -r /sys/class/tpm/tpm0/tpm_version_major ]; then
    tpm_maj=$(read_file_value /sys/class/tpm/tpm0/tpm_version_major)
    tpm_min=$(read_file_value /sys/class/tpm/tpm0/tpm_version_minor)
    if [ -n "$tpm_maj" ] && [ -n "$tpm_min" ]; then
        tpm_status="${tpm_maj}.${tpm_min}"
    else
        tpm_status="present"
    fi
elif [ -d /sys/class/tpm/tpm0 ]; then
    tpm_status="present"
fi

ram_modules=""
if command -v dmidecode >/dev/null 2>&1; then
    ram_modules=$(dmidecode -t 17 2>/dev/null | awk '
    BEGIN { first = 1 }
    function sanitize(s) {
        gsub(/\|/, "-", s)
        gsub(/\//, "-", s)
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
    }
    function bad(v) {
        return v == "" || v == "Not Specified" || v == "Unknown" || v == "None"
    }
    function flush() {
        if (!has_module) return
        if (size == "" || size ~ /^0 / || size == "0 MB" || size == "0 GB") return
        slot = (bad(slot) ? "UNKNOWN_SLOT" : sanitize(slot))
        part = (bad(part) ? "UNKNOWN_PN" : sanitize(part))
        sn = (bad(sn) ? "UNKNOWN_SN" : sanitize(sn))
        mt = (cfgspeed != "" ? cfgspeed : speed)
        if (mt == "" || mt == "Unknown") mt = "UNK"; else mt = mt "MT"
        if (!first) printf "|"
        printf "RM/%s/%s/%s/%s/%s", slot, sanitize(size), mt, part, sn
        first = 0
    }
    function reset() {
        slot = ""; size = ""; speed = ""; cfgspeed = ""; part = ""; sn = ""; has_module = 0
    }
    /^Memory Device$/ { flush(); reset(); next }
    /^[ \t]*Locator:/ { sub(/^[ \t]*Locator:[ \t]*/, ""); slot = $0 }
    /^[ \t]*Size:/ {
        if ($0 ~ /No Module Installed/ || $0 ~ /Size:[ \t]*0 /) { has_module = 0; next }
        sub(/^[ \t]*Size:[ \t]*/, ""); size = $0; has_module = 1
    }
    /^[ \t]*Speed:/ { if (match($0, /[0-9]+/)) speed = substr($0, RSTART, RLENGTH) }
    /^[ \t]*Configured Memory Speed:/ { if (match($0, /[0-9]+/)) cfgspeed = substr($0, RSTART, RLENGTH) }
    /^[ \t]*Part Number:/ { sub(/^[ \t]*Part Number:[ \t]*/, ""); part = $0 }
    /^[ \t]*Serial Number:/ { sub(/^[ \t]*Serial Number:[ \t]*/, ""); sn = $0 }
    END { flush() }')
fi

gpus=""
if command -v lspci >/dev/null 2>&1; then
    gpus=$(lspci 2>/dev/null | awk -F': ' '
        /VGA compatible controller|3D controller|Display controller/ {
            gsub(/\|/, "-", $2)
            gsub(/\//, "-", $2)
            gsub(/:/, "-", $2)
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            if ($2 != "") print $2
        }')
fi

read_ps() {
    _f="$1/$2"
    if [ -r "$_f" ]; then
        cat "$_f" 2>/dev/null | tr -d '\n' | trim
    fi
}

disk_smart_health() {
    if ! command -v smartctl >/dev/null 2>&1; then
        echo "NOSMART"
        return
    fi
    smartctl -H -n standby,q "/dev/$1" 2>/dev/null | awk '
        /self-assessment test result:[ \t]*PASSED/ { print "PASSED"; found = 1; exit }
        /self-assessment test result:[ \t]*FAILED/ { print "FAILED"; found = 1; exit }
        /SMART Health Status:[ \t]*OK/ { print "PASSED"; found = 1; exit }
        /SMART Health Status:[ \t]*FAILED/ { print "FAILED"; found = 1; exit }
        END { if (!found) print "UNKNOWN" }'
}

output=""
base_output=""
qr_add_base DT "$scan_dt"
qr_add_base C "$cpu"
qr_add_base CT "$cpu_cores" "$cpu_threads"
qr_add_base R "$ram"
qr_add_base SM "$sys_manufacturer"
qr_add_base PN "$product_name"
qr_add_base SS "$system_serial"
qr_add_base UUID "$system_uuid"
qr_add_base AT "$asset_tag"
qr_add_base M "$mb_vendor_model"
qr_add_base MS "$mb_serial"
qr_add_base B "$bios"
qr_add_base BD "$bios_date"
qr_add_base BF "$bios_full"
qr_add_base TPM "$tpm_status"

if [ -n "$ram_modules" ]; then
    old_ifs=$IFS
    IFS='|'
    for rm_seg in $ram_modules; do
        qr_append_base_segment "$rm_seg"
    done
    IFS=$old_ifs
fi

if [ -n "$gpus" ]; then
    while IFS= read -r gpu; do
        [ -n "$gpu" ] && qr_add_base G "$gpu"
    done <<EOF
$gpus
EOF
fi

battery_count=0
for ps in /sys/class/power_supply/*; do
    [ -d "$ps" ] || continue
    [ "$(read_ps "$ps" type)" = "Battery" ] || continue
    bat_name=$(basename "$ps")
    bat_status=$(clean_or "$(read_ps "$ps" status)" "unk")
    bat_capacity=$(clean_or "$(read_ps "$ps" capacity)" "unk")
    bat_health=$(clean_or "$(read_ps "$ps" health)" "unk")
    bat_manufacturer=$(clean_or "$(read_ps "$ps" manufacturer)" "unk")
    bat_model=$(clean_or "$(read_ps "$ps" model_name)" "unk")
    [ "$bat_model" != "unk" ] || bat_model=$(clean_or "$(read_ps "$ps" model)" "unk")
    bat_serial=$(clean_or "$(read_ps "$ps" serial_number)" "unk")
    bat_cycles=$(clean_or "$(read_ps "$ps" cycle_count)" "unk")
    qr_add_base BAT "$bat_name" "$bat_status" "$bat_capacity" "$bat_health" "$bat_manufacturer" "$bat_model" "$bat_serial" "$bat_cycles"
    battery_count=$((battery_count + 1))
done

disk_count=0
if command -v lsblk >/dev/null 2>&1; then
    for name in $(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }'); do
        line=$(lsblk -d -n -o MODEL,SERIAL,SIZE,ROTA,TRAN -P "/dev/$name" 2>/dev/null | head -n1)
        [ -n "$line" ] || continue
        model=$(printf '%s\n' "$line" | awk 'match($0, /MODEL="[^"]*"/) {v=substr($0,RSTART+7,RLENGTH-8); print v}')
        serial=$(printf '%s\n' "$line" | awk 'match($0, /SERIAL="[^"]*"/) {v=substr($0,RSTART+8,RLENGTH-9); print v}')
        size=$(printf '%s\n' "$line" | awk 'match($0, /SIZE="[^"]*"/) {v=substr($0,RSTART+6,RLENGTH-7); print v}')
        rota=$(printf '%s\n' "$line" | awk 'match($0, /ROTA="[^"]*"/) {v=substr($0,RSTART+6,RLENGTH-7); print v}')
        tran=$(printf '%s\n' "$line" | awk 'match($0, /TRAN="[^"]*"/) {v=substr($0,RSTART+6,RLENGTH-7); print v}')
        model=$(clean_or "$model" "UNKNOWN_MODEL")
        serial=$(clean_or "$serial" "UNKNOWN_SERIAL")
        size=$(clean_or "$size" "UNKNOWN_SIZE")
        tran=$(clean_or "$(printf '%s' "$tran" | tr '[:upper:]' '[:lower:]')" "unk")
        if [ "$rota" = "0" ]; then media="ssd"; elif [ "$rota" = "1" ]; then media="hdd"; else media="unk"; fi
        smart=$(disk_smart_health "$name")
        qr_add_base D "$model" "$serial" "$size" "$tran" "$media" "$smart"
        disk_count=$((disk_count + 1))
    done
fi

build_qr_payload

clear 2>/dev/null || true
echo "--- Зібрані дані про залізо ---"
echo "Заявка     : $ticket"
echo "Скановано  : $scan_dt"
echo "CPU        : $cpu ($cpu_ct ядер/потоків)"
echo "ОЗП        : $ram"
if [ -n "$ram_modules" ]; then
    printf '%s\n' "$ram_modules" | tr '|' '\n' | sed 's/^RM\//  Планка ОЗП  : /' | tr '/' ' '
else
    echo "  Планка ОЗП  : (недоступно)"
fi
echo "Система    : $sys_manufacturer $product_name (SN: $system_serial)"
echo "Інв. №     : $asset_tag"
echo "UUID       : $system_uuid"
echo "Мат. плата : $mb_vendor_model (SN: $mb_serial)"
echo "BIOS       : $bios ($bios_date)"
echo "BIOS повн. : $bios_full"
echo "TPM        : $tpm_status"
if [ -n "$gpus" ]; then
    printf '%s\n' "$gpus" | sed 's/^/  GPU        : /'
else
    echo "  GPU        : (не виявлено)"
fi
if [ "$battery_count" -gt 0 ]; then
    printf '%s\n' "$output" | tr '|' '\n' | grep '^BAT/' | sed 's/^BAT\//  Батарея    : /' | tr '/' ' '
else
    echo "  Батарея    : (немає)"
fi
if [ "$disk_count" -gt 0 ]; then
    printf '%s\n' "$output" | tr '|' '\n' | grep '^D/' | sed 's/^D\//  Диск       : /' | tr '/' ' '
else
    echo "  Диск       : (немає)"
fi
case "$qr_payload_mode" in
    gzip+base64) _payload_lbl="стиснуто" ;;
    raw) _payload_lbl="без стиснення" ;;
    *) _payload_lbl="$qr_payload_mode" ;;
esac
echo "Схема QR   : v1 (${_payload_lbl})"
echo "-------------------------------"
echo ""
printf "Натисніть Enter для генерації QR-коду..."
IFS= read -r _dummy

printf '%s' "$qr_payload" > "$payload_file"
echo ""
echo "Файл даних  : $payload_file"

if command -v qrencode >/dev/null 2>&1; then
    if qrencode -o "$png_file" -s 8 -m 4 -l L "$qr_payload"; then
        echo "QR-зображ.  : $png_file"
    else
        echo "QR-зображ.  : не вдалося створити $png_file"
    fi
    if [ "$show_terminal" -eq 1 ]; then
        echo ""
        echo "Скануйте QR-код:"
        echo "=============================="
        printf '%s' "$qr_payload" | qrencode -t UTF8 -l L -m 1 2>/dev/null || \
            printf '%s' "$qr_payload" | qrencode -t ANSIUTF8 -l L -m 1
        echo "=============================="
    fi
else
    echo "qrencode не встановлено. Встановіть для генерації QR."
    echo "Debian/Ubuntu: sudo apt install qrencode"
    echo "Arch/Manjaro : sudo pacman -S qrencode"
    echo "Fedora       : sudo dnf install qrencode"
fi
