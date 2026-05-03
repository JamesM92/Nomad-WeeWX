#!/usr/bin/python3

import sqlite3
import re
from time import strftime, localtime
from datetime import datetime

# =====================================================
# Configuration
# =====================================================

DATABASE    = "/var/lib/weewx/weewx.sdb"
WEEWX_CONF  = "/etc/weewx/weewx.conf"

def get_station_name():
    try:
        with open(WEEWX_CONF) as f:
            content = f.read()
        m = re.search(r'^\s*location\s*=\s*(.+)$', content, re.MULTILINE)
        if m:
            return m.group(1).strip()
    except:
        pass
    return "Weather Station"

STATION_NAME = get_station_name()

# Lightning Settings (CONFIGURABLE)
LIGHTNING_MAX_DISTANCE = 31     # Hide lightning if >= this value
LIGHTNING_ALERT_DISTANCE = 10    # Show header banner & highlight below this

DATA_POINTS = [
    "dateTime","usUnits","interval","appTemp","cloudbase","dewpoint",
    "heatindex","humidex","lightning_distance","lightning_strike_count",
    "maxSolarRad","outHumidity","outTemp","rain","rainRate","windchill",
    "windGust","windrun","windSpeed","windDir"
]

LABEL_WIDTH = 16
VALUE_WIDTH = 18
BOX_WIDTH   = 28

DIRECTIONS = [
    "N","NNE","NE","ENE","E","ESE","SE","SSE",
    "S","SSW","SW","WSW","W","WNW","NW","NNW"
]

# =====================================================
# Helpers
# =====================================================

def fmt(val, fmtstr, unit=""):
    if val is None:
        return "NA"
    try:
        return f"{fmtstr.format(val)}{unit}"
    except:
        return "NA"


def trend(curr, prev, threshold=0.01):
    if curr is None or prev is None:
        return ""
    diff = curr - prev
    if abs(diff) < threshold:
        return " →"
    return " ↑" if diff > 0 else " ↓"


def wind_dir(deg):
    if deg is None:
        return "NA"
    card = int((deg + 11.25) / 22.5) % 16
    return f"{deg:.2f}° - {DIRECTIONS[card]}"


def render_line(label, value, box=""):
    return f"{label:<{LABEL_WIDTH}}{value:<{VALUE_WIDTH}}{box:<{BOX_WIDTH}}"

# =====================================================
# Database
# =====================================================

def fetch_latest_two():
    conn = sqlite3.connect(DATABASE)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    cur.execute(f"""
        SELECT {", ".join(DATA_POINTS)}
        FROM archive
        ORDER BY dateTime DESC
        LIMIT 2
    """)

    rows = cur.fetchall()
    conn.close()

    if not rows:
        return None, None

    return rows[0], rows[1] if len(rows) > 1 else None


def get_daily_min_max(field):
    conn = sqlite3.connect(DATABASE)
    cur = conn.cursor()

    now = datetime.now()
    start = datetime(now.year, now.month, now.day)
    start_ts = int(start.timestamp())

    cur.execute(f"""
        SELECT MIN({field}), MAX({field})
        FROM archive
        WHERE dateTime >= ?
    """, (start_ts,))

    row = cur.fetchone()
    conn.close()

    return row if row else (None, None)

# =====================================================
# MAIN
# =====================================================

data, prev = fetch_latest_two()

if not data:
    print("Weather data unavailable.")
    exit()

# =====================================================
# Lightning Nearby Check (HEADER BANNER)
# =====================================================

lightning_nearby = False

try:
    ld = data["lightning_distance"]
    if ld is not None:
        ld = float(ld)
        if 0 < ld < LIGHTNING_ALERT_DISTANCE:
            lightning_nearby = True
except:
    pass


# =====================================================
# HEADER
# =====================================================

print("#!bg=222")
print(f"`cWelcome to the {STATION_NAME} Node!")

