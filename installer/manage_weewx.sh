#!/bin/bash
# ============================================================
# Nomad-WeeWX Manager
#
# Day-to-day management of the WeeWX service, database,
# and companion project deployments.
#
# Usage:
#   bash installer/manage_weewx.sh [command]
#
# Commands (interactive menu if none given):
#   start       Start weewx service
#   stop        Stop weewx service
#   restart     Restart weewx service
#   status      Show service status and deployed file locations
#   logs        Tail live service logs
#   deploy      Redeploy NomadNet pages and NodeBot plugin
#   scan        Run interactive SDR station scan
#   db-check    Inspect the SQLite weather database
#   uninstall   Remove WeeWX and all installed files
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Load saved install config (NodeBot path etc.) ─────────────
INSTALL_CONFIG="$PROJECT_DIR/.install_config"
NODEBOT_PLUGINS_DEFAULT="/home/$(whoami)/NodeBot/src/plugins"

if [ -f "$INSTALL_CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$INSTALL_CONFIG"
fi
NODEBOT_PLUGINS="${NODEBOT_PLUGINS:-$NODEBOT_PLUGINS_DEFAULT}"

# ── Fixed paths ───────────────────────────────────────────────
NOMADNET_PAGES="$HOME/.nomadnetwork/storage/pages"
WEEWX_CONF_DEST="/etc/weewx/weewx.conf"
TEMPLATES_DIR="$PROJECT_DIR/templates"
PLUGIN_SRC="$TEMPLATES_DIR/weewx.py"
PAGE_SRC_DIR="$TEMPLATES_DIR/nomadpages"
WEEWX_DB="$(python3 - <<'PYEOF' 2>/dev/null || echo "/var/lib/weewx/weewx.sdb"
import configparser, os
c = configparser.RawConfigParser()
conf = "/etc/weewx/weewx.conf"
if os.path.exists(conf):
    c.read(conf)
    try:
        db_name   = c.get("archive_sqlite", "database_name")
        sqlite_rt = c.get("SQLite", "SQLITE_ROOT")
        print(os.path.join(sqlite_rt, db_name))
        exit()
    except Exception:
        pass
print("/var/lib/weewx/weewx.sdb")
PYEOF
)"

SERVICE="weewx"

