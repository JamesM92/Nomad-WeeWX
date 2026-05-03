#!/usr/bin/env python3
import sqlite3
from time import strftime, localtime

from uniplot import plot_to_string
from ansi2micron import MicronConverter

mc = MicronConverter()

database = '/var/lib/weewx/weewx.sdb'
data_points = ['dateTime', 'outTemp', 'outHumidity', 'heatindex']

try:
    conn = sqlite3.connect(database)
    cur = conn.cursor()
    cur.execute(f'SELECT {", ".join(data_points)} FROM archive ORDER BY dateTime DESC LIMIT 288')
    data = cur.fetchall()
    conn.close()
except:
    data = []

# Filter out rows with missing timestamps
data = [row for row in data if row[0] is not None]

if not data:
    print("No weather data available yet.")
    print("\n`F0FD`[Home`:/page/weewx/weewx.mu`]`f")
    raise SystemExit

time_axis = []
temp_line = []
humi_line = []
heat_line = []

nan = float('nan')

for row in data:
    time_axis.append(strftime('%Y-%m-%dT%H:%M', localtime(row[0])))
    temp_line.append(row[1] if row[1] is not None else nan)
    humi_line.append(row[2] if row[2] is not None else nan)
    heat_line.append(row[3] if row[3] is not None else nan)

# Build only series that have at least one real value
y_lines = []
axes = []
labels = []
colors = []
for line, label, color in [
    (heat_line, "Heat Index", "yellow"),
    (temp_line, "Temperature", "red"),
    (humi_line, "Humidity", "blue"),
]:
    if any(v == v for v in line):  # at least one non-nan
        y_lines.append(line)
        axes.append(time_axis)
        labels.append(label)
        colors.append(color)

if not y_lines:
    print("No temperature data available yet.")
    print("\n`F0FD`[Home`:/page/weewx/weewx.mu`]`f")
    raise SystemExit

graph = plot_to_string(
    xs=axes,
    ys=y_lines,
    title="Temp And Humidity",
    legend_labels=labels,
    character_set="braille",
    lines=True,
    width=100,
    height=25
)

print(mc.convert(graph))

print("\n")
print("Graph is generated using Uniplot from https://github.com/olavolav/uniplot")
print("The output is then modified to micron using Ansi2MicronMU from https://github.com/JamesM92/Ansi2MicronMU")
print("\n")
print("`F0FD`[Home`:/page/weewx/weewx.mu`]`f")