# ---- WEATHER ICON (KEEP YOUR FULL ORIGINAL BLOCK HERE) ----
print("`c"
"""`Ffff@@@@@@@@@Q@@@@@@@@@@@@@@@@@@@@@@@@@`f\n"""
"""`Ffff@@@@@TQ@@PM@@QN@@@@@@@@@@@@@7zz[@@@`f\n"""
"""`Ffff@@@@@M`F000t`Ffff@@@@@@`F000q`Ffff@@@@@@@@@@@@@ `Fbdfg`Fcef@@`Fbefg`Ffff7@@`f\n"""
"""`Ffff@@@@@@@@[[[Q@@@@@@@@@@@@@@Q`F000>`Fcef@MM@ `FfffN@`f\n"""
"""`Ffff@@gt@@Q`Fff02`Ffe7g`Ffe8WB`Ffe7p`Fff0\"`Ffff@@@2W@@@@@@@@V`F000:`Fccf[[[[ `FfffN@`f\n"""
"""`Ffff@@@@@(`Fff0S`Ffe8@MMMMM`Fff0'`FfffQ@@@@@@@@@@@V `Ff79BHBB `FfffN@`f\n"""
"""`Ffff@@@@@`F000?`Ffe7@`Ffe8MMMMMM`Ffd6Q`Fff7T`Ffff>`F3bfz`F5dfuu`F6cfx`FffffQ@@@@V `Ff89MUH`Ff69> `FfffN@`f\n"""
"""`Ffff@UnN@`Fff7z`Ffe8@MMMMM@ `F5afu`F6efM`F6dfM@`F5efQQ`F5dfM`F3cf>`Fffff@@@V `Ff89MUU`Ff79M `FfffN@`f\n"""
"""`Ffff@@@@@`F000'`Ffe7@`Ffe8MMMMM `F5dfm`F6df@UHM`F5dfo`F6cfz`F0ff/`F5df@`F3cf2`Ffff7@@V `Ff89MUB`Ff77T `FfffN@`f\n"""
"""`Ffff@@@@@=`Ffd7N`Ffe8QQQ`Ffe7Q`Ffe8Q`F000>`F6df@UUUUM@`F6efJ`F5ff/`F5df@`F0ff:`Ffff@@V `Ff89MUU`Ff79B `FfffN@`f\n"""
"""`Ffff@@@7M@`Fffd7`F07f~`F4dfux`F5af> `F6cfb`F6dfMUUUUUUM`F6cfu`F5dfM`F3bf:`FfffN@V `Ff89MUU`Ff79Q `FfffN@`f\n"""
"""`Ffff@@gW@ `F5ffq`F6df@QM@`F4dfd`F6dfMUUUUUUUUQM`F4efJ`Ffff\\Q7 `Ff89MUH`Ff69~ `FfffN@`f\n"""
"""`Ffff@@@@@`F5ffS`F6df@UUUUUUUUUUUHUUUUM`F5df@`F4dfM`F4ef( `Ff89M`Ff79XU`Ff89M `FfffN@`f\n"""
"""`Ffff@@@@7`F5dfE`F6efM`F6dfUUUUUUUUUBM`F5dfQ`F6dfBUUUUUM`F6ef( `Ff89M`Ff69:`Ff55>`Ff89M `FfffN@`f\n"""
"""`Ffff@@Q.`F5af~`F5efE`F6dfMUUUUUUUUHM`F5efT `F6cfB`F6dfUUUUUM`F6ef( `Ff89M`Ff69:`Ff77>`Ff89M `FfffN@`f\n"""
"""`Ffff@7`F5ffu`F6efM`F6df@QUUUUUUUUUM`F5ef/ `F000>`F6dfMUUUUBM `F000?`Ff89M`Ff69:`Ff77>`Ff89M `FfffT@`f\n"""
"""`FfffQ`F000>`F6df@UUUUUUUUUUUMT`Fff0~`Ffd3i`F3bfS`F6ef@`F6dfUUUUM`F5dfT`Ff00?`Ff8aB`Ff79Q `Ff0f'`Ff79Q`Ff78U`Ff55:`Ffff@`f\n"""
"""`Ffff:`F5ffn`F6dfMUUUUUUUUUUM$`F000>`Ffd4M `F6efB`F6dfMUUUUM `Ff79B`Ff89M `Ff02>`Ff04.`Ff00'`Ff79M`Ff78U`Ffff/`f\n"""
"""`FfffJ`F0ff'`F6dfMUUUUUUUUUM`F5ef/`F000>`Ffd4M7`F000.`F6dfMUUUUUU `Ff79M`Ff89U `Ff04>> `Ff8aM`Ff79Z`F000>`f\n"""
"""`FfffM\"`F5dfQ`F6dfMMBBBBBBM`F6efT`Fff0~`Ffe4B`Ffe5M `F0ff>`F6efM`F6dfMBBBBM`F6ff:`Ff79Z`Ff89M`Ff55:  `Ff00~`Ff89M`Ff78T`Ffffq`f\n"""
"""`Ffff@@^`F3bf/`F5efQ`F6dfQQQQQ`F5dfQ`F6df$`F000>`Ffe4M`Ffe5MM2`Fff0>`F5af/`F5dfT`F6efQQ`F6dfQQQ`F5efU`Ff00'`Ff79Q`Ff89M`Ff88d`Ff78p`Ff79M`Ff78T`Ff77.`FfffM`f\n"""
"""`Ffff@@@Wgggggg`Fdffg4`Fff0/`Ffe4QQ`Ffe5BM@`Ffd4H:`FfffqggggWg1`Ff77T`Ff787`Ff8a7`Ff77/`F0002`FfffW@`f\n"""
"""`Ffff@@@@@@@@@@@@ggi`Ffd3Z`Ffe5HM`Ffe4/`F000>`Ffff@@@@@@@@gggW@@@`f\n"""
"""`Ffff@@@@@@Q@@@@@@@(`Ffe5BM`Ffe4T`F000S`FfffM@@@@@@@@@@@@@@@`f\n"""
"""`Ffff@QW@@(W@@(M@@@ `Ffd5@ `F000S`Ffff@@@.W@@(M@@@@@@@@`f\n"""
"""`Ffff@M@@@W@@@W@@@(`F000?`Ffd47`Ffffw@@@@W@@@W@@@@@@@@@`f\n"""
"""`Ffff@@@@@@@@@@@@@ `Fff3/`F000S`Ffff@@@@@@@@@@@@@@@@@@@`f\n"""
"""`Ffff@@`F000>`FfffM@Q.@@@`F000S`Ffff@@ `F000>`Ffff@@@`F000~`FfffM@Q`F000>`Ffff@@Qq@@@@@@@@`f\n"""
"""`Ffff@JW@@>W@@=@@@uM@@JM@@>W@@<@@@@@@@@@`f\n"""
"``"
)

