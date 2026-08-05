#!/bin/sh
# /usr/local/bin/hardware_qr.sh
#
# Unified QR schema v1 (for parent-app parsing):
#   - Segment separator: |
#   - Field separator:   /
#   - Segment format:    TAG/field1/field2/...
#   - First segment:     V/1
#   - Repeating tags:    RM, G, D, BAT (one segment per item)
#
# Tag reference (field order):
#   V/1  T/ticket  DT/iso-time  C/cpu  CT/cores/threads  R/total-ram
#   SM/mfr  PN/product  SS/serial  UUID/id  AT/asset-tag
#   M/board  MS/board-sn  B/bios  BD/bios-date  BF/bios-full  TPM/status
#   RM/slot/size/mhz/part/serial
#   G/gpu-name
#   D/model/serial/size/bus/media/smart
#   BAT/id/status/capacity/health/mfr/model/serial/cycles
#
# QR on screen uses compressed wrapper (smaller matrix):
#   V/1|Z/<base64(gzip(v1 payload))>
# Parent app: if text starts with "V/1|Z/", gunzip+base64 decode, then parse v1.

# Console fonts: large → small. Smaller font = more cells = QR more likely to fit.
# Used as terminal "scale" when fbi/framebuffer path is unavailable (common on AMD Renoir).
# BIOS/Legacy: never drop to 8x8 — UTF8 half-block QR becomes unreadable on vesafb.
qr_is_uefi() {
    [ -d /sys/firmware/efi ]
}

if qr_is_uefi; then
    qr_fonts="LatArCyrHeb-19 LatArCyrHeb-16 LatArCyrHeb-14 Cyr_a8x16 UniCyr_8x16 Cyr_a8x14 UniCyr_8x14 Cyr_a8x8 UniCyr_8x8 LatArCyrHeb-08"
else
    qr_fonts="LatArCyrHeb-16 LatArCyrHeb-14 Cyr_a8x16 UniCyr_8x16 Cyr_a8x14 UniCyr_8x14"
fi
qr_font_idx=-1
QR_TERM_RESERVED=15
qr_term_margin=1

qr_set_font_by_name() {
    command -v setfont >/dev/null 2>&1 || return 1
    _name="$1"
    _dir=/usr/share/kbd/consolefonts
    [ -d "$_dir" ] || return 1
    for _f in \
        "$_dir/$_name.psfu.gz" \
        "$_dir/$_name.psf.gz" \
        "$_dir/$_name.gz" \
        "$_dir/$_name"; do
        if [ -f "$_f" ]; then
            setfont "$_f" 2>/dev/null && return 0
        fi
    done
    return 1
}

qr_set_console_font() {
    for _name in LatArCyrHeb-16 UniCyr_8x16 Cyr_a8x16 LatArCyrHeb-14; do
        qr_set_font_by_name "$_name" && return 0
    done
    return 0
}

qr_apply_font_idx() {
    set -- $qr_fonts
    _count=$#
    [ "$_count" -gt 0 ] || return 1
    if [ "$qr_font_idx" -lt 0 ]; then
        qr_font_idx=1
    fi
    if [ "$qr_font_idx" -ge "$_count" ]; then
        qr_font_idx=$((_count - 1))
    fi
    _i=0
    for _name in $qr_fonts; do
        if [ "$_i" -eq "$qr_font_idx" ]; then
            qr_set_font_by_name "$_name"
            return $?
        fi
        _i=$((_i + 1))
    done
    return 1
}

qr_font_scale_adjust() {
    _delta="$1"
    set -- $qr_fonts
    _count=$#
    [ "$_count" -gt 0 ] || return 1
    if [ "$qr_font_idx" -lt 0 ]; then
        qr_font_idx=1
    fi
    qr_font_idx=$((qr_font_idx + _delta))
    if [ "$qr_font_idx" -lt 0 ]; then
        qr_font_idx=0
    fi
    if [ "$qr_font_idx" -ge "$_count" ]; then
        qr_font_idx=$((_count - 1))
    fi
    qr_apply_font_idx
}

qr_set_console_font

clear
echo "====================================="
echo "   УТИЛІТА ЗБОРУ ДАНИХ ЗАЛІЗА       "
echo "====================================="
echo ""
printf "Введіть номер заявки: "
read ticket
if [ -z "$ticket" ]; then
    ticket="NO_TICKET"
fi

# Gather CPU
cpu=$(lscpu | awk -F: '/Model name/ {sub(/^[ \t]+/, "", $2); print $2}')
if [ -z "$cpu" ]; then cpu="UNKNOWN_CPU"; fi

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
if [ -z "$cpu_ct" ]; then cpu_ct="UNKNOWN_CT"; fi

# Scan timestamp (UTC)
scan_dt=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
if [ -z "$scan_dt" ]; then scan_dt="UNKNOWN_DT"; fi

# System identification (chassis / product)
product_name=""
system_serial=""
system_uuid=""
if [ -r /sys/class/dmi/id/product_name ]; then
    product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null | awk '{$1=$1};1')
fi
if [ -r /sys/class/dmi/id/product_serial ]; then
    system_serial=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | awk '{$1=$1};1')
fi
if [ -r /sys/class/dmi/id/product_uuid ]; then
    system_uuid=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | awk '{$1=$1};1')
fi
if [ -z "$product_name" ]; then product_name="UNKNOWN_PN"; fi
if [ -z "$system_serial" ]; then system_serial="UNKNOWN_SS"; fi
if [ -z "$system_uuid" ]; then system_uuid="UNKNOWN_UUID"; fi

