#!/bin/bash
# ============================================================
# SDR Weather Station Scanner
#
# Listens on the RTL-SDR dongle using rtl_433, identifies
# nearby weather station broadcasts, and generates the
# correct weewx-sdr sensor_map configuration.
#
# If WeeWX is already running it holds the SDR dongle via its
# own rtl_433 subprocess.  This script stops WeeWX before
# scanning and restarts it afterwards (or on early exit).
#
# Usage:
#   bash installer/scan_sdr.sh [--duration N] [--apply]
#
# Options:
#   --duration N   Scan for N seconds (default: 90)
#   --apply        Write the chosen sensor_map automatically
#                  without an interactive Y/n prompt
#
# On success, the sensor_map block is also written to:
#   /tmp/weewx_sensor_map.conf   (for use by calling scripts)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WEEWX_CONF_DEST="/etc/weewx/weewx.conf"
SCAN_DURATION=90
AUTO_APPLY=false
SCAN_TMP=$(mktemp /tmp/sdr_scan_XXXXXX.json)
RESULT_TMP="/tmp/weewx_sensor_map.conf"
WEEWX_WAS_RUNNING=false
RTL_PID=""

# ── Argument parsing ──────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) SCAN_DURATION="$2"; shift 2 ;;
        --apply)    AUTO_APPLY=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Cleanup on exit (Ctrl-C or error) ────────────────────────
cleanup() {
    # Kill rtl_433 if still running
    if [ -n "$RTL_PID" ]; then
        kill "$RTL_PID" 2>/dev/null || true
        wait "$RTL_PID" 2>/dev/null || true
    fi
    rm -f "$SCAN_TMP"
    # Restart WeeWX if we stopped it
    if $WEEWX_WAS_RUNNING; then
        echo ""
        echo "  Restarting WeeWX..."
        sudo systemctl start weewx 2>/dev/null || true
        echo "  WeeWX restarted."
    fi
}
trap cleanup EXIT

echo ""
echo "================================================"
echo "  SDR Weather Station Scanner"
echo "================================================"
echo ""

# ── Pre-flight: rtl_433 installed? ───────────────────────────
if ! command -v rtl_433 >/dev/null 2>&1; then
    echo "  ✗  rtl_433 is not installed."
    echo "     Run the installer first:  bash installer/install_weewx.sh"
    exit 1
fi

# ── Pre-flight: SDR dongle connected? ────────────────────────
echo "  Checking for RTL-SDR USB device..."

if lsusb 2>/dev/null | grep -qi "0bda"; then
    DONGLE_LINE=$(lsusb 2>/dev/null | grep -i "0bda" | head -1)
    echo "  Found: $DONGLE_LINE"
else
    echo ""
    echo "  ⚠  No RTL-SDR dongle detected (no USB device with vendor 0bda)."
    echo ""
    printf "  Continue anyway? [y/N]: "
    read -r _CONT || true
    _CONT="${_CONT:-N}"
    if [[ ! "$_CONT" =~ ^[Yy]$ ]]; then
        echo "  Plug in the SDR dongle and try again."
        exit 1
    fi
fi

# ── Stop WeeWX if it is running (it holds the SDR dongle) ────
echo ""
if systemctl is-active --quiet weewx 2>/dev/null; then
    echo "  WeeWX is currently running and holds the SDR dongle."
    echo "  It must be stopped for the duration of the scan."
    echo ""
    printf "  Stop WeeWX now and restart it after the scan? [Y/n]: "
    read -r _STOP_WX || true
    _STOP_WX="${_STOP_WX:-Y}"

    if [[ "$_STOP_WX" =~ ^[Yy]$ ]]; then
        sudo systemctl stop weewx
        WEEWX_WAS_RUNNING=true
        echo "  WeeWX stopped."
    else
        echo ""
        echo "  Cannot scan while WeeWX is running — aborting."
        echo "  Stop WeeWX manually first:  sudo systemctl stop weewx"
        exit 1
    fi
else
    echo "  WeeWX is not running — SDR dongle is free."
fi

# ── Scan ─────────────────────────────────────────────────────
echo ""
echo "  Scanning for ${SCAN_DURATION} seconds..."
echo "  Most weather stations transmit every 18–48 seconds."
echo "  Press Ctrl-C to stop early and use what was captured."
echo ""

rtl_433 -q -F json 2>/dev/null > "$SCAN_TMP" &
RTL_PID=$!

START_TIME=$(date +%s)
END_TIME=$(( START_TIME + SCAN_DURATION ))

