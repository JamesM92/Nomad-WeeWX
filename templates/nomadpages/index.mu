#!/usr/bin/python3
import subprocess, os, sys

# Set this to the page you want to redirect to, relative to the pages/ directory
TARGET = "weewx/weewx.mu"

page = os.path.join(os.path.dirname(os.path.abspath(__file__)), *TARGET.split("/"))
result = subprocess.run([page], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
sys.stdout.buffer.write(result.stdout)