# DMI extras: system vendor, asset tag, full BIOS, TPM (types 0/1/3/43)
sys_manufacturer="UNKNOWN_SM"
asset_tag="UNKNOWN_AT"
bios_full="UNKNOWN_BF"
tpm_status="none"
if command -v dmidecode >/dev/null 2>&1; then
    eval "$(dmidecode -t bios -t system -t chassis -t 43 2>/dev/null | awk '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function bad(v) {
    return v == "" || v == "Not Specified" || v == "Not Specified By O.E.M." \
        || v == "To Be Filled By O.E.M." || v == "Default string" || v == "Unknown"
}
function q(s) { gsub(/'"'"'/, "'\''", s); return s }
function set(k, v) { if (!bad(v)) print k "='"'"'" q(trim(v)) "'"'"'" }
BEGIN { ctx = "" }
/^BIOS Information$/       { ctx = "bios"; next }
/^System Information$/       { ctx = "sys"; next }
/^Chassis Information$/      { ctx = "chassis"; next }
/^TPM Device$/               { ctx = "tpm"; tpm_found = 1; next }
/^[ \t]*Vendor:/ && ctx == "bios" {
    sub(/^[ \t]*Vendor:[ \t]*/, ""); bios_vendor = $0; next
}
/^[ \t]*Version:/ && ctx == "bios" {
    sub(/^[ \t]*Version:[ \t]*/, ""); bios_ver = $0; next
}
/^[ \t]*Release Date:/ && ctx == "bios" {
    sub(/^[ \t]*Release Date:[ \t]*/, ""); bios_rel = $0; next
}
/^[ \t]*BIOS Revision:/ && ctx == "bios" {
    sub(/^[ \t]*BIOS Revision:[ \t]*/, ""); bios_rev = $0; next
}
/^[ \t]*Firmware Revision:/ && ctx == "bios" {
    sub(/^[ \t]*Firmware Revision:[ \t]*/, ""); fw_rev = $0; next
}
/^[ \t]*Manufacturer:/ && ctx == "sys" {
    sub(/^[ \t]*Manufacturer:[ \t]*/, ""); sys_mfr = $0; next
}
/^[ \t]*Asset Tag:/ && ctx == "sys" {
    sub(/^[ \t]*Asset Tag:[ \t]*/, ""); asset_sys = $0; next
}
/^[ \t]*Asset Tag:/ && ctx == "chassis" {
    sub(/^[ \t]*Asset Tag:[ \t]*/, ""); asset_chassis = $0; next
}
/^[ \t]*Specification Version:/ && ctx == "tpm" {
    sub(/^[ \t]*Specification Version:[ \t]*/, ""); tpm_spec = $0; next
}
END {
    set("sys_manufacturer", sys_mfr)
    asset = asset_sys
    if (bad(asset)) asset = asset_chassis
    set("asset_tag", asset)
    if (!bad(bios_ver)) set("bios", bios_ver)
    if (!bad(bios_rel)) set("bios_date", bios_rel)
    bf = bios_vendor
    if (!bad(bios_ver)) bf = (bf == "" ? bios_ver : bf " " bios_ver)
    if (!bad(bios_rev)) bf = bf " rev" bios_rev
    if (!bad(fw_rev)) bf = bf " fw" fw_rev
    set("bios_full", bf)
    if (!bad(tpm_spec)) {
        print "tpm_status=" tpm_spec
    } else if (tpm_found) {
        print "tpm_status=present"
    }
}
')"
fi
if [ -z "$sys_manufacturer" ]; then sys_manufacturer="UNKNOWN_SM"; fi
if [ -z "$asset_tag" ]; then asset_tag="UNKNOWN_AT"; fi
if [ -z "$bios_full" ]; then bios_full="UNKNOWN_BF"; fi

if [ -r /sys/class/tpm/tpm0/tpm_version_major ]; then
    tpm_maj=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null)
    tpm_min=$(cat /sys/class/tpm/tpm0/tpm_version_minor 2>/dev/null)
    if [ -n "$tpm_maj" ] && [ -n "$tpm_min" ]; then
        tpm_status="${tpm_maj}.${tpm_min}"
    fi
fi

# Gather RAM (total + per-DIMM via SMBIOS)
ram=$(free -h | awk '/^Mem:/ {print $2}')
if [ -z "$ram" ]; then ram="UNKNOWN_RAM"; fi

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

function flush() {
    if (!has_module) return
    if (size == "" || size ~ /^0 / || size == "0 MB" || size == "0 GB") return

    slot = (slot == "" ? "UNKNOWN_SLOT" : sanitize(slot))
    part = (part == "" || part == "Not Specified" || part == "Unknown" ? "UNKNOWN_PN" : sanitize(part))
    sn = (sn == "" || sn == "Not Specified" || sn == "Unknown" ? "UNKNOWN_SN" : sanitize(sn))
    size = sanitize(size)
    mt = (cfgspeed != "" ? cfgspeed : speed)
    if (mt == "" || mt == "Unknown") mt = "UNK"
    else mt = mt "MT"

    if (!first) printf "|"
    printf "RM/%s/%s/%s/%s/%s", slot, size, mt, part, sn
    first = 0
}

function reset() {
    slot = ""; size = ""; speed = ""; cfgspeed = ""; part = ""; sn = ""
    has_module = 0
}

/^Memory Device$/ {
    flush()
    reset()
    next
}

/^[ \t]*Locator:/ {
    sub(/^[ \t]*Locator:[ \t]*/, "")
    slot = $0
}

/^[ \t]*Size:/ {
    if ($0 ~ /No Module Installed/ || $0 ~ /Size:[ \t]*0 /) {
        has_module = 0
        next
    }
    sub(/^[ \t]*Size:[ \t]*/, "")
    size = $0
    has_module = 1
}

/^[ \t]*Speed:/ {
    if (match($0, /[0-9]+/)) speed = substr($0, RSTART, RLENGTH)
}

/^[ \t]*Configured Memory Speed:/ {
    if (match($0, /[0-9]+/)) cfgspeed = substr($0, RSTART, RLENGTH)
}

/^[ \t]*Part Number:/ {
    sub(/^[ \t]*Part Number:[ \t]*/, "")
    part = $0
}

/^[ \t]*Serial Number:/ {
    sub(/^[ \t]*Serial Number:[ \t]*/, "")
    sn = $0
}

END {
    flush()
}
')
fi

# Motherboard Vendor & Model
mb_vendor=""
if [ -r /sys/class/dmi/id/board_vendor ]; then
    mb_vendor=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null)