while true; do
    NOW=$(date +%s)
    REMAINING=$(( END_TIME - NOW ))
    [ "$REMAINING" -le 0 ] && break

    PACKET_COUNT=$(wc -l < "$SCAN_TMP" 2>/dev/null | tr -d ' ')
    printf "\r  Scanning... %3ds remaining  |  packets captured: %-4s" \
        "$REMAINING" "$PACKET_COUNT"
    sleep 1
done

kill "$RTL_PID" 2>/dev/null || true
wait "$RTL_PID" 2>/dev/null || true
RTL_PID=""   # prevent cleanup() killing it again

FINAL_COUNT=$(wc -l < "$SCAN_TMP" 2>/dev/null | tr -d ' ')
printf "\r  Scan complete. %s packet(s) captured.                 \n\n" \
    "$FINAL_COUNT"

if [ "$FINAL_COUNT" -eq 0 ]; then
    echo "  No packets captured."
    echo ""
    echo "  Common causes:"
    echo "    - SDR dongle not connected or not recognized by rtl_433"
    echo "    - Weather station out of range (typically 50–300 m)"
    echo "    - Station transmit interval longer than scan window"
    echo "      Try a longer scan:  bash installer/scan_sdr.sh --duration 180"
    echo "    - Kernel module conflict — try:"
    echo "      sudo rmmod dvb_usb_rtl28xxu rtl2832 2>/dev/null; then retry"
    echo ""
    exit 1
fi

# ── Parse captured packets ────────────────────────────────────
PARSE_RESULT=$(python3 - "$SCAN_TMP" <<'PYEOF'
import json, sys, collections

SCAN_FILE = sys.argv[1]

# model string → (PacketType, id_field, id_format)
# id_format: 'hex4' = "%04X" % id,  'dec' = str(id)
PACKET_TYPES = {
    "Acurite-Atlas":        ("AcuriteAtlasPacket",    "id",        "hex4"),
    "Acurite 5n1 sensor":   ("Acurite5n1Packet",      "sensor_id", "hex4"),
    "Acurite tower sensor": ("AcuriteTowerPacket",     "id",        "hex4"),
    "Acurite-986":          ("Acurite986Packet",       "id",        "dec"),
    "Acurite-6045M":        ("AcuriteLightningPacket", "id",        "hex4"),
    "Acurite-Rain899":      ("AcuriteRain899Packet",   "id",        "hex4"),
    "Acurite 606TX Sensor": ("Acurite606TXPacket",     "id",        "dec"),
    "Acurite-606TX":        ("Acurite606TXPacketV2",   "id",        "dec"),
}

# rtl_433 JSON key → (weewx_field, sdr_field)
FIELD_MAP = {
    "temperature_F":   ("outTemp",              "temperature"),
    "temperature_C":   ("outTemp",              "temperature"),
    "humidity":        ("outHumidity",           "humidity"),
    "wind_avg_mi_h":   ("windSpeed",             "wind_speed"),
    "wind_avg_km_h":   ("windSpeed",             "wind_speed"),
    "wind_speed_mph":  ("windSpeed",             "wind_speed"),
    "wind_speed_kph":  ("windSpeed",             "wind_speed"),
    "wind_dir_deg":    ("windDir",               "wind_dir"),
    "rain_in":         ("rain_total",            "rain_total"),
    "rain_mm":         ("rain_total",            "rain_total"),
    "raincounter_raw": ("rain_total",            "rain_total"),
    "strike_count":    ("strikes_total",         "strike_count"),
    "strike_distance": ("lightning_distance",    "strike_distance"),
    "storm_dist":      ("lightning_distance",    "strike_distance"),
    "uv":              ("uv_index",              "uv"),
    "lux":             ("lux",                   "lux"),
    "pressure_hPa":    ("pressure",              "pressure"),
    "pressure_kPa":    ("pressure",              "pressure"),
    "battery_ok":      ("outTempBatteryStatus",  "battery"),
    "battery_low":     ("outTempBatteryStatus",  "battery"),
    "battery":         ("outTempBatteryStatus",  "battery"),
}

packets = []
with open(SCAN_FILE) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            packets.append(json.loads(line))
        except json.JSONDecodeError:
            continue

if not packets:
    print("NO_PACKETS")
    sys.exit(0)

device_data = {}  # (model, hw_id) → {fields, count, packet_type}

for pkt in packets:
    model = pkt.get("model", "")
    if model not in PACKET_TYPES:
        continue

    packet_type, id_field, id_fmt = PACKET_TYPES[model]
    raw_id = pkt.get(id_field) or pkt.get("id")
    if raw_id is None:
        continue

    hw_id = ("%04X" % int(raw_id)) if id_fmt == "hex4" else str(int(raw_id))
    key = (model, hw_id)

    if key not in device_data:
        device_data[key] = {"fields": set(), "count": 0, "packet_type": packet_type}

    device_data[key]["count"] += 1

    for json_field, (weewx_field, sdr_field) in FIELD_MAP.items():
        if json_field in pkt and pkt[json_field] is not None:
            device_data[key]["fields"].add((weewx_field, sdr_field))

# Sort by packet count descending (most active device first)
print(f"DEVICE_COUNT:{len(device_data)}")
for i, ((model, hw_id), data) in enumerate(
        sorted(device_data.items(), key=lambda x: -x[1]["count"])):
    print(f"DEV:{i}:model:{model}")
    print(f"DEV:{i}:packet_type:{data['packet_type']}")
    print(f"DEV:{i}:hw_id:{hw_id}")
    print(f"DEV:{i}:count:{data['count']}")
    for weewx_field, sdr_field in sorted(data["fields"]):
        print(f"DEV:{i}:field:{weewx_field}:{sdr_field}")
PYEOF
)

