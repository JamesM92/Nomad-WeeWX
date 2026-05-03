#!/bin/bash
# ============================================================
# Nomad-WeeWX Installer
#
# Full setup from SDR dongle to running service:
#   1. System packages
#   2. RTL-SDR + rtl_433
#   3. Install WeeWX v5
#   4. Install weewx-sdr extension
#   5. SDR scan — detect station, generate sensor_map
#   6. Deploy files to companion projects
#
# WeeWX and weewx-sdr manage their own weewx.conf. This installer
# does not overwrite it — the SDR scan applies only the sensor_map.
#
# Companion deployments (optional):
#   weewx.py   → NodeBot plugins directory (path confirmed with user)
#   weewx.mu   → ~/.nomadnetwork/storage/pages/weewx/
#
# Usage (from project root or anywhere):
#   bash installer/install_weewx.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Saved config (persists NodeBot path for the manager) ──────
INSTALL_CONFIG="$PROJECT_DIR/.install_config"

# ── Fixed paths ───────────────────────────────────────────────
NOMADNET_PAGES="$HOME/.nomadnetwork/storage/pages"
WEEWX_DB_DIR="/var/lib/weewx"
SDR_PLUGIN_URL="https://github.com/matthewwall/weewx-sdr/archive/master.zip"

# ── Template sources ──────────────────────────────────────────
TEMPLATES_DIR="$PROJECT_DIR/templates"
PLUGIN_SRC="$TEMPLATES_DIR/weewx.py"
PAGE_SRC_DIR="$TEMPLATES_DIR/nomadpages"