fi
mb_model=""
if [ -r /sys/class/dmi/id/board_name ]; then
    mb_model=$(cat /sys/class/dmi/id/board_name 2>/dev/null)
fi
mb_vendor_model="${mb_vendor} ${mb_model}"
mb_vendor_model=$(echo "$mb_vendor_model" | awk '{$1=$1};1')
if [ -z "$mb_vendor_model" ]; then mb_vendor_model="UNKNOWN_MB"; fi

# Motherboard Serial
mb_serial=""
if [ -r /sys/class/dmi/id/board_serial ]; then
    mb_serial=$(cat /sys/class/dmi/id/board_serial 2>/dev/null)
fi
if [ -z "$mb_serial" ]; then mb_serial="UNKNOWN_MB_SN"; fi

# BIOS Version & release date (sysfs fallback; dmidecode type 0 preferred when set above)
if [ -z "$bios" ] && [ -r /sys/class/dmi/id/bios_version ]; then
    bios=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
fi
if [ -z "$bios" ]; then bios="UNKNOWN_BIOS"; fi

if [ -z "$bios_date" ] && [ -r /sys/class/dmi/id/bios_date ]; then
    bios_date=$(cat /sys/class/dmi/id/bios_date 2>/dev/null | awk '{$1=$1};1')
fi
if [ -z "$bios_date" ]; then bios_date="UNKNOWN_BD"; fi