# ── setup_pages_venv ─────────────────────────────────────────
# Creates (or updates) the venv inside the deployed pages/weewx/
# directory and rewrites .mu shebangs to point at it.
# See install_weewx.sh for full description.
setup_pages_venv() {
    local PROJECT_DIR="$1"
    local VENV_DIR="$PROJECT_DIR/.venv"
    local REQ="$PROJECT_DIR/requirements.txt"

    if [ ! -d "$PROJECT_DIR" ]; then
        echo "  ⚠  Project pages directory not found: $PROJECT_DIR"
        return 1
    fi

    if [ ! -f "$REQ" ]; then
        echo "  ⚠  requirements.txt not found: $REQ"
        return 1
    fi

    echo "  Setting up venv: $VENV_DIR"

    if command -v uv >/dev/null 2>&1; then
        uv venv "$VENV_DIR" --quiet
        uv pip install --quiet -r "$REQ" --python "$VENV_DIR/bin/python3"
    else
        python3 -m venv "$VENV_DIR"
        "$VENV_DIR/bin/pip" install --quiet -r "$REQ"
    fi

    local VENV_PYTHON="$VENV_DIR/bin/python3"
    echo "  Installed: $(tr '\n' ' ' < "$REQ")"

    # Fetch micron_converter.py from source
    local MICRON_URL="https://raw.githubusercontent.com/JamesM92/Ansi2MicronMU/main/micron_converter.py"
    local MICRON_DEST="$PROJECT_DIR/micron_converter.py"
    echo "  Fetching micron_converter.py from Ansi2MicronMU..."
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$MICRON_DEST" "$MICRON_URL"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$MICRON_URL" -o "$MICRON_DEST"
    else
        echo "  ⚠  Neither wget nor curl found — micron_converter.py not fetched."
        echo "     Download it manually from https://github.com/JamesM92/Ansi2MicronMU"
    fi

    local REWRITTEN=0
    for script in "$PROJECT_DIR"/*.mu; do
        [ -f "$script" ] || continue
        local FIRST_LINE
        FIRST_LINE=$(head -1 "$script")
        if [[ "$FIRST_LINE" == "#!/"*"python"* ]] || \
           [[ "$FIRST_LINE" == "#!/usr/bin/env python"* ]]; then
            python3 - "$script" "$VENV_PYTHON" <<'PYEOF'
import sys
path, interp = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()
lines[0] = f"#!{interp}\n"
with open(path, "w") as f:
    f.writelines(lines)
PYEOF
            chmod +x "$script"
            REWRITTEN=$(( REWRITTEN + 1 ))
        fi
    done

    echo "  Shebang rewritten in $REWRITTEN script(s) → $VENV_PYTHON"
}

# ── Helpers ───────────────────────────────────────────────────

service_active() {
    systemctl is-active --quiet "$SERVICE" 2>/dev/null
}

header() {
    echo ""
    echo "  ── $* ──"
}

_check_file() {
    local path="$1" label="$2"
    if [ -f "$path" ]; then
        local age
        age=$(python3 -c "
import os, time
t = os.path.getmtime('$path')
print(time.strftime('%Y-%m-%d %H:%M', time.localtime(t)))
" 2>/dev/null || echo "?")
        printf "  %-22s %s  (%s)\n" "$label" "$path" "$age"
    else
        printf "  %-22s NOT FOUND  %s\n" "$label" "$path"
    fi
}

# ── Commands ──────────────────────────────────────────────────

cmd_start() {
    header "Starting WeeWX"
    sudo systemctl start "$SERVICE"
    echo "  Started."
    systemctl status "$SERVICE" --no-pager --lines=3 || true
}

cmd_stop() {
    header "Stopping WeeWX"
    sudo systemctl stop "$SERVICE"
    echo "  Stopped."
}

cmd_restart() {
    header "Restarting WeeWX"
    sudo systemctl restart "$SERVICE"
    echo "  Restarted."
    systemctl status "$SERVICE" --no-pager --lines=3 || true
}

cmd_status() {
    header "WeeWX Service"
    systemctl status "$SERVICE" --no-pager || true

    header "Database"
    if [ -f "$WEEWX_DB" ]; then
        DB_SIZE=$(du -sh "$WEEWX_DB" | cut -f1)
        DB_INFO=$(python3 -c "
import sqlite3, time
try:
    conn = sqlite3.connect('$WEEWX_DB')
    n      = conn.execute('SELECT COUNT(*) FROM archive').fetchone()[0]
    latest = conn.execute('SELECT dateTime FROM archive ORDER BY dateTime DESC LIMIT 1').fetchone()
    conn.close()
    ts = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(latest[0])) if latest else 'N/A'
    print(f'records: {n}  |  latest: {ts}')
except Exception as e:
    print(f'could not read: {e}')
" 2>/dev/null || echo "could not read")
        echo "  Path : $WEEWX_DB  ($DB_SIZE)"
        echo "  $DB_INFO"
    else
        echo "  Not found: $WEEWX_DB"
        echo "  (Created automatically on first WeeWX run)"
    fi

    header "Sensor Map"
    python3 - <<'PYEOF' 2>/dev/null || echo "  Could not read sensor map"
import re, os
conf = "/etc/weewx/weewx.conf"
if not os.path.exists(conf):
    print("  weewx.conf not found")
else:
    with open(conf) as f:
        content = f.read()
    m = re.search(r'\[\[sensor_map\]\](.*?)(?=^\s*\[|\Z)', content, re.DOTALL | re.MULTILINE)
    if m:
        lines = [l.strip() for l in m.group(1).strip().splitlines() if l.strip() and not l.strip().startswith('#')]
        for line in lines:
            print(f"  {line}")
    else:
        print("  No sensor_map found in weewx.conf")
PYEOF
    echo ""

    header "Deployed Files"
    _check_file "$WEEWX_CONF_DEST"              "weewx.conf"
    _check_file "$NODEBOT_PLUGINS/weewx.py"     "NodeBot plugin"
    _check_file "$NOMADNET_PAGES/weewx/weewx.mu"       "NomadNet page"
    _check_file "$NOMADNET_PAGES/weewx/graph_temp.mu"  "  graph_temp.mu"
    _check_file "$NOMADNET_PAGES/weewx/graph_wind.mu"  "  graph_wind.mu"
    _check_file "$NOMADNET_PAGES/weewx/status.mu"      "  status.mu"
    echo ""
}

cmd_logs() {
    header "WeeWX Logs  (Ctrl-C to exit)"
    echo ""
    journalctl -u "$SERVICE" -f --no-hostname
}

cmd_deploy() {
    header "Redeploying Files"

    # ── weewx.py → NodeBot plugins ───────────────────────────
    if [ -f "$PLUGIN_SRC" ]; then
        if [ -d "$NODEBOT_PLUGINS" ]; then
            cp "$PLUGIN_SRC" "$NODEBOT_PLUGINS/weewx.py"
            echo "  Deployed: $NODEBOT_PLUGINS/weewx.py"
        else
            echo "  ⚠  NodeBot plugins directory not found: $NODEBOT_PLUGINS"
            echo "     Update the path with:  bash installer/manage_weewx.sh set-nodebot"
        fi
    else
        echo "  ⚠  Plugin source not found: $PLUGIN_SRC"
    fi

    # ── NomadNet pages ────────────────────────────────────────
    if [ -d "$PAGE_SRC_DIR" ] && [ -d "$NOMADNET_PAGES" ]; then
        if [ -d "$PAGE_SRC_DIR/weewx" ]; then
            mkdir -p "$NOMADNET_PAGES/weewx"
            cp -r "$PAGE_SRC_DIR/weewx/." "$NOMADNET_PAGES/weewx/"
            echo "  Deployed: $NOMADNET_PAGES/weewx/ ($(ls "$PAGE_SRC_DIR/weewx" | wc -l | tr -d ' ') files)"
            setup_pages_venv "$NOMADNET_PAGES/weewx"
        fi
        if [ -f "$PAGE_SRC_DIR/index.mu" ]; then
            if [ -f "$NOMADNET_PAGES/index.mu" ]; then
                printf "  index.mu already exists — overwrite with weewx redirect? [y/N]: "
                read -r _OW_INDEX || true
                _OW_INDEX="${_OW_INDEX:-N}"
            else
                _OW_INDEX="Y"
            fi
            if [[ "$_OW_INDEX" =~ ^[Yy]$ ]]; then
                cp "$PAGE_SRC_DIR/index.mu" "$NOMADNET_PAGES/index.mu"
                chmod +x "$NOMADNET_PAGES/index.mu"
                echo "  Deployed: $NOMADNET_PAGES/index.mu"
            else
                echo "  Skipping index.mu — existing file kept."
            fi
        fi
    elif [ ! -d "$PAGE_SRC_DIR" ]; then
        echo "  ⚠  Template pages not found: $PAGE_SRC_DIR"
    elif [ ! -d "$NOMADNET_PAGES" ]; then
        echo "  ⚠  NomadNet pages directory not found: $NOMADNET_PAGES"
    fi

    # ── NomadNet node name ────────────────────────────────────
    NOMADNET_CONF="$HOME/.nomadnetwork/config"
    if [ -f "$NOMADNET_CONF" ]; then
        CURRENT_NODE_NAME=$(grep -Po '(?<=^node_name = ).*' "$NOMADNET_CONF" || true)
        STATION_NAME=$(python3 -c "
import re
try:
    with open('/etc/weewx/weewx.conf') as f:
        m = re.search(r'^\s*location\s*=\s*(.+)$', f.read(), re.MULTILINE)
    print(m.group(1).strip() if m else '')
except:
    print('')
" 2>/dev/null || true)
        echo ""
        echo "  NomadNet node name  (current: ${CURRENT_NODE_NAME:-<not set>})"
        if [ -n "$STATION_NAME" ]; then
            printf "  Use station name '%s'? [Y/n]: " "$STATION_NAME"
            read -r _USE_STATION || true
            _USE_STATION="${_USE_STATION:-Y}"
            if [[ "$_USE_STATION" =~ ^[Yy]$ ]]; then
                _NODE_NAME="$STATION_NAME"
            else
                printf "  Enter name [keep '%s']: " "${CURRENT_NODE_NAME:-<not set>}"
                read -r _NODE_NAME || true
                _NODE_NAME="${_NODE_NAME:-}"
            fi
        else
            printf "  Enter name [keep '%s']: " "${CURRENT_NODE_NAME:-<not set>}"
            read -r _NODE_NAME || true
            _NODE_NAME="${_NODE_NAME:-}"
        fi
        if [ -n "$_NODE_NAME" ] && [ "$_NODE_NAME" != "$CURRENT_NODE_NAME" ]; then
            _NODE_NAME_SAFE=$(printf '%s\n' "$_NODE_NAME" | sed 's/[&\\]/\\&/g')
            sed -i "s|^node_name = .*|node_name = $_NODE_NAME_SAFE|" "$NOMADNET_CONF"
            echo "  Node name updated: $_NODE_NAME"
        else
            echo "  Node name unchanged."
        fi
    fi

    echo ""
    echo "  Deploy complete."
}

cmd_scan() {
    header "SDR Station Scan"
    echo ""
    bash "$SCRIPT_DIR/scan_sdr.sh" "$@"
}

cmd_db_check() {
    header "Database Check"

    if [ ! -f "$WEEWX_DB" ]; then
        echo "  Database not found: $WEEWX_DB"
        echo "  It will be created automatically when WeeWX first runs."
        return
    fi

    python3 - "$WEEWX_DB" <<'PYEOF'
import sqlite3, sys, time

db = sys.argv[1]
conn = sqlite3.connect(db)

row_count = conn.execute("SELECT COUNT(*) FROM archive").fetchone()[0]
oldest    = conn.execute("SELECT MIN(dateTime) FROM archive").fetchone()[0]
newest    = conn.execute("SELECT MAX(dateTime) FROM archive").fetchone()[0]

def ts(t):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t)) if t else "N/A"

print(f"  Records : {row_count}")
print(f"  Oldest  : {ts(oldest)}")
print(f"  Newest  : {ts(newest)}")

conn.row_factory = sqlite3.Row
row = conn.execute("""
    SELECT outTemp, outHumidity, windSpeed, rain, lightning_distance
    FROM archive ORDER BY dateTime DESC LIMIT 1
""").fetchone()
if row:
    print("")
    print("  Latest observation:")
    for key in row.keys():
        val = row[key]
        print(f"    {key:<26} {val if val is not None else 'NULL'}")

conn.close()
PYEOF
    echo ""
}

cmd_set_nodebot() {
    header "Update NodeBot Plugins Path"
    echo ""
    echo "  Current path: $NODEBOT_PLUGINS"
    echo ""
    printf "  New path (leave blank to keep current): "
    read -r _NEW_PATH || true
    _NEW_PATH="${_NEW_PATH:-$NODEBOT_PLUGINS}"
    _NEW_PATH="${_NEW_PATH%/}"

    if [ ! -d "$_NEW_PATH" ]; then
        echo "  ⚠  Directory not found: $_NEW_PATH"
        echo "     Path not saved."
        return
    fi

    NODEBOT_PLUGINS="$_NEW_PATH"
    echo "NODEBOT_PLUGINS=$NODEBOT_PLUGINS" > "$INSTALL_CONFIG"
    echo "  Saved: $NODEBOT_PLUGINS"
    echo ""
    printf "  Deploy weewx.py there now? [Y/n]: "
    read -r _DO_DEPLOY || true
    _DO_DEPLOY="${_DO_DEPLOY:-Y}"
    if [[ "$_DO_DEPLOY" =~ ^[Yy]$ ]]; then
        cp "$PLUGIN_SRC" "$NODEBOT_PLUGINS/weewx.py"
        echo "  Deployed: $NODEBOT_PLUGINS/weewx.py"
    fi
}

cmd_uninstall() {
    header "Uninstall WeeWX"
    echo ""
    echo "  This will remove:"
    echo "    - weewx systemd service (stopped + disabled)"
    echo "    - weewx apt package and repository"
    echo "    - $WEEWX_CONF_DEST"
    echo "    - $NODEBOT_PLUGINS/weewx.py"
    echo "    - $NOMADNET_PAGES/weewx.mu"
    echo ""
    echo "  The database at $WEEWX_DB will NOT be removed."
    echo ""
    printf "  Type 'yes' to confirm: "
    read -r _CONFIRM || true
    if [ "$_CONFIRM" != "yes" ]; then
        echo "  Aborted."
        return
    fi

    echo ""
    echo "  Stopping service..."
    sudo systemctl stop    "$SERVICE" 2>/dev/null || true
    sudo systemctl disable "$SERVICE" 2>/dev/null || true

    echo "  Removing weewx package..."
    sudo apt-get remove -y weewx 2>/dev/null || true

    echo "  Removing apt repository..."
    sudo rm -f /etc/apt/sources.list.d/weewx.list
    sudo rm -f /etc/apt/trusted.gpg.d/weewx.gpg
    sudo apt-get update -qq 2>/dev/null || true

    echo "  Removing deployed files..."
    sudo rm -f "$WEEWX_CONF_DEST"
    rm -f "$NODEBOT_PLUGINS/weewx.py"
    rm -rf "$NOMADNET_PAGES/weewx"

    echo ""
    echo "  Uninstall complete."
    echo "  Database preserved at: $WEEWX_DB"
    echo ""
}

# ── Interactive menu ──────────────────────────────────────────

show_menu() {
    local status
    if service_active; then
        status="running"
    else
        status="stopped"
    fi

    echo ""
    echo "================================================"
    echo "  WeeWX Manager  (service: $status)"
    echo "================================================"
    echo ""
    echo "  1) Status"
    echo "  2) Start"
    echo "  3) Stop"
    echo "  4) Restart"
    echo "  5) View logs"
    echo "  6) Redeploy files"
    echo "  7) SDR station scan"
    echo "  8) Database check"
    echo "  9) Set NodeBot path"
    echo "  0) Uninstall"
    echo "  q) Quit"
    echo ""
    printf "  Choice: "
}

run_menu() {
    while true; do
        show_menu
        read -r CHOICE || true
        case "$CHOICE" in
            1) cmd_status      ;;
            2) cmd_start       ;;
            3) cmd_stop        ;;
            4) cmd_restart     ;;
            5) cmd_logs        ;;
            6) cmd_deploy      ;;
            7) cmd_scan        ;;
            8) cmd_db_check    ;;
            9) cmd_set_nodebot ;;
            0) cmd_uninstall   ;;
            q|Q) echo ""; exit 0 ;;
            *) echo "  Unknown option: $CHOICE" ;;
        esac
    done
}

# ── Entry point ───────────────────────────────────────────────

case "${1:-}" in
    start)        cmd_start        ;;
    stop)         cmd_stop         ;;
    restart)      cmd_restart      ;;
    status)       cmd_status       ;;
    logs)         cmd_logs         ;;
    deploy)       cmd_deploy       ;;
    scan)         cmd_scan "${@:2}";;
    db-check)     cmd_db_check     ;;
    set-nodebot)  cmd_set_nodebot  ;;
    uninstall)    cmd_uninstall    ;;
    "")           run_menu         ;;
    *)
        echo "Unknown command: $1"
        echo "Usage: $0 [start|stop|restart|status|logs|deploy|scan|db-check|set-nodebot|uninstall]"
        exit 1
        ;;
esac
