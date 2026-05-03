# WeeWX NomadNet Pages

A self-contained set of NomadNet pages that display live weather data from a
WeeWX weather station. Includes a main conditions page, temperature graph,
wind/rain graph, and a network status page.

## Pages

| File | NomadNet path | Description |
|---|---|---|
| `weewx.mu` | `/page/weewx/weewx.mu` | Main page — current conditions, lightning alert, daily min/max |
| `graph_temp.mu` | `/page/weewx/graph_temp.mu` | 24-hour temperature, heat index, and humidity graph |
| `graph_wind.mu` | `/page/weewx/graph_wind.mu` | 24-hour wind speed and rain graph |
| `status.mu` | `/page/weewx/status.mu` | Network interface status (runs `rnstatus`) |

## Requirements

- [WeeWX](https://weewx.com) running and writing to `/var/lib/weewx/weewx.sdb`
- [NomadNet](https://github.com/markqvist/NomadNet) installed and running
- Python 3.9+

Python package dependencies are listed in `requirements.txt` and are installed
automatically into an isolated `.venv/` inside this directory by the installer.
You do not need to install them globally.

## Installation

Use the project installer from the repository root — it handles WeeWX, the SDR
driver, and deploys these pages in one pass:

```bash
bash installer/install_weewx.sh
```

To redeploy only the pages (e.g. after updating templates):

```bash
bash installer/manage_weewx.sh deploy
```

The installer will:
1. Copy all files in this directory to `~/.nomadnetwork/storage/pages/weewx/`
2. Create a `.venv/` inside that directory and install `requirements.txt`
3. Rewrite the shebang line of each `.mu` script to point at the venv's
   `python3`, so NomadNet's subprocess call picks up the correct interpreter

## Manual installation

If you are not using the installer:

```bash
PAGES=~/.nomadnetwork/storage/pages

# Copy pages
mkdir -p "$PAGES/weewx"
cp -r . "$PAGES/weewx/"

# Create venv and install deps
python3 -m venv "$PAGES/weewx/.venv"
"$PAGES/weewx/.venv/bin/pip" install -r "$PAGES/weewx/requirements.txt"

# Rewrite shebangs
PYTHON="$PAGES/weewx/.venv/bin/python3"
for f in "$PAGES/weewx/"*.mu; do
    sed -i "1s|.*|#!$PYTHON|" "$f"
    chmod +x "$f"
done
```

## Making weewx.mu your site's index page

NomadNet serves `index.mu` as the default page when a visitor connects without
specifying a path. If you want the weather page to be the only thing your node
hosts, redirect `index.mu` to `weewx.mu`.

Create or replace `~/.nomadnetwork/storage/pages/index.mu` with:

```python
#!/usr/bin/python3
import subprocess, os, sys

# Set this to the page you want to redirect to, relative to the pages/ directory
TARGET = "weewx/weewx.mu"

page = os.path.join(os.path.dirname(os.path.abspath(__file__)), *TARGET.split("/"))
result = subprocess.run([page], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
sys.stdout.buffer.write(result.stdout)
```

Then make it executable:

```bash
chmod +x ~/.nomadnetwork/storage/pages/index.mu
```

This works because the installer rewrites the shebang in `weewx.mu` to point
at the venv's `python3`, so calling it directly picks up all installed
dependencies without any activation step.

## Adding dependencies for future projects

This directory follows a per-project venv pattern that any NomadNet page
project can reuse:

1. Create a subfolder under `pages/` for your project
2. Add a `requirements.txt` listing your Python dependencies
3. Call `setup_pages_venv <your-subfolder>` from your installer (the function
   is defined in `installer/install_weewx.sh` and `installer/manage_weewx.sh`
   and can be copied into any installer script)

Each project gets its own isolated `.venv/` with no shared state between
projects. Adding or updating one project's dependencies cannot break another.

## File layout after deployment

```
~/.nomadnetwork/storage/pages/
└── weewx/
    ├── .venv/                  # isolated venv (created by installer)
    ├── requirements.txt
    ├── weewx.mu                # main weather page
    ├── graph_temp.mu           # temperature graph
    ├── graph_wind.mu           # wind/rain graph
    └── status.mu               # network status
```