# ---- LIGHTNING BANNER ----
if lightning_nearby:
    print("\n`c`FF00!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!`f")
    print("`FF00   ⚡  LIGHTNING NEARBY  ⚡   `f")
    print("`FF00!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!`f\n")

# =====================================================
# CONDITIONS
# =====================================================

print("\n`aCurrent Conditions")

update = strftime('%Y-%m-%d %H:%M:%S', localtime(data["dateTime"]))
print(render_line("Last Updated:", update))
print("`a")

SECTIONS = [

("Heat and Humidity", [
    ("Temperature", "outTemp", "{:.2f}", "°F"),
    ("Humidity", "outHumidity", "{:.0f}", "%RH"),
    ("Heat Index", "heatindex", "{:.2f}", "°F"),
    ("Dew Point", "dewpoint", "{:.2f}", "°F"),
]),

("Wind and Rain", [
    ("Wind Speed", "windSpeed", "{:.2f}", " MPH"),
    ("Wind Chill", "windchill", "{:.2f}", "°F"),
    ("Rain", "rain", "{:.2f}", " IN"),
]),

("Clouds and Lightning", [
    ("Cloud Base", "cloudbase", "{:.2f}", " ft"),
    ("Lightning Dist", "lightning_distance", "{:.2f}", " miles"),
    ("Lightning Strikes", "lightning_strike_count", "{:.0f}", ""),
])

]

for section_name, fields in SECTIONS:

    print("\n    `_`!" + section_name + "`_`!")

    for label, field, fmtstr, unit in fields:

        value = data[field]

        # Lightning rules
        if field in ["rain", "lightning_distance", "lightning_strike_count"]:
            try:
                if value is None:
                    continue
                numeric_value = float(value)

                if field == "rain" and numeric_value <= 0:
                    print(render_line(label, "0.00 IN"))
                    continue

                if field == "lightning_distance":
                    strikes = data["lightning_strike_count"]
                    has_strikes = strikes is not None and float(strikes) > 0
                    if not has_strikes:
                        print(render_line(label, "N/A"))
                        continue
                    if numeric_value <= 0 or numeric_value >= LIGHTNING_MAX_DISTANCE:
                        continue
                    if numeric_value < LIGHTNING_ALERT_DISTANCE:
                        value_str = f"`F0F0{fmt(value, fmtstr, unit)}`f ⚡"
                    else:
                        value_str = fmt(value, fmtstr, unit)
                elif field == "lightning_strike_count":
                    if numeric_value <= 0:
                        continue
                    value_str = fmt(value, fmtstr, unit)
                else:
                    value_str = fmt(value, fmtstr, unit)

            except:
                continue
        elif field == "windchill":
            try:
                temp = data["outTemp"]
                ws   = data["windSpeed"]
                if temp is None or ws is None or float(temp) > 50 or float(ws) < 3:
                    value_str = "N/A"
                else:
                    value_str = fmt(value, fmtstr, unit)
            except:
                value_str = fmt(value, fmtstr, unit)
        elif field == "heatindex":
            try:
                temp = data["outTemp"]
                humi = data["outHumidity"]
                if temp is None or humi is None or float(temp) < 80 or float(humi) < 40:
                    value_str = "N/A"
                else:
                    value_str = fmt(value, fmtstr, unit)
            except:
                value_str = fmt(value, fmtstr, unit)
        else:
            value_str = fmt(value, fmtstr, unit)

        arrow = ""
        if prev:
            try:
                arrow = trend(float(value), float(prev[field]))
            except:
                pass

        day_min, day_max = get_daily_min_max(field)

        box = ""
        if day_min is not None and day_max is not None:
            box = f"`[{fmt(day_min, fmtstr, unit)}–{fmt(day_max, fmtstr, unit)}`]"

        print(render_line(label, value_str + arrow, box))

    if section_name == "Wind and Rain":
        ws = data["windSpeed"]
        try:
            dir_str = "N/A" if ws is None or float(ws) == 0 else wind_dir(data["windDir"])
        except:
            dir_str = wind_dir(data["windDir"])
        print(render_line("Wind Dir", dir_str))

# =====================================================
# FOOTER 
# =====================================================

print("\n\n")
print("Graphs: `F0FD`[Temp`:/page/weewx/graph_temp.mu`]`   `F0FD`[Wind`:/page/weewx/graph_wind.mu`]`f")

print("\n\nCredit for weather icon original goes to Dewi Sari ")
print("The icon was converted to Ascii using Img2ContourAscii from https://github.com/JamesM92/Img2ContourAscii")
print("The output was then converted for MicronMU using AnsiMicroMU from https://github.com/JamesM92/Ansi2MicronMU")