# All GPUs (VGA / 3D / Display controllers) — one name per line for output loop
gpus=$(lspci 2>/dev/null | awk -F': ' '
/VGA compatible controller|3D controller|Display controller/ {
    gsub(/\|/, "-", $2)
    gsub(/\//, "-", $2)
    gsub(/:/, "-", $2)
    gsub(/^[ \t]+|[ \t]+$/, "", $2)
    if ($2 != "") print $2
}')
# Batteries (sysfs power_supply)

read_ps() {
    f="$1/$2"
    if [ -r "$f" ]; then
        cat "$f" 2>/dev/null | tr -d '\n' | awk '{$1=$1};1'
    fi
}

battery_count=0

# Storage Drives (model:serial:size:iface:media:smart)
disk_smart_health() {
    if ! command -v smartctl >/dev/null 2>&1; then
        echo "NOSMART"
        return
    fi
    smartctl -H -n standby,q "/dev/$1" 2>/dev/null | awk '
        /self-assessment test result:[ \t]*PASSED/ { print "PASSED"; exit }
        /self-assessment test result:[ \t]*FAILED/ { print "FAILED"; exit }
        /SMART Health Status:[ \t]*OK/ { print "PASSED"; exit }
        /SMART Health Status:[ \t]*FAILED/ { print "FAILED"; exit }
        END { print "UNKNOWN" }
    '
}

# --- Build unified QR payload (schema v1) ---
qr_enc() {
    printf '%s' "$1" | tr '/|' '-' | sed 's/[[:cntrl:]]//g' | awk '{$1=$1};1'
}

output=""
base_output=""
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
    _seg="$1"
    [ -n "$_seg" ] || return
    if [ -z "$base_output" ]; then
        base_output="$_seg"
    else
        base_output="${base_output}|${_seg}"
    fi
}

build_qr_payload() {
    output=""
    qr_add V 1
    qr_add T "$ticket"
    if [ -n "$base_output" ]; then
        output="${output}|${base_output}"
    fi

    # Prefer compressed wrapper whenever gzip/base64 work. Comparing string lengths
    # wrongly fell back to raw on some payloads and produced huge unreadable terminal QR.
    qr_b64=$(printf '%s' "$output" | gzip -9c 2>/dev/null | base64 -w 0 2>/dev/null)
    if [ -z "$qr_b64" ]; then
        qr_b64=$(printf '%s' "$output" | gzip -9c 2>/dev/null | base64 2>/dev/null | tr -d '\n')
    fi
    qr_wrapped="V/1|Z/${qr_b64}"
    if [ -n "$qr_b64" ]; then
        qr_payload="$qr_wrapped"
        qr_payload_mode="gzip+base64"
    else
        qr_payload="$output"
        qr_payload_mode="raw"
    fi
}

qr_add_base DT "$scan_dt"
qr_add_base C "$cpu"
cpu_cores=${cpu_ct%/*}
cpu_threads=${cpu_ct#*/}
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
    _ifs=$IFS
    IFS='|'
    for _rm in $ram_modules; do
        qr_append_base_segment "$_rm"
    done
    IFS=$_ifs
fi

if [ -n "$gpus" ]; then
    while IFS= read -r _gpu; do
        [ -n "$_gpu" ] || continue
        qr_add_base G "$_gpu"
    done <<EOF
$gpus
EOF
fi

_battery_count=0
for ps in /sys/class/power_supply/*; do
    [ -d "$ps" ] || continue
    [ "$(read_ps "$ps" type)" = "Battery" ] || continue

    bat_name=$(basename "$ps")
    bat_status=$(read_ps "$ps" status)
    bat_capacity=$(read_ps "$ps" capacity)
    bat_health=$(read_ps "$ps" health)
    bat_manufacturer=$(read_ps "$ps" manufacturer)
    bat_model=$(read_ps "$ps" model_name)
    [ -n "$bat_model" ] || bat_model=$(read_ps "$ps" model)
    bat_serial=$(read_ps "$ps" serial_number)
    bat_cycles=$(read_ps "$ps" cycle_count)

    [ -n "$bat_status" ] || bat_status="unk"
    [ -n "$bat_capacity" ] || bat_capacity="unk"
    [ -n "$bat_health" ] || bat_health="unk"
    [ -n "$bat_manufacturer" ] || bat_manufacturer="unk"
    [ -n "$bat_model" ] || bat_model="unk"
    [ -n "$bat_serial" ] || bat_serial="unk"
    [ -n "$bat_cycles" ] || bat_cycles="unk"

    qr_add_base BAT "$bat_name" "$bat_status" "$bat_capacity" "$bat_health" \
        "$bat_manufacturer" "$bat_model" "$bat_serial" "$bat_cycles"
    _battery_count=$((_battery_count + 1))
done
battery_count=$_battery_count

_disk_i=0
for name in $(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }'); do
    line=$(lsblk -d -n -o MODEL,SERIAL,SIZE,ROTA,TRAN -P "/dev/$name" 2>/dev/null | head -n1)
    [ -n "$line" ] || continue

    model=$(echo "$line" | awk '
        function v(l, k, p) {
            p = k "=\""
            if (match(l, p)) {
                x = substr(l, RSTART + RLENGTH)
                if (match(x, /^[^"]*/)) return substr(x, 1, RLENGTH)
            }
            return ""
        }
        { print v($0, "MODEL") }
    ')
    serial=$(echo "$line" | awk '
        function v(l, k, p) {
            p = k "=\""
            if (match(l, p)) {
                x = substr(l, RSTART + RLENGTH)
                if (match(x, /^[^"]*/)) return substr(x, 1, RLENGTH)
            }
            return ""
        }
        { print v($0, "SERIAL") }
    ')
    size=$(echo "$line" | awk '
        function v(l, k, p) {
            p = k "=\""
            if (match(l, p)) {
                x = substr(l, RSTART + RLENGTH)
                if (match(x, /^[^"]*/)) return substr(x, 1, RLENGTH)
            }
            return ""
        }
        { print v($0, "SIZE") }
    ')
    tran=$(echo "$line" | awk '
        function v(l, k, p) {
            p = k "=\""
            if (match(l, p)) {
                x = substr(l, RSTART + RLENGTH)
                if (match(x, /^[^"]*/)) return substr(x, 1, RLENGTH)
            }
            return ""
        }
        { print v($0, "TRAN") }
    ')
    rota=$(echo "$line" | awk '
        function v(l, k, p) {
            p = k "=\""
            if (match(l, p)) {
                x = substr(l, RSTART + RLENGTH)
                if (match(x, /^[^"]*/)) return substr(x, 1, RLENGTH)
            }
            return ""
        }
        { print v($0, "ROTA") }
    ')

    [ -n "$model" ] || model="UNKNOWN_MODEL"
    [ -n "$serial" ] || serial="UNKNOWN_SERIAL"
    [ -n "$size" ] || size="UNKNOWN_SIZE"
    if [ -z "$tran" ]; then tran="unk"; else tran=$(echo "$tran" | tr '[:upper:]' '[:lower:]'); fi
    if [ "$rota" = "0" ]; then media="ssd"
    elif [ "$rota" = "1" ]; then media="hdd"
    else media="unk"; fi

    smart=$(disk_smart_health "$name")
    qr_add_base D "$model" "$serial" "$size" "$tran" "$media" "$smart"
    _disk_i=$((_disk_i + 1))
done
disk_count=$_disk_i
build_qr_payload

qr_out() {
    _cols=$(stty size 2>/dev/null | awk '{ print $2 }')
    case "$_cols" in ''|*[!0-9]*) _cols=80 ;; esac
    if [ "$_cols" -lt 40 ]; then
        _cols=40
    fi
    # fold keeps summary readable when Legacy console width is wrong/narrow.
    if command -v fold >/dev/null 2>&1; then
        printf '%s\n' "$1" | fold -s -w "$_cols"
    else
        printf '%s\n' "$1"
    fi
}

clear
qr_out "--- Зібрані дані про залізо ---"
qr_out "Заявка     : $ticket"
qr_out "Скановано  : $scan_dt"
qr_out "CPU        : $cpu ($cpu_ct ядер/потоків)"
qr_out "ОЗП        : $ram"
if [ -n "$ram_modules" ]; then
    echo "$ram_modules" | tr '|' '\n' | sed 's/^RM\//  Планка ОЗП  : /' | tr '/' ' ' | while IFS= read -r _line; do
        qr_out "$_line"
    done
else
    qr_out "  Планка ОЗП  : (недоступно)"
fi
qr_out "Система    : $sys_manufacturer $product_name (SN: $system_serial)"
qr_out "Інв. №     : $asset_tag"
qr_out "UUID       : $system_uuid"
qr_out "Мат. плата : $mb_vendor_model (SN: $mb_serial)"
qr_out "BIOS       : $bios ($bios_date)"
qr_out "BIOS повн. : $bios_full"
qr_out "TPM        : $tpm_status"
if [ -n "$gpus" ]; then
    printf '%s\n' "$gpus" | sed 's/^/  GPU        : /' | while IFS= read -r _line; do
        qr_out "$_line"
    done
else
    qr_out "  GPU        : (не виявлено)"
fi
if [ "$battery_count" -gt 0 ]; then
    echo "$output" | tr '|' '\n' | grep '^BAT/' | sed 's/^BAT\//  Батарея    : /' | tr '/' ' ' | while IFS= read -r _line; do
        qr_out "$_line"
    done
else
    qr_out "  Батарея    : (немає)"
fi
if [ "$disk_count" -gt 0 ]; then
    echo "$output" | tr '|' '\n' | grep '^D/' | sed 's/^D\//  Диск       : /' | tr '/' ' ' | while IFS= read -r _line; do
        qr_out "$_line"
    done
else
    qr_out "  Диск       : (немає)"
fi
qr_out "Схема QR   : v1 (сегменти TAG/поле/... через |)"
if qr_is_uefi; then
    qr_out "Завантаження: UEFI"
else
    qr_out "Завантаження: Legacy BIOS (краще UEFI, якщо доступно)"
fi
qr_out "-------------------------------"
echo ""

echo "Натисніть Enter для генерації QR-коду..."
read dummy

qr_png_width() {
    file -b "$1" 2>/dev/null | sed -n 's/.*, \([0-9][0-9]*\) x [0-9][0-9]*.*/\1/p'
}

qr_png_height() {
    file -b "$1" 2>/dev/null | sed -n 's/.*, [0-9][0-9]* x \([0-9][0-9]*\).*/\1/p'
}

qr_fb_size() {
    _fw=1024
    _fh=768
    if [ -r /sys/class/graphics/fb0/virtual_size ]; then
        _fb_virtual=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | tr ',x' '  ')
        set -- $_fb_virtual
        _fw=$1
        _fh=$2
    fi
    if { [ -z "$_fw" ] || [ -z "$_fh" ] || [ "$_fw" = "0" ] || [ "$_fh" = "0" ]; } \
        && [ -r /sys/class/graphics/fb0/modes ]; then
        _fb_mode=$(sed -n '1s/.*:\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p' \
            /sys/class/graphics/fb0/modes 2>/dev/null)
        set -- $_fb_mode
        if [ -n "$1" ] && [ -n "$2" ]; then
            _fw=$1
            _fh=$2
        fi
    fi
    case "$_fw" in ''|*[!0-9]*) _fw=1024 ;; esac
    case "$_fh" in ''|*[!0-9]*) _fh=768 ;; esac
    echo "$_fw $_fh"
}

qr_fb_max_px() {
    set -- $(qr_fb_size)
    _fbw=$1
    _fbh=$2
    _min=$((_fbw < _fbh ? _fbw : _fbh))
    # Conservative fit: leave headroom so fbi/center never clips on HiDPI panels.
    _max=$((_min * 65 / 100))
    _floor=$((_min - 160))
    if [ "$_max" -gt "$_floor" ]; then
        _max=$_floor
    fi
    if [ "$_max" -lt 240 ]; then
        _max=$((_min - 40))
    fi
    if [ "$_max" -lt 160 ]; then
        _max=160
    fi
    echo "$_max"
}

qrencode_png() {
    _png="$1"
    _scale="$2"
    _data="$3"
    _inverted="$4"

    if [ "$_inverted" = "1" ]; then
        qrencode -o "$_png" -s "$_scale" -m 2 -l L \
            --foreground=FFFFFF --background=000000 "$_data" 2>/dev/null || \
            qrencode -o "$_png" -s "$_scale" -m 2 -l L "$_data" 2>/dev/null
    else
        qrencode -o "$_png" -s "$_scale" -m 2 -l L \
            --foreground=000000 --background=FFFFFF "$_data" 2>/dev/null || \
            qrencode -o "$_png" -s "$_scale" -m 2 -l L "$_data" 2>/dev/null
    fi
}

# QR display tuning (adjust on QR screen with =/-, 0, V)
qr_scale=0          # 0 = auto-fit; otherwise qrencode -s module size (fbi path)
qr_scale_auto=8
qr_scale_max=24
qr_res_modes=""
qr_res_idx=0
qr_res_current=""
qr_display_mode="term"   # fb | term — last successful path

qr_collect_available_modes() {
    _avail=""
    if [ -r /sys/class/graphics/fb0/modes ]; then
        _avail=$(sed -n 's/.*:\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1x\2/p' \
            /sys/class/graphics/fb0/modes 2>/dev/null)
    fi
    for _conn in /sys/class/drm/card*-*-*; do
        [ -e "$_conn/status" ] || continue
        [ "$(cat "$_conn/status" 2>/dev/null)" = "connected" ] || continue
        [ -r "$_conn/modes" ] || continue
        _avail="$_avail $(awk '{ print $1 }' "$_conn/modes" 2>/dev/null)"
    done
    echo "$_avail" | tr ' ' '\n' | sed '/^$/d' | sort -u
}

qr_list_res_modes() {
    _avail=$(qr_collect_available_modes)
    _result=""
    # Lower modes first — better QR fit on Vivobook/Renoir-class panels.
    for _m in 800x600 1024x768 1280x720 1280x1024 1366x768 1600x900 1920x1080; do
        if [ -z "$_avail" ] || printf '%s\n' "$_avail" | grep -qx "$_m" 2>/dev/null; then
            _result="$_result $_m"
        fi
    done
    _result=$(echo "$_result" | awk '{$1=$1};1')
    if [ -z "$_result" ]; then
        echo "1024x768 1280x720 800x600"
    else
        echo "$_result"
    fi
}

qr_init_display_modes() {
    qr_res_modes=$(qr_list_res_modes)
    set -- $(qr_fb_size)
    qr_res_current="${1}x${2}"
    qr_res_idx=0
    _i=0
    for _m in $qr_res_modes; do
        if [ "$_m" = "$qr_res_current" ]; then
            qr_res_idx=$_i
            break
        fi
        _i=$((_i + 1))
    done
}

qr_apply_resolution() {
    _mode="$1"
    _w=${_mode%x*}
    _h=${_mode#*x}
    case "$_w" in ''|*[!0-9]*) return 1 ;; esac
    case "$_h" in ''|*[!0-9]*) return 1 ;; esac
    _ok=1

    # 1) Classic fb sysfs (efifb / simplefb after nomodeset)
    if [ -w /sys/class/graphics/fb0/mode ]; then
        for _fmt in "U:${_w}x${_h}-0" "${_w}x${_h}-0" "${_w}x${_h}"; do
            if printf '%s\n' "$_fmt" > /sys/class/graphics/fb0/mode 2>/dev/null; then
                _ok=0
                break
            fi
        done
    fi

    # 2) DRM connector mode (amdgpu on Renoir etc.)
    if [ "$_ok" -ne 0 ]; then
        for _conn in /sys/class/drm/card*-*-*; do
            [ -e "$_conn/status" ] || continue
            [ "$(cat "$_conn/status" 2>/dev/null)" = "connected" ] || continue
            [ -w "$_conn/mode" ] || continue
            if [ -r "$_conn/modes" ]; then
                grep -q "^${_w}x${_h}" "$_conn/modes" 2>/dev/null || continue
            fi
            if printf '%s\n' "${_w}x${_h}" > "$_conn/mode" 2>/dev/null; then
                _ok=0
                break
            fi
        done
    fi

    # 3) fbset (works on some drivers; often fails on modern DRM)
    if [ "$_ok" -ne 0 ] && command -v fbset >/dev/null 2>&1; then
        if fbset "$_mode" 2>/dev/null || fbset -g "$_w" "$_h" "$_w" "$_h" 32 2>/dev/null; then
            _ok=0
        fi
    fi

    # 4) Soft fallback: shrink console font (visible effect when DRM ignores modes)
    if [ "$_ok" -ne 0 ]; then
        qr_font_scale_adjust 2
        qr_res_current="${_mode}~font"
        qr_scale=0
        return 0
    fi

    qr_res_current="$_mode"
    qr_scale=0
    qr_font_idx=-1
    return 0
}

qr_cycle_resolution() {
    [ -n "$qr_res_modes" ] || qr_init_display_modes
    set -- $qr_res_modes
    _count=$#
    [ "$_count" -gt 0 ] || return 1
    _attempts=0
    while [ "$_attempts" -lt "$_count" ]; do
        qr_res_idx=$(( (qr_res_idx + 1) % _count ))
        _i=0
        for _m in $qr_res_modes; do
            if [ "$_i" -eq "$qr_res_idx" ]; then
                if qr_apply_resolution "$_m"; then
                    return 0
                fi
                break
            fi
            _i=$((_i + 1))
        done
        _attempts=$((_attempts + 1))
    done
    return 1
}

qr_prefer_safe_mode() {
    # On Legacy BIOS, forcing 1024x768 via fbset/sysfs often yields broken vesafb
    # pitch (skewed QR). Keep native KMS mode there; only shrink on UEFI/efifb.
    if ! qr_is_uefi; then
        return 0
    fi
    set -- $(qr_fb_size)
    _fh=$2
    case "$_fh" in ''|*[!0-9]*) return 0 ;; esac
    # Native FHD/QHD on AMD Renoir often breaks fbi and oversizes UTF8 QR.
    if [ "$_fh" -gt 800 ]; then
        qr_apply_resolution "1024x768" || qr_apply_resolution "1280x720" || \
            qr_apply_resolution "800x600" || true
        qr_init_display_modes
    fi
}

qr_compute_auto_scale() {
    _data="$1"
    _inverted="$2"
    _png="/tmp/hwqr_probe.png"
    _max=$(qr_fb_max_px)
    _s=1
    _best=1

    while [ "$_s" -le 24 ]; do
        if ! qrencode_png "$_png" "$_s" "$_data" "$_inverted"; then
            _s=$((_s + 1))
            continue
        fi
        _w=$(qr_png_width "$_png")
        _h=$(qr_png_height "$_png")
        if [ -n "$_w" ] && [ "$_w" -le "$_max" ] \
            && { [ -z "$_h" ] || [ "$_h" -le "$_max" ]; }; then
            _best=$_s
        else
            break
        fi
        _s=$((_s + 1))
    done
    rm -f "$_png"
    qr_scale_auto=$_best
    qr_scale_max=$_best
    echo "$_best"
}

qr_effective_scale() {
    _data="$1"
    _inverted="$2"
    _auto=$(qr_compute_auto_scale "$_data" "$_inverted")

    if [ "$qr_scale" -le 0 ]; then
        echo "$_auto"
        return
    fi

    if [ "$qr_scale" -gt "$qr_scale_max" ]; then
        qr_scale=$qr_scale_max
    fi
    if [ "$qr_scale" -lt 1 ]; then
        qr_scale=1
    fi
    echo "$qr_scale"
}

qr_scale_adjust() {
    _delta="$1"
    _data="$2"
    _inverted="$3"

    if [ "$qr_scale" -le 0 ]; then
        qr_scale=$(qr_compute_auto_scale "$_data" "$_inverted")
    fi
    qr_scale=$((qr_scale + _delta))
    if [ "$qr_scale" -gt "$qr_scale_max" ]; then
        qr_scale=$qr_scale_max
    fi
    if [ "$qr_scale" -lt 1 ]; then
        qr_scale=1
    fi
}

qr_term_size() {
    _ts=$(stty size 2>/dev/null || echo "24 80")
    set -- $_ts
    _lines=${1:-24}
    _cols=${2:-80}
    case "$_lines" in ''|*[!0-9]*) _lines=24 ;; esac
    case "$_cols" in ''|*[!0-9]*) _cols=80 ;; esac
    echo "$_lines $_cols"
}

qr_utf8_metrics() {
    _data="$1"
    _margin="${2:-$qr_term_margin}"
    _tmp="/tmp/hwqr_utf8.txt"
    # Measure the same renderer we will display (Legacy prefers ANSIUTF8).
    if qr_is_uefi; then
        _ok=1
        printf '%s' "$_data" | qrencode -t UTF8 -l L -m "$_margin" > "$_tmp" 2>/dev/null || _ok=0
        if [ "$_ok" -eq 0 ]; then
            printf '%s' "$_data" | qrencode -t ANSIUTF8 -l L -m "$_margin" > "$_tmp" 2>/dev/null || {
                echo "0 0"
                return 1
            }
        fi
    else
        _ok=1
        printf '%s' "$_data" | qrencode -t ANSIUTF8 -l L -m "$_margin" > "$_tmp" 2>/dev/null || _ok=0
        if [ "$_ok" -eq 0 ]; then
            printf '%s' "$_data" | qrencode -t UTF8 -l L -m "$_margin" > "$_tmp" 2>/dev/null || {
                echo "0 0"
                return 1
            }
        fi
    fi
    _ql=$(wc -l < "$_tmp" | tr -d ' ')
    # Strip ANSI escapes when measuring width of ANSIUTF8 output.
    _qw=$(sed 's/\x1b\[[0-9;]*m//g' "$_tmp" | awk '{ if (length > m) m = length } END { print m+0 }')
    case "$_ql" in ''|*[!0-9]*) _ql=0 ;; esac
    case "$_qw" in ''|*[!0-9]*) _qw=0 ;; esac
    echo "$_ql $_qw"
}

qr_term_autofit() {
    _data="$1"
    set -- $qr_fonts
    _count=$#
    [ "$_count" -gt 0 ] || return 1

    if [ "$qr_font_idx" -ge 0 ]; then
        qr_apply_font_idx
        return 0
    fi

    for _margin in 1 0; do
        qr_term_margin=$_margin
        _i=0
        while [ "$_i" -lt "$_count" ]; do
            qr_font_idx=$_i
            qr_apply_font_idx || true
            set -- $(qr_term_size)
            _lines=$1
            _cols=$2
            _avail=$((_lines - QR_TERM_RESERVED))
            if [ "$_avail" -lt 10 ]; then
                _avail=10
            fi
            set -- $(qr_utf8_metrics "$_data" "$_margin")
            _ql=$1
            _qw=$2
            if [ "$_ql" -gt 0 ] && [ "$_ql" -le "$_avail" ] && [ "$_qw" -le "$_cols" ]; then
                return 0
            fi
            _i=$((_i + 1))
        done
    done

    qr_term_margin=0
    qr_font_idx=$((_count - 1))
    qr_apply_font_idx || true
    return 1
}

read_key_code() {
    _old_stty=$(stty -g 2>/dev/null)
    [ -n "$_old_stty" ] && stty raw -echo 2>/dev/null
    _code=$(dd bs=1 count=1 2>/dev/null | od -An -tu1 | awk '{ print $1; exit }')
    [ -n "$_old_stty" ] && stty "$_old_stty" 2>/dev/null
    echo "$_code"
}

qr_wait_action() {
    echo ""
    echo "= / + : збільшити QR   - : зменшити QR   0 : авто-масштаб"
    echo "V : наступна роздільність   Tab : інверсія кольорів"
    echo "E / N : змінити заявку   Enter / R : перезавантаження   P / S : вимкнення"

    while :; do
        _code=$(read_key_code)
        case "$_code" in
            9)
                qr_action="invert"
                return 0
                ;;
            43|61)
                qr_action="scale_up"
                return 0
                ;;
            45)
                qr_action="scale_down"
                return 0
                ;;
            48)
                qr_action="scale_auto"
                return 0
                ;;
            86|118)
                qr_action="resolution"
                return 0
                ;;
            69|78|101|110)
                qr_action="edit"
                return 0
                ;;
            80|83|112|115)
                qr_action="poweroff"
                return 0
                ;;
            82|114)
                qr_action="reboot"
                return 0
                ;;
            10|13|"")
                qr_action="reboot"
                return 0
                ;;
        esac
    done
}

