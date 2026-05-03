# Nomad-WeeWX

Receive weather data from an RF weather station using a software-defined radio
(SDR) dongle, store it with [WeeWX](https://weewx.com), and serve live
conditions over a [Reticulum](https://reticulum.network) mesh network via
[NomadNet](https://github.com/markqvist/NomadNet) pages.

## Hardware Requirements

- **RTL-SDR dongle** — tested with RTL-SDR Blog V4 (`0bda:2838`)
- **Compatible weather station** — tested with AcuRite Atlas; other AcuRite
  models and many other brands are supported via
  [rtl_433](https://github.com/merbanan/rtl_433)
- Raspberry Pi or any Debian/Ubuntu-based Linux system

## What Gets Installed

| Component | Description |
|---|---|
| WeeWX v5 | Weather station software, records data to SQLite |
| weewx-sdr | WeeWX driver for SDR dongles |
| rtl-sdr / rtl_433 | RTL-SDR kernel driver and RF decoder |
| NomadNet pages | Weather pages served over the mesh network |

## Quick Start

```bash
git clone https://github.com/JamesM92/WeeWX.git
cd WeeWX
bash installer/install_weewx.sh
```

The installer will walk you through each step interactively:

1. Install system packages
2. Install RTL-SDR and rtl_433
3. Scan the airwaves to detect your weather station and generate the sensor map
4. Install WeeWX v5
5. Install the weewx-sdr extension
6. Deploy `weewx.conf`
7. Deploy companion files (NodeBot plugin, NomadNet pages) — optional

Plug in the SDR dongle before step 3.

## Day-to-Day Management

```bash
bash installer/manage_weewx.sh
```

Interactive menu for starting/stopping WeeWX, redeploying files, re-scanning
for station changes, and inspecting the database.

Common one-liners:

```bash
bash installer/manage_weewx.sh status    # service status + sensor map
bash installer/manage_weewx.sh logs      # live log tail
bash installer/manage_weewx.sh scan      # re-scan SDR for station changes
bash installer/manage_weewx.sh deploy    # redeploy pages and config
```

## Re-scanning After a Station Change

If you replace your weather station or want to update the sensor map:

```bash
bash installer/scan_sdr.sh
```

The scan stops WeeWX while the dongle is in use and restarts it automatically
when done.

## NomadNet Pages

Pages are deployed to `~/.nomadnetwork/storage/pages/weewx/` and served at:

| Path | Description |
|---|---|
| `/page/weewx/weewx.mu` | Current conditions, lightning alert, daily min/max |
| `/page/weewx/graph_temp.mu` | 24-hour temperature, heat index, humidity graph |
| `/page/weewx/graph_wind.mu` | 24-hour wind speed and rain graph |

An `index.mu` redirect is also deployed to the pages root so visitors see the
weather page by default.

Each page project gets its own isolated Python venv with dependencies from
`requirements.txt`, installed automatically by the installer.

## NodeBot Plugin (Optional)

If you use [NodeBot](https://github.com/JamesM92/NodeBot), the installer can
optionally deploy `templates/weewx.py` as a plugin, adding a `weather` command
to your bot. It is not required and can be skipped during installation.

## Project Structure

```
WeeWX/
├── installer/
│   ├── install_weewx.sh    # full setup installer
│   ├── manage_weewx.sh     # day-to-day manager
│   └── scan_sdr.sh         # interactive SDR station scanner
└── templates/
    ├── weewx.py            # NodeBot plugin
    └── nomadpages/
        ├── index.mu        # NomadNet index redirect
        └── weewx/
            ├── weewx.mu        # main conditions page
            ├── graph_temp.mu   # temperature graph
            ├── graph_wind.mu   # wind/rain graph
            ├── status.mu       # network status
            └── requirements.txt
```

## Credits

Nomad-WeeWX is built almost entirely on the work of others. Without the
following projects this would not exist:

**[WeeWX](https://weewx.com)** by Tom Keffer and Matthew Wall
— the weather station software at the core of everything here. All data
collection, archiving, and processing is handled by WeeWX. Please consider
supporting the project at [weewx.com](https://weewx.com).

**[weewx-sdr](https://github.com/matthewwall/weewx-sdr)** by Matthew Wall
— the WeeWX driver that makes SDR dongles work as a weather station input.
This project would not be possible without it.

**[rtl_433](https://github.com/merbanan/rtl_433)** by Benjamin Larsson and contributors
— decodes the RF transmissions from the weather station and feeds them to
weewx-sdr.

**[NomadNet](https://github.com/markqvist/NomadNet)** by Mark Qvist
— the mesh network node software that serves the weather pages over Reticulum.

**[uniplot](https://github.com/olavolav/uniplot)** by Olav Stetter
— terminal graph rendering used in the NomadNet graph pages.

**[Ansi2MicronMU](https://github.com/JamesM92/Ansi2MicronMU)**
— converts ANSI terminal output to NomadNet MicronMU markup.

## License

MIT — see [LICENSE](LICENSE)
