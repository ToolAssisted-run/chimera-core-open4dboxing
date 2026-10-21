#!/usr/bin/env python3
"""Writes a .chimeraProject for run-frontend.sh, by hand, as the wizard would.

A 4D Sports Boxing project is its settings, its firmware pins (the floppies'
images and, for the MT-32's sound, its ROMs, by SHA-1) and an input log: the
mouse's place as the two axes, then a letter for each button held, in the
package's own order (Chimera's rows put a group's axes before its buttons).
The movie, if given, is the gate's: a step a line, the mnemonics of the keys
held, and @X,Y to put the mouse at that pixel from that step on (# comments).

usage: make-project.py <package> <out.chimeraProject> <steps> --firmware <id>=<path>...
                       [--movie <movie>] [--settings <json>] [--log-out <path>]
--log-out also writes the rows alone, as chimera-run takes a movie.
"""
import argparse
import hashlib
import json
import re
import zipfile


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("package")
    ap.add_argument("out")
    ap.add_argument("steps", type=int)
    ap.add_argument("--firmware", action="append", default=[], metavar="ID=PATH")
    ap.add_argument("--movie")
    ap.add_argument("--settings", default="{}")
    ap.add_argument("--log-out")
    a = ap.parse_args()

    cfg = json.loads(zipfile.ZipFile(a.package).read("waterbox.config"))
    settings = {d["name"]: d["default"] for d in cfg["settings"]}
    settings.update(json.loads(a.settings))
    buttons = cfg["input"]["buttons"]
    mnemonics = cfg["input"]["mnemonics"]
    axes = cfg["input"]["axes"]

    place = [axis["neutral"] for axis in axes]
    held_rows = []
    if a.movie:
        for line in open(a.movie):
            if line.startswith("#"):
                continue
            line = line.rstrip("\n")
            # the mouse's place first: its digits are not the digit keys
            for m in re.finditer(r"@(-?\d+),(-?\d+)", line):
                place = [int(m.group(1)), int(m.group(2))]
            keys = re.sub(r"@-?\d+,-?\d+", "", line)
            held_rows.append((list(place), keys))
    rows = []
    for step in range(a.steps):
        at, keys = held_rows[step] if step < len(held_rows) else (place, "")
        fields = "".join(f"{v:>5}," for v in at)
        fields += "".join(mnemonics[b] if mnemonics[b] in keys else "." for b in buttons)
        rows.append("|" + fields + "|")
    if a.log_out:
        open(a.log_out, "w").write("\n".join(rows) + "\n")
    key = "#" + "".join(axis["name"] + "|" for axis in axes) + "".join(b + "|" for b in buttons)
    log = "[Input]\nLogKey:" + key + "\n" + "\n".join(rows) + "\n[/Input]\n"

    given = dict(f.split("=", 1) for f in a.firmware)
    firmware = []
    for d in cfg["firmware"]:
        when = d.get("requiredWhen")
        if when and settings.get(when["setting"]) not in when["in"]:
            continue
        if d["id"] in given:
            firmware.append({"id": d["id"], "sha1": sha1(given[d["id"]])})

    project = {
        "id": "open4dboxing-frontend-gate",
        "title": "4D Sports Boxing through Chimera",
        "description": "written by waterbox/tests/run-frontend.sh",
        "core": {"name": cfg["coreName"], "version": cfg["version"], "sha1": sha1(a.package)},
        "rerecords": 0,
        "files": [],
        "settings": settings,
        "firmware": firmware,
        "coreCache": [],
        "input": log,
        "markers": [],
        "branches": [],
        "headers": {
            "MovieVersion": "Chimera Project File v1.1",
            "Platform": cfg["systemId"],
            "SHA1": "",
            "LastInputFrame": str(a.steps - 1),
            "VsyncNumerator": str(cfg["video"]["vsyncNumerator"]),
            "VsyncDenominator": str(cfg["video"]["vsyncDenominator"]),
        },
    }
    with open(a.out, "w") as f:
        json.dump(project, f, indent="\t")


if __name__ == "__main__":
    main()