qr_edit_ticket() {
    clear
    echo "Поточна заявка: $ticket"
    printf "Новий номер заявки (порожньо — залишити поточний): "
    read new_ticket
    if [ -n "$new_ticket" ]; then
        ticket="$new_ticket"
    fi
    build_qr_payload
}

qr_current_font_name() {
    set -- $qr_fonts
    _i=0
    for _name in $qr_fonts; do
        if [ "$_i" -eq "$qr_font_idx" ]; then
            echo "$_name"
            return 0
        fi
        _i=$((_i + 1))
    done
    echo "авто"
}

qr_show_framebuffer() {
    _data="$1"
    _inverted="$2"
    _png="/tmp/hwqr.png"

    if ! command -v fbi >/dev/null 2>&1; then
        return 1
    fi
    if [ ! -c /dev/fb0 ]; then
        return 1
    fi

    set -- $(qr_fb_size)
    _fbw=$1
    _fbh=$2
    qr_res_current="${_fbw}x${_fbh}"

    _best=$(qr_effective_scale "$_data" "$_inverted")
    qrencode_png "$_png" "$_best" "$_data" "$_inverted" || return 1
    _pw=$(qr_png_width "$_png")

    _tty_num=$(tty 2>/dev/null | sed -n 's|^/dev/tty||p')
    case "$_tty_num" in ''|*[!0-9]*) _tty_num=1 ;; esac

    clear
    echo "Заявка: $ticket"
    echo "Екран      : ${_fbw}x${_fbh}  (V: змінити роздільність)"
    if [ "$qr_scale" -le 0 ]; then
        echo "Масштаб QR  : ${_best} модулів (авто, макс. ${qr_scale_max})  (=/-)"
    else
        echo "Масштаб QR  : ${_best} модулів (вручну, макс. ${qr_scale_max})  (0: авто)"
    fi
    echo "Ширина QR   : ${_pw} px"
    case "$qr_payload_mode" in
        gzip+base64) _payload_lbl="стиснуто" ;;
        raw) _payload_lbl="без стиснення" ;;
        *) _payload_lbl="$qr_payload_mode" ;;
    esac
    echo "Формат QR   : ${_payload_lbl}"
    if [ "$_inverted" = "1" ]; then
        echo "Кольори QR  : інверсія"
    else
        echo "Кольори QR  : звичайні"
    fi
    echo "Скануйте QR-код на екрані."
    echo "=/- масштаб | V роздільність | Tab інверсія | Enter reboot"
    sleep 1

    # -a autozoom: critical on AMD Renoir / HiDPI where module math alone still clips.
    fbi -d /dev/fb0 -T "$_tty_num" -a -noverbose "$_png" >/tmp/hwqr_fbi.err 2>&1 &
    _fbi_pid=$!
    sleep 0.3
    if ! kill -0 "$_fbi_pid" 2>/dev/null; then
        # Retry without explicit device
        fbi -T "$_tty_num" -a -noverbose "$_png" >/tmp/hwqr_fbi.err 2>&1 &
        _fbi_pid=$!
        sleep 0.3
        if ! kill -0 "$_fbi_pid" 2>/dev/null; then
            return 1
        fi
    fi

    qr_display_mode="fb"
    qr_wait_action
    kill "$_fbi_pid" 2>/dev/null
    wait "$_fbi_pid" 2>/dev/null
    killall fbi 2>/dev/null
    return 0
}

