#!/usr/bin/python3
import shutil
import subprocess

_rnstatus = shutil.which("rnstatus") or "rnstatus"
result = subprocess.run([_rnstatus], capture_output=True, text=True)
rnstatus = result.stdout

print(rnstatus)

print("\n")
print("`F0FD`[Home`:/page/weewx/weewx.mu`]`f")