if echo "$PARSE_RESULT" | grep -q "^NO_PACKETS"; then
    echo "  No recognizable weather station packets found."
    echo "  Signals were received but none matched known device types."
    echo "  Try a longer scan:  bash installer/scan_sdr.sh --duration 180"
    exit 1
fi

DEVICE_COUNT=$(echo "$PARSE_RESULT" | grep "^DEVICE_COUNT:" | cut -d: -f2)

# ── Display found devices ─────────────────────────────────────
echo "  Found $DEVICE_COUNT device(s):"
echo ""

for i in $(seq 0 $(( DEVICE_COUNT - 1 ))); do
    MODEL=$(echo "$PARSE_RESULT" | grep "^DEV:${i}:model:"       | cut -d: -f4-)
    PTYPE=$(echo "$PARSE_RESULT" | grep "^DEV:${i}:packet_type:" | cut -d: -f4-)
    HW_ID=$(echo "$PARSE_RESULT" | grep "^DEV:${i}:hw_id:"       | cut -d: -f4-)
    COUNT=$(echo "$PARSE_RESULT" | grep "^DEV:${i}:count:"       | cut -d: -f4-)
    FIELDS=$(echo "$PARSE_RESULT" | grep "^DEV:${i}:field:" | cut -d: -f4 | sort | tr '\n' ' ')

    echo "  $(( i + 1 ))  $MODEL"
    echo "     ID      : $HW_ID  ($PTYPE)"
    echo "     Packets : $COUNT received during scan"
    echo "     Fields  : $FIELDS"
    echo ""
done

# ── Device selection ──────────────────────────────────────────
if [ "$DEVICE_COUNT" -eq 1 ]; then
    SELECTED=0
    echo "  Only one device found — selecting automatically."
    echo ""
else
    while true; do
        printf "  Select your weather station [1-%d]: " "$DEVICE_COUNT"
        read -r SEL || true
        if [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= DEVICE_COUNT )); then
            SELECTED=$(( SEL - 1 ))
            break
        fi
        echo "  Please enter a number between 1 and $DEVICE_COUNT."
    done
    echo ""
fi

SEL_MODEL=$(echo "$PARSE_RESULT" | grep "^DEV:${SELECTED}:model:"       | cut -d: -f4-)
SEL_PTYPE=$(echo "$PARSE_RESULT" | grep "^DEV:${SELECTED}:packet_type:" | cut -d: -f4-)
SEL_ID=$(echo   "$PARSE_RESULT" | grep "^DEV:${SELECTED}:hw_id:"        | cut -d: -f4-)

# ── Build sensor_map block ────────────────────────────────────
echo "  Sensor map for: $SEL_MODEL  (ID: $SEL_ID)"
echo ""

SENSOR_MAP=$(echo "$PARSE_RESULT" \
    | grep "^DEV:${SELECTED}:field:" \
    | while IFS=: read -r _dev _idx _type weewx_field sdr_field; do
        printf "        %-28s = %s.%s.%s\n" \
            "$weewx_field" "$sdr_field" "$SEL_ID" "$SEL_PTYPE"
    done)

