#!/usr/bin/env python3
"""The declarations: waterbox.config is what gen-config.py writes now from the
driver's button and axis order and its settings' tables (boxing-driver.h,
boxing-driver.c) - so nobody edited one and not the others - and the gate's
movie letters (gate-harness.h) are the mnemonics it declares.

usage: check-wire.py <repo root>
"""
import json
import os
import re
import subprocess
import sys
import tempfile

root = sys.argv[1]
wb = os.path.join(root, "waterbox")
cfg = json.load(open(os.path.join(wb, "waterbox.config")))
with tempfile.TemporaryDirectory() as tmp:
    fresh = os.path.join(tmp, "waterbox.config")
    subprocess.run([sys.executable, os.path.join(wb, "gen-config.py"), fresh], check=True)
    if json.load(open(fresh)) != cfg:
        sys.exit("waterbox.config is not what gen-config.py writes from the driver: regenerate it")

# the sandbox harness builds the machine with the layout the package declares
m = re.search(r"#define LAYOUT_MIB ([0-9, ]+)", open(os.path.join(wb, "run-wbx.c")).read())
if [int(x) for x in m.group(1).split(",")] != cfg["memoryLayoutMiB"]:
    sys.exit(f"run-wbx.c's LAYOUT_MIB {m.group(1)} is not memoryLayoutMiB {cfg['memoryLayoutMiB']}")

# the harness's letters: each one the button the config gives that mnemonic
harness = open(os.path.join(wb, "gate-harness.h")).read()
body = harness[harness.index("static int gate_key_index(char c)"):]
body = body[:body.index("default: return -1;")]
pairs = re.findall(r"case '(.)': return BOX_BTN_(\w+);", body)
enum = open(os.path.join(wb, "boxing-driver.h")).read()
enum = enum[enum.index("enum BoxButton"):enum.index("BOX_BTN_COUNT")]
syms = re.findall(r"BOX_BTN_(\w+)", re.sub(r"/\*.*?\*/", "", enum, flags=re.S))
buttons = cfg["input"]["buttons"]
mn = cfg["input"]["mnemonics"]
for letter, sym in pairs:
    name = buttons[syms.index(sym)]
    if mn[name] != letter:
        sys.exit(f"the harness's {letter!r} is {name}, whose mnemonic is {mn[name]!r}")
for b in buttons:
    if len(b) == 1 and mn[b] != b.lower():
        sys.exit(f"the key {b}'s mnemonic is {mn[b]!r}, not its own letter")
print(f"{len(buttons)} buttons, {len(cfg['input']['axes'])} axes, {len(cfg['settings'])} settings and "
      f"{len(cfg['firmware'])} firmware files agree; the gate's {len(pairs)} named letters are the mnemonics")