# NodeBot default — loaded from saved config if present, overridden by user prompt
NODEBOT_PLUGINS_DEFAULT="/home/$(whoami)/NodeBot/src/plugins"
if [ -f "$INSTALL_CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$INSTALL_CONFIG"
fi
NODEBOT_PLUGINS="${NODEBOT_PLUGINS:-$NODEBOT_PLUGINS_DEFAULT}"

# ── setup_pages_venv ─────────────────────────────────────────
# General-purpose helper for NomadNet page projects.
#
# Given a project subfolder under pages/, this function:
#   1. Creates (or updates) a .venv inside that subfolder
#   2. Installs deps from the subfolder's requirements.txt
#   3. Rewrites the shebang of every python .mu script in that
#      subfolder to point at the venv's python3, so that
#      NomadNet's subprocess.run([file_path]) picks up the
#      correct interpreter without any activation step.
#
# Each project gets its own isolated venv — no shared state
# with other page projects.
#
# Usage: setup_pages_venv <project_pages_dir>
#   e.g. setup_pages_venv ~/.nomadnetwork/storage/pages/weewx
# ──────────────────────────────────────────────────────────────
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

    # Prefer uv for speed, fall back to stdlib venv
    if command -v uv >/dev/null 2>&1; then
        uv venv "$VENV_DIR" --quiet
        uv pip install --quiet -r "$REQ" --python "$VENV_DIR/bin/python3"
    else
        python3 -m venv "$VENV_DIR"
        "$VENV_DIR/bin/pip" install --quiet -r "$REQ"
    fi

    local VENV_PYTHON="$VENV_DIR/bin/python3"
    echo "  Installed: $(tr '\n' ' ' < "$REQ")"

    # Rewrite shebang of every python .mu in this project dir only
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

echo ""
echo "================================================"
echo "  Nomad-WeeWX Installer"
echo "================================================"
echo "  Project    : $PROJECT_DIR"
echo "  DB dir     : $WEEWX_DB_DIR"
echo "  NomadNet   : $NOMADNET_PAGES/weewx/"
echo "================================================"
echo "  Templates  : $TEMPLATES_DIR"
echo "================================================"
echo ""

# ── Step 1: System packages ───────────────────────────────────
echo "[1/6] Checking system packages..."

MISSING=()
command -v python3 >/dev/null 2>&1 || MISSING+=("python3")
command -v pip3    >/dev/null 2>&1 || MISSING+=("python3-pip")
command -v wget    >/dev/null 2>&1 || MISSING+=("wget")
command -v curl    >/dev/null 2>&1 || MISSING+=("curl")

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "  Installing: ${MISSING[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${MISSING[@]}"
else
    echo "  Base packages already present."
fi

# ── Step 2: RTL-SDR and rtl_433 ───────────────────────────────
echo ""
echo "[2/6] Installing RTL-SDR and rtl_433..."

SDR_PKGS=()
dpkg -s rtl-sdr       >/dev/null 2>&1 || SDR_PKGS+=("rtl-sdr")
dpkg -s librtlsdr-dev >/dev/null 2>&1 || SDR_PKGS+=("librtlsdr-dev")

if [ ${#SDR_PKGS[@]} -gt 0 ]; then
    echo "  Installing RTL-SDR packages: ${SDR_PKGS[*]}"
    sudo apt-get install -y "${SDR_PKGS[@]}"
else
    echo "  rtl-sdr already installed."
fi

RTL_433_AVAILABLE=false
if ! command -v rtl_433 >/dev/null 2>&1; then
    echo "  Installing rtl_433..."
    if sudo apt-get install -y rtl-433 2>/dev/null; then
        echo "  rtl_433 installed via apt."
        RTL_433_AVAILABLE=true
    else
        echo ""
        echo "  ⚠  rtl_433 not available in apt for this OS version."
        echo "     Install it manually from source:"
        echo "       https://github.com/merbanan/rtl_433"
        echo "     Then re-run this installer."
        echo ""
        printf "  Continue without rtl_433? [y/N]: "
        read -r _CONT || true
        _CONT="${_CONT:-N}"
        if [[ ! "$_CONT" =~ ^[Yy]$ ]]; then
            echo "  Aborting."
            exit 1
        fi
    fi
else
    echo "  rtl_433 already installed."
    RTL_433_AVAILABLE=true
fi

# ── Step 3: Install WeeWX ─────────────────────────────────────
echo ""
echo "[3/6] Installing WeeWX v5..."

if command -v weectl >/dev/null 2>&1; then
    echo "  WeeWX already installed."
else
    echo "  Adding WeeWX apt repository..."

    # Import signing key
    wget -qO /tmp/weewx.gpg.html https://weewx.com/keys.html
    gpg --dearmor < /tmp/weewx.gpg.html \
        | sudo tee /etc/apt/trusted.gpg.d/weewx.gpg > /dev/null
    rm -f /tmp/weewx.gpg.html

    # WeeWX uses 'buster' as a universal dist across all Debian/Pi OS versions
    echo "deb [arch=all] https://weewx.com/apt/python3 buster main" \
        | sudo tee /etc/apt/sources.list.d/weewx.list > /dev/null

    echo "  Installing weewx package..."
    sudo apt-get update -qq
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y weewx

    echo "  WeeWX installed."
fi

echo "  Ensuring database directory: $WEEWX_DB_DIR"
sudo mkdir -p "$WEEWX_DB_DIR"
sudo chown weewx:weewx "$WEEWX_DB_DIR" 2>/dev/null \
    || sudo chown "$(whoami):$(whoami)" "$WEEWX_DB_DIR" 2>/dev/null || true

# ── RTL-SDR udev rules + weewx group access ───────────────────
# Without this, rtl_433 fails with "usb_open error -3" when
# running as the weewx service user.
UDEV_SRC="/usr/lib/udev/rules.d/60-librtlsdr0.rules"
UDEV_DEST="/etc/udev/rules.d/60-librtlsdr0.rules"
if [ -f "$UDEV_SRC" ] && [ ! -f "$UDEV_DEST" ]; then
    echo "  Installing RTL-SDR udev rules..."
    sudo cp "$UDEV_SRC" "$UDEV_DEST"
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    echo "  Udev rules installed."
elif [ ! -f "$UDEV_SRC" ]; then
    echo "  ⚠  RTL-SDR udev rules not found at $UDEV_SRC — skipping."
    echo "     If WeeWX fails with 'usb_open error -3', install the rules manually."
else
    echo "  RTL-SDR udev rules already in place."
fi

echo "  Adding weewx to plugdev group (required for SDR dongle access)..."
sudo usermod -aG plugdev weewx

sudo systemctl daemon-reload
sudo systemctl enable weewx
echo "  weewx.service enabled."

# ── Step 4: Install weewx-sdr extension ──────────────────────
echo ""
echo "[4/6] Installing weewx-sdr extension..."

SDR_PY_PATHS=(
    "/usr/share/weewx/user/sdr.py"
    "/etc/weewx/bin/user/sdr.py"
    "$HOME/weewx-data/bin/user/sdr.py"
)
SDR_INSTALLED=false
for sdr_path in "${SDR_PY_PATHS[@]}"; do
    if [ -f "$sdr_path" ]; then
        echo "  weewx-sdr already installed at: $sdr_path"
        SDR_INSTALLED=true
        break
    fi
done

if [ "$SDR_INSTALLED" = false ]; then
    echo "  Downloading weewx-sdr from GitHub..."
    wget -q -O /tmp/weewx-sdr.zip "$SDR_PLUGIN_URL"
    echo "  Installing extension..."
    sudo weectl extension install /tmp/weewx-sdr.zip --yes
    rm -f /tmp/weewx-sdr.zip
    echo "  weewx-sdr extension installed."
fi

# ── Step 5: SDR station scan ──────────────────────────────────
echo ""
echo "[5/6] SDR station scan..."
echo ""

if $RTL_433_AVAILABLE; then
    echo "  This step scans the airwaves to identify your weather station"
    echo "  and automatically generates the correct sensor_map for weewx.conf."
    echo ""
    echo "  Make sure your SDR dongle is plugged in before continuing."
    echo ""

    # Verify the dongle is visible on USB before asking to scan
    if lsusb | grep -q "0bda:"; then
        echo "  ✓  RTL-SDR dongle detected on USB."
    else
        echo "  ⚠  No RTL-SDR dongle detected (no device with vendor 0bda found)."
        echo "     Plug in the dongle now, then press Enter to re-check, or"
        printf "     type 's' to skip the scan: "
        read -r _WAIT || true
        if [[ "$_WAIT" =~ ^[Ss]$ ]]; then
            _DO_SCAN="N"
        elif lsusb | grep -q "0bda:"; then
            echo "  ✓  RTL-SDR dongle detected."
        else
            echo "  ⚠  Still not detected — skipping scan."
            echo "     Re-run later with: bash installer/scan_sdr.sh"
            _DO_SCAN="N"
        fi
    fi

    if [ "${_DO_SCAN:-Y}" != "N" ]; then
        printf "  Run scan now? [Y/n]: "
        read -r _DO_SCAN || true
        _DO_SCAN="${_DO_SCAN:-Y}"
    fi
    echo ""

    if [[ "$_DO_SCAN" =~ ^[Yy]$ ]]; then
        if ! bash "$SCRIPT_DIR/scan_sdr.sh"; then
            echo ""
            echo "  ⚠  Scan did not complete — sensor_map not yet configured."
            echo "     Re-run the scan at any time:"
            echo "       bash installer/scan_sdr.sh"
        fi
    else
        echo "  Skipping. Re-run later with:"
        echo "    bash installer/scan_sdr.sh"
        echo "    bash installer/manage_weewx.sh scan"
    fi
else
    echo "  rtl_433 not available — skipping scan."
    echo "  Once rtl_433 is installed, run: bash installer/scan_sdr.sh"
fi

# ── Step 6: Deploy to companion projects ─────────────────────
echo ""
echo "[6/6] Deploying to companion projects..."
echo ""

# ── 7a: weewx.py → NodeBot plugins ──────────────────────────
printf "  Deploy NodeBot plugin (weewx.py)? [y/N]: "
read -r _USE_NODEBOT || true
_USE_NODEBOT="${_USE_NODEBOT:-N}"

if [[ "$_USE_NODEBOT" =~ ^[Yy]$ ]]; then
    echo ""
    echo "  weewx.py registers a 'weather' command in NodeBot."
    echo "  It needs to be placed in NodeBot's plugins directory."
    echo ""

    # Show current / default path and let user confirm or change it
    echo "  NodeBot plugins directory"
    printf "  [default: %s]: " "$NODEBOT_PLUGINS"
    read -r _NB_INPUT || true
    _NB_INPUT="${_NB_INPUT:-$NODEBOT_PLUGINS}"

    # Strip trailing slash
    NODEBOT_PLUGINS="${_NB_INPUT%/}"

    if [ -f "$PLUGIN_SRC" ]; then
        if [ -d "$NODEBOT_PLUGINS" ]; then
            PLUGIN_DEST="$NODEBOT_PLUGINS/weewx.py"
            if [ -f "$PLUGIN_DEST" ]; then
                PLUGIN_BAK="${PLUGIN_DEST}.bak.$(date +%Y%m%d_%H%M%S)"
                cp "$PLUGIN_DEST" "$PLUGIN_BAK"
                echo "  Backed up existing plugin → $PLUGIN_BAK"
            fi
            cp "$PLUGIN_SRC" "$PLUGIN_DEST"
            echo "  Deployed: $PLUGIN_DEST"
        else
            echo ""
            echo "  ⚠  Directory not found: $NODEBOT_PLUGINS"
            echo "     weewx.py was NOT copied. Move it manually once NodeBot is set up:"
            echo "       cp $PLUGIN_SRC <nodebot-plugins-dir>/weewx.py"
            echo "     Then restart NodeBot."
            NODEBOT_PLUGINS="$NODEBOT_PLUGINS_DEFAULT"   # reset to default for config save
        fi
    else
        echo "  ⚠  weewx.py not found at $PLUGIN_SRC — skipping."
    fi

    # Save the confirmed NodeBot path for the manager to use
    echo "NODEBOT_PLUGINS=$NODEBOT_PLUGINS" > "$INSTALL_CONFIG"
else
    echo "  Skipping NodeBot deployment."
fi
echo ""

# ── 7b: NomadNet pages ───────────────────────────────────────
printf "  Deploy NomadNet pages? [y/N]: "
read -r _USE_NOMADNET || true
_USE_NOMADNET="${_USE_NOMADNET:-N}"

if [[ "$_USE_NOMADNET" =~ ^[Yy]$ ]]; then
    # Deploys:
    #   templates/nomadpages/weewx/  → pages/weewx/  (all pages including weewx.mu)
    echo ""
    if [ ! -d "$PAGE_SRC_DIR" ]; then
        echo "  ⚠  Template pages not found at $PAGE_SRC_DIR — skipping."
    elif [ ! -d "$NOMADNET_PAGES" ]; then
        echo "  ⚠  NomadNet pages directory not found: $NOMADNET_PAGES"
        echo "     Start NomadNet once to create it, then re-deploy manually:"
        echo "       bash installer/manage_weewx.sh deploy"
    else
        # Deploy the weewx/ directory (contains all pages including weewx.mu)
        if [ -d "$PAGE_SRC_DIR/weewx" ]; then
            mkdir -p "$NOMADNET_PAGES/weewx"
            cp -r "$PAGE_SRC_DIR/weewx/." "$NOMADNET_PAGES/weewx/"
            echo "  Deployed: $NOMADNET_PAGES/weewx/ ($(ls "$PAGE_SRC_DIR/weewx" | wc -l | tr -d ' ') files)"

            # Set up this project's isolated venv and rewrite shebangs
            setup_pages_venv "$NOMADNET_PAGES/weewx"
        fi

        # Deploy index.mu redirect to pages root
        if [ -f "$PAGE_SRC_DIR/index.mu" ]; then
            cp "$PAGE_SRC_DIR/index.mu" "$NOMADNET_PAGES/index.mu"
            chmod +x "$NOMADNET_PAGES/index.mu"
            echo "  Deployed: $NOMADNET_PAGES/index.mu"
        fi

        # ── NomadNet node name ────────────────────────────────
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
    fi
else
    echo "  Skipping NomadNet deployment."
fi

# ── Start WeeWX? ──────────────────────────────────────────────
echo ""
printf "  Start WeeWX service now? [Y/n]: "
read -r _START || true
_START="${_START:-Y}"
if [[ "$_START" =~ ^[Yy]$ ]]; then
    sudo systemctl start weewx
    echo "  WeeWX started."
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Installation complete."
echo "================================================"
echo ""
echo "  WeeWX service  : sudo systemctl start|stop|restart weewx"
echo "  Logs           : journalctl -u weewx -f"
echo "  Manager        : bash installer/manage_weewx.sh"
echo "  Re-scan SDR    : bash installer/scan_sdr.sh"
echo ""
if [[ "$_USE_NODEBOT" =~ ^[Yy]$ ]]; then
    echo "  NodeBot plugin : $NODEBOT_PLUGINS/weewx.py"
fi
if [[ "$_USE_NOMADNET" =~ ^[Yy]$ ]]; then
    echo "  NomadNet pages : $NOMADNET_PAGES/weewx/"
fi
echo ""
