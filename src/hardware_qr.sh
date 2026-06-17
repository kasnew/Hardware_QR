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

qr_set_console_font() {
    command -v setfont >/dev/null 2>&1 || return 0

    if [ -f /etc/arch-release ]; then
        for _dir in /usr/share/kbd/consolefonts; do
            [ -d "$_dir" ] || continue
            for _name in LatArCyrHeb-16 UniCyr_8x16 Cyr_a8x16 LatArCyrHeb-14; do
                for _ext in .psfu.gz .psf.gz; do
                    if [ -f "$_dir/$_name$_ext" ]; then
                        setfont "$_dir/$_name$_ext" 2>/dev/null && return 0
                    fi
                done
            done
        done
        return 0
    fi

    for _font in \
        /usr/share/kbd/consolefonts/default8x9.psfu.gz \
        /usr/share/kbd/consolefonts/lat8-08.psfu.gz \
        /usr/share/kbd/consolefonts/lat9-12.psfu.gz \
        /usr/share/consolefonts/default8x9.psfu.gz \
        /usr/share/consolefonts/lat8-08.psfu.gz \
        /usr/share/consolefonts/lat9-12.psfu.gz; do
        if [ -f "$_font" ]; then
            setfont "$_font" 2>/dev/null && return 0
        fi
    done
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

clear
echo "--- Зібрані дані про залізо ---"
echo "Заявка     : $ticket"
echo "Скановано  : $scan_dt"
echo "CPU        : $cpu ($cpu_ct ядер/потоків)"
echo "ОЗП        : $ram"
if [ -n "$ram_modules" ]; then
    echo "$ram_modules" | tr '|' '\n' | sed 's/^RM\//  Планка ОЗП  : /' | tr '/' ' '
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
    echo "$output" | tr '|' '\n' | grep '^BAT/' | sed 's/^BAT\//  Батарея    : /' | tr '/' ' '
else
    echo "  Батарея    : (немає)"
fi
if [ "$disk_count" -gt 0 ]; then
    echo "$output" | tr '|' '\n' | grep '^D/' | sed 's/^D\//  Диск       : /' | tr '/' ' '
else
    echo "  Диск       : (немає)"
fi
echo "Схема QR   : v1 (сегменти TAG/поле/... через |)"
echo "-------------------------------"
echo ""

echo "Натисніть Enter для генерації QR-коду..."
read dummy

qr_png_width() {
    file -b "$1" 2>/dev/null | sed -n 's/.*, \([0-9][0-9]*\) x [0-9][0-9]*.*/\1/p'
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
    if { [ -z "$_fw" ] || [ -z "$_fh" ]; } && [ -r /sys/class/graphics/fb0/modes ]; then
        _fb_mode=$(sed -n '1s/.*:\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p' /sys/class/graphics/fb0/modes 2>/dev/null)
        set -- $_fb_mode
        _fw=$1
        _fh=$2
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
    _max=$((_min * 80 / 100))
    _floor=$((_min - 120))
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

# QR display tuning (adjust on QR screen with =/-, 0, R)
qr_scale=0          # 0 = auto-fit; otherwise qrencode -s module size
qr_scale_auto=8
qr_scale_max=24
qr_res_modes=""
qr_res_idx=0
qr_res_current=""

qr_list_res_modes() {
    _avail=""
    if [ -r /sys/class/graphics/fb0/modes ]; then
        _avail=$(sed -n 's/.*:\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1x\2/p' \
            /sys/class/graphics/fb0/modes 2>/dev/null | sort -u)
    fi
    _result=""
    for _m in 1024x768 1280x1024 1280x720 1366x768 1600x900 1920x1080; do
        if [ -z "$_avail" ] || printf '%s\n' "$_avail" | grep -qx "$_m" 2>/dev/null; then
            _result="$_result $_m"
        fi
    done
    _result=$(echo "$_result" | awk '{$1=$1};1')
    if [ -z "$_result" ]; then
        echo "1024x768"
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

    if command -v fbset >/dev/null 2>&1; then
        fbset "$_mode" 2>/dev/null || \
            fbset -g "$_w" "$_h" "$_w" "$_h" 32 2>/dev/null || return 1
    else
        return 1
    fi
    qr_res_current="$_mode"
    qr_scale=0
    return 0
}

qr_cycle_resolution() {
    [ -n "$qr_res_modes" ] || qr_init_display_modes
    set -- $qr_res_modes
    _count=$#
    [ "$_count" -gt 0 ] || return 1
    qr_res_idx=$(( (qr_res_idx + 1) % _count ))
    _i=0
    for _m in $qr_res_modes; do
        if [ "$_i" -eq "$qr_res_idx" ]; then
            qr_apply_resolution "$_m" && return 0
            return 1
        fi
        _i=$((_i + 1))
    done
    return 1
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
        if [ -n "$_w" ] && [ "$_w" -le "$_max" ]; then
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

qr_show_framebuffer() {
    _data="$1"
    _inverted="$2"
    _png="/tmp/hwqr.png"
    set -- $(qr_fb_size)
    _fbw=$1
    _fbh=$2
    qr_res_current="${_fbw}x${_fbh}"

    _best=$(qr_effective_scale "$_data" "$_inverted")
    qrencode_png "$_png" "$_best" "$_data" "$_inverted" || return 1
    _pw=$(qr_png_width "$_png")

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
    echo ""

    if ! command -v fbi >/dev/null 2>&1; then
        return 1
    fi

    if [ -c /dev/fb0 ]; then
        fbi -d /dev/fb0 -T 1 -1 -t 1 -center -noverbose "$_png" 2>/dev/null || \
            openvt -c 1 -s -w -- fbi -d /dev/fb0 -T 1 -1 -t 1 -center -noverbose "$_png" 2>/dev/null || \
            fbi -T 1 -1 -t 1 -center -noverbose "$_png" 2>/dev/null || return 1
    else
        fbi -T 1 -1 -t 1 -center -noverbose "$_png" 2>/dev/null || return 1
    fi

    echo ""
    qr_wait_action
    killall fbi 2>/dev/null
    return 0
}

qr_show_terminal() {
    _data="$1"
    _inverted="$2"
    set -- $(qr_fb_size)
    _fbw=$1
    _fbh=$2

    qr_set_console_font

    clear
    echo "Заявка: $ticket"
    set -- $(qr_fb_size)
    echo "Екран      : ${1}x${2}  (V: змінити роздільність)"
    if [ "$qr_scale" -le 0 ]; then
        echo "Масштаб QR  : авто (режим терміналу; =/- якщо є framebuffer)"
    else
        echo "Масштаб QR  : ${qr_scale} модулів (вручну)"
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
    printf '%s' "$_data" | qrencode -t UTF8 -l L -m 1 2>/dev/null || \
        printf '%s' "$_data" | qrencode -t ANSIUTF8 -l L -m 1
    if [ "$_inverted" = "1" ]; then
        printf '\033[0m'
    fi
    echo "=============================="
    qr_wait_action
}

qr_inverted=0
qr_init_display_modes
while :; do
    if ! qr_show_framebuffer "$qr_payload" "$qr_inverted"; then
        qr_show_terminal "$qr_payload" "$qr_inverted"
    fi

    case "$qr_action" in
        scale_up)
            qr_scale_adjust 1 "$qr_payload" "$qr_inverted"
            ;;
        scale_down)
            qr_scale_adjust -1 "$qr_payload" "$qr_inverted"
            ;;
        scale_auto)
            qr_scale=0
            ;;
        resolution)
            qr_cycle_resolution || true
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