# Ensure battery is always present
if ! echo "$SENSOR_MAP" | grep -q "battery"; then
    SENSOR_MAP="${SENSOR_MAP}
        outTempBatteryStatus         = battery.${SEL_ID}.${SEL_PTYPE}"
fi

echo "$SENSOR_MAP"
echo ""

# Write sensor_map to temp file for calling scripts
printf "[[sensor_map]]\n%s\n" "$SENSOR_MAP" > "$RESULT_TMP"

# ── Apply sensor_map to weewx.conf ───────────────────────────

# Replaces (or inserts) [[sensor_map]] inside [SDR] in the given conf file.
# Reads SENSOR_MAP_BLOCK from environment.
apply_to_conf() {
    local CONF_PATH="$1"

    if [ ! -f "$CONF_PATH" ]; then
        echo "  Skipping (not found): $CONF_PATH"
        return
    fi

    local BACKUP
    BACKUP="${CONF_PATH}.bak.$(date +%Y%m%d_%H%M%S)"

    python3 - "$CONF_PATH" "$BACKUP" <<'PYEOF'
import sys, re, os, shutil

conf_path, backup_path = sys.argv[1], sys.argv[2]
sensor_map_block = os.environ["SENSOR_MAP_BLOCK"]

with open(conf_path) as f:
    content = f.read()

# Build the replacement [[sensor_map]] block (4-space indent inside [SDR])
new_map = "    [[sensor_map]]\n" + sensor_map_block + "\n"

# Try to replace an existing [[sensor_map]] block inside [SDR]
pattern = r'(\[SDR\].*?)(\[\[sensor_map\]\].*?)(\n[ \t]*\[\[|\n\[(?!\[))'
replacement = lambda m: m.group(1) + new_map.rstrip() + m.group(3)
new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

if new_content == content:
    # No existing [[sensor_map]] — insert after the driver = user.sdr line
    pattern2 = r'(\[SDR\].*?driver\s*=\s*user\.sdr[^\n]*)'
    new_content = re.sub(
        pattern2,
        lambda m: m.group(1) + "\n" + new_map.rstrip(),
        content,
        flags=re.DOTALL,
    )

if new_content != content:
    shutil.copy2(conf_path, backup_path)
    print(f"  Backed up → {backup_path}")
    with open(conf_path, "w") as f:
        f.write(new_content)
    print(f"  Updated:   {conf_path}")
else:
    print(f"  ⚠  Could not find [SDR] section in {conf_path}")
    print( "     Add the sensor_map manually — it was printed above.")
PYEOF
}

do_apply() {
    export SENSOR_MAP_BLOCK="$SENSOR_MAP"

    if [ -f "$WEEWX_CONF_DEST" ]; then
        echo "  Updating $WEEWX_CONF_DEST..."
        if [ -w "$WEEWX_CONF_DEST" ]; then
            apply_to_conf "$WEEWX_CONF_DEST"
        else
            SUDO_TMP=$(mktemp /tmp/weewx_conf_XXXXXX)
            cp "$WEEWX_CONF_DEST" "$SUDO_TMP"
            apply_to_conf "$SUDO_TMP"
            sudo cp "$SUDO_TMP" "$WEEWX_CONF_DEST"
            rm -f "$SUDO_TMP"
        fi
    else
        echo "  ⚠  weewx.conf not found at $WEEWX_CONF_DEST"
        echo "     Has WeeWX been installed? Run the installer first."
    fi
}

if $AUTO_APPLY; then
    do_apply
else
    printf "  Apply this sensor_map to weewx.conf? [Y/n]: "
    read -r _APPLY || true
    _APPLY="${_APPLY:-Y}"
    if [[ "$_APPLY" =~ ^[Yy]$ ]]; then
        do_apply
    else
        echo ""
        echo "  Not applied. Add this block manually under [SDR] in weewx.conf:"
        echo ""
        echo "      [[sensor_map]]"
        echo "$SENSOR_MAP"
    fi
fi

echo ""
echo "  Sensor map saved to: $RESULT_TMP"

# ── Restart WeeWX if we stopped it ───────────────────────────
# (cleanup() also handles this on unexpected exit, so clear the flag
#  here to avoid a double-restart)
if $WEEWX_WAS_RUNNING; then
    echo ""
    echo "  Restarting WeeWX with the new sensor_map..."
    sudo systemctl start weewx
    WEEWX_WAS_RUNNING=false   # tell cleanup() not to restart again
    echo "  WeeWX running."
fi

echo ""
