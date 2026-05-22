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

clear
echo "====================================="
echo "   SERVICE CENTER HARDWARE UTILITY   "
echo "====================================="
echo ""
printf "Enter Ticket Number: "
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

qr_add V 1
qr_add T "$ticket"
qr_add DT "$scan_dt"
qr_add C "$cpu"
cpu_cores=${cpu_ct%/*}
cpu_threads=${cpu_ct#*/}
qr_add CT "$cpu_cores" "$cpu_threads"
qr_add R "$ram"
qr_add SM "$sys_manufacturer"
qr_add PN "$product_name"
qr_add SS "$system_serial"
qr_add UUID "$system_uuid"
qr_add AT "$asset_tag"
qr_add M "$mb_vendor_model"
qr_add MS "$mb_serial"
qr_add B "$bios"
qr_add BD "$bios_date"
qr_add BF "$bios_full"
qr_add TPM "$tpm_status"

if [ -n "$ram_modules" ]; then
    _ifs=$IFS
    IFS='|'
    for _rm in $ram_modules; do
        [ -n "$_rm" ] && output="${output}|${_rm}"
    done
    IFS=$_ifs
fi

if [ -n "$gpus" ]; then
    while IFS= read -r _gpu; do
        [ -n "$_gpu" ] || continue
        qr_add G "$_gpu"
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

    qr_add BAT "$bat_name" "$bat_status" "$bat_capacity" "$bat_health" \
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
    qr_add D "$model" "$serial" "$size" "$tran" "$media" "$smart"
    _disk_i=$((_disk_i + 1))
done
disk_count=$_disk_i

clear
echo "--- Hardware Data Collected ---"
echo "Ticket      : $ticket"
echo "Scanned     : $scan_dt"
echo "CPU         : $cpu ($cpu_ct cores/threads)"
echo "RAM         : $ram"
if [ -n "$ram_modules" ]; then
    echo "$ram_modules" | tr '|' '\n' | sed 's/^RM\//  DIMM        : /' | tr '/' ' '
else
    echo "  DIMM        : (not available)"
fi
echo "System      : $sys_manufacturer $product_name (SN: $system_serial)"
echo "Asset tag   : $asset_tag"
echo "UUID        : $system_uuid"
echo "Motherboard : $mb_vendor_model (SN: $mb_serial)"
echo "BIOS        : $bios ($bios_date)"
echo "BIOS full   : $bios_full"
echo "TPM         : $tpm_status"
if [ -n "$gpus" ]; then
    printf '%s\n' "$gpus" | sed 's/^/  GPU         : /'
else
    echo "  GPU         : (not detected)"
fi
if [ "$battery_count" -gt 0 ]; then
    echo "$output" | tr '|' '\n' | grep '^BAT/' | sed 's/^BAT\//  Battery     : /' | tr '/' ' '
else
    echo "  Battery     : (none)"
fi
if [ "$disk_count" -gt 0 ]; then
    echo "$output" | tr '|' '\n' | grep '^D/' | sed 's/^D\//  Drive       : /' | tr '/' ' '
else
    echo "  Drive       : (none)"
fi
echo "QR schema   : v1 (segments TAG/field/... separated by |)"
echo "-------------------------------"
echo ""

echo "Press Enter to generate QR Code..."
read dummy

# Raw payload: no compression since resolution is increased
qr_payload="V/1|${output}"

qr_png_width() {
    file -b "$1" 2>/dev/null | sed -n 's/.*, \([0-9][0-9]*\) x [0-9][0-9]*.*/\1/p'
}

qr_fb_size() {
    _fw=1024
    _fh=768
    if [ -r /sys/class/graphics/fb0/virtual_size ]; then
        read _fw _fh < /sys/class/graphics/fb0/virtual_size 2>/dev/null
    fi
    [ -z "$_fw" ] && _fw=1024
    [ -z "$_fh" ] && _fh=768
    echo "$_fw $_fh"
}

qr_show_framebuffer() {
    _data="$1"
    _png="/tmp/hwqr.png"
    set -- $(qr_fb_size)
    _fbw=$1
    _fbh=$2
    _max=$((_fbw < _fbh ? _fbw : _fbh))
    _max=$((_max - 60))

    # Pick largest module size that fits the framebuffer (sharper QR on high-res screens).
    _s=4
    _best=4
    while [ "$_s" -le 24 ]; do
        if ! qrencode -o "$_png" -s "$_s" -m 2 -l L "$_data" 2>/dev/null; then
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
    qrencode -o "$_png" -s "$_best" -m 2 -l L "$_data" 2>/dev/null || return 1

    clear
    echo "Ticket: $ticket"
    echo "Resolution  : ${_fbw}x${_fbh}"
    echo "Scan the QR code on screen."
    echo ""

    if ! command -v fbi >/dev/null 2>&1; then
        return 1
    fi

    if [ -c /dev/fb0 ]; then
        fbi -d /dev/fb0 -a -1 -center -noverbose -T quick "$_png" 2>/dev/null || \
            openvt -c 1 -s -w -- fbi -d /dev/fb0 -a -1 -center -noverbose -T quick "$_png" 2>/dev/null || \
            fbi -a -1 -center -noverbose -T quick "$_png" 2>/dev/null || return 1
    else
        fbi -a -1 -center -noverbose -T quick "$_png" 2>/dev/null || return 1
    fi

    echo ""
    echo "Press Enter to reboot..."
    read dummy
    killall fbi 2>/dev/null
    return 0
}

qr_show_terminal() {
    _data="$1"
    set -- $(qr_fb_size)
    _fbw=$1
    _fbh=$2

    # Smaller font → more columns (helps terminal fallback on wide screens).
    if command -v setfont >/dev/null 2>&1; then
        for _font in \
            /usr/share/kbd/consolefonts/default8x9.psfu.gz \
            /usr/share/kbd/consolefonts/lat8-08.psfu.gz \
            /usr/share/kbd/consolefonts/lat9-12.psfu.gz; do
            if [ -f "$_font" ]; then
                setfont "$_font" 2>/dev/null && break
            fi
        done
    fi

    clear
    echo "Ticket: $ticket"
    echo "Resolution  : ${_fbw}x${_fbh} (terminal QR — rebuild ISO if too large)"
    echo "Scan the QR code."
    echo "=============================="
    printf '%s' "$_data" | qrencode -t UTF8 -l L -m 1 2>/dev/null || \
        printf '%s' "$_data" | qrencode -t ANSIUTF8 -l L -m 1
    echo "=============================="
    echo ""
    echo "Press Enter to reboot..."
    read dummy
}

if ! qr_show_framebuffer "$qr_payload"; then
    qr_show_terminal "$qr_payload"
fi
reboot