qr_show_terminal() {
    _data="$1"
    _inverted="$2"

    qr_term_autofit "$_data" || true

    set -- $(qr_fb_size)
    _fbw=$1
    _fbh=$2
    set -- $(qr_term_size)
    _lines=$1
    _cols=$2
    _font_lbl=$(qr_current_font_name)

    clear
    echo "Заявка: $ticket"
    echo "Екран      : ${_fbw}x${_fbh}  консоль ${_cols}x${_lines}  (V: роздільність)"
    if qr_is_uefi; then
        echo "Режим      : UEFI"
    else
        echo "Режим      : Legacy BIOS"
    fi
    if [ "$qr_font_idx" -lt 0 ]; then
        echo "Масштаб QR  : авто-шрифт (${_font_lbl})  (=/-)"
    else
        echo "Масштаб QR  : шрифт ${_font_lbl}  (0: авто)"
    fi
    case "$qr_payload_mode" in
        gzip+base64) _payload_lbl="стиснуто" ;;
        raw) _payload_lbl="без стиснення" ;;
        *) _payload_lbl="$qr_payload_mode" ;;
    esac
    echo "Формат QR   : ${_payload_lbl}"
    if [ "$_inverted" = "1" ]; then
        echo "Кольори QR  : інверсія"
    else
        echo "Кольори QR  : звичайні"
    fi
    echo "Скануйте QR-код."
    echo "=============================="
    if [ "$_inverted" = "1" ]; then
        printf '\033[7m'
    fi
    # On Legacy, ANSIUTF8 (full blocks) is often more stable than UTF8 half-blocks
    # when vesafb/glyph rendering skews the matrix.
    if qr_is_uefi; then
        printf '%s' "$_data" | qrencode -t UTF8 -l L -m "$qr_term_margin" 2>/dev/null || \
            printf '%s' "$_data" | qrencode -t ANSIUTF8 -l L -m "$qr_term_margin"
    else
        printf '%s' "$_data" | qrencode -t ANSIUTF8 -l L -m "$qr_term_margin" 2>/dev/null || \
            printf '%s' "$_data" | qrencode -t UTF8 -l L -m "$qr_term_margin"
    fi
    if [ "$_inverted" = "1" ]; then
        printf '\033[0m'
    fi
    echo "=============================="
    qr_display_mode="term"
    qr_wait_action
}

qr_inverted=0
qr_init_display_modes
qr_prefer_safe_mode
while :; do
    if ! qr_show_framebuffer "$qr_payload" "$qr_inverted"; then
        qr_show_terminal "$qr_payload" "$qr_inverted"
    fi

    case "$qr_action" in
        scale_up)
            # fb: larger modules; term: larger font (smaller font index)
            qr_scale_adjust 1 "$qr_payload" "$qr_inverted"
            qr_font_scale_adjust -1
            ;;
        scale_down)
            qr_scale_adjust -1 "$qr_payload" "$qr_inverted"
            qr_font_scale_adjust 1
            ;;
        scale_auto)
            qr_scale=0
            qr_font_idx=-1
            ;;
        resolution)
            qr_cycle_resolution || true
            qr_font_idx=-1
            ;;
        invert)
            if [ "$qr_inverted" = "1" ]; then
                qr_inverted=0
            else
                qr_inverted=1
            fi
            ;;
        edit)
            qr_edit_ticket
            qr_scale=0
            qr_font_idx=-1
            ;;
        poweroff)
            poweroff
            exit 0
            ;;
        reboot|*)
            reboot
            exit 0
            ;;
    esac
done
