#!/usr/bin/env python3
"""Writes waterbox.config: what the frontend is told about this core.

The buttons and the axes come from the driver's wire order (boxing-driver.h);
the settings' choices from the driver's tables (boxing-driver.c), so a choice
the driver does not know cannot be declared.

usage: gen-config.py [<out>]   (default: waterbox/waterbox.config)
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# the floppies' images Open4DBoxing was checked with (its README, "Getting the game"); the MT-32's ROMs of the
# first generation, v1.07 (the DOSBox-X and OpenSamurai cores' firmware ids and hashes)
DISKS = [
    ("disk1.img", 737280, "5B324ABEC67BAA90A44C04BB9CC82BA50F4FB962", "the first floppy, with the four programs (MCGA/VGA, EGA, CGA, Tandy) and the sound drivers"),
    ("disk2.img", 737280, "C63AA4787B3A7860EC07B171AD3B47DA1A41E58E", "the second floppy, with the rings, the boxers' heads and the rest of the pictures and sounds"),
]
ROMS = [
    ("MT32_CONTROL.ROM", 65536, "B083518FFFB7F66B03C23B7EB4F868E62DC5A987", "control", "the control ROM of the Roland MT-32, version 1.07, dumped from a unit of the first generation"),
    ("MT32_PCM.ROM", 524288, "F6B1EEBC4B2D200EC6D3D21D51325D5B48C60252", "PCM", "the PCM ROM of the Roland MT-32, which is the same in every MT-32"),
]


def driver_ids(table):
    """The ids of one of boxing-driver.c's tables (k_programs, k_sounds), in its order."""
    text = open(os.path.join(HERE, "boxing-driver.c")).read()
    body = text[text.index(table + "[] = {"):]
    body = body[:body.index("};")]
    return re.findall(r'\{ "(\w+)", "', body)


def buttons():
    """The input.buttons names, in the driver's enum order (boxing-driver.h)."""
    text = open(os.path.join(HERE, "boxing-driver.h")).read()
    enum = text[text.index("enum BoxButton"):text.index("BOX_BTN_COUNT")]
    enum = re.sub(r"/\*.*?\*/", "", enum, flags=re.S)
    syms = re.findall(r"BOX_BTN_(\w+)", enum)
    special = {"ESC": "Esc"}
    # the rest: the symbol's words, capitalised (LEFT_SHIFT -> Left Shift); a letter or a digit is itself
    return [special.get(s) or (s if len(s) == 1 else " ".join(w.capitalize() for w in s.split("_"))) for s in syms]


def axes():
    text = open(os.path.join(HERE, "boxing-driver.h")).read()
    enum = text[text.index("enum BoxAxis"):text.index("BOX_AXIS_COUNT")]
    enum = re.sub(r"/\*.*?\*/", "", enum, flags=re.S)
    return [" ".join(w.capitalize() for w in s.split("_")) for s in re.findall(r"BOX_AXIS_(\w+)", enum)]


# ---- what the controls and the system are called ----
# The frontend keeps no table of these: a core says what its own are called.
# MNEMONICS is the letter each button writes into a movie's text (the gate's
# movies use the same, gate-harness.h); HEADERS heads the columns whose letter
# does not tell them from their neighbours.
MNEMONICS = {
    "Mouse Left": "<", "Mouse Right": ">",
    "Keypad 8": "U", "Keypad 2": "D", "Keypad 4": "L", "Keypad 6": "R", "Keypad 7": "Q", "Keypad 9": "E",
    "Keypad 1": "Z", "Keypad 3": "C", "Keypad 5": "K", "Keypad 0": "O",
    "Enter": "N", "Space": "_", "Backspace": "B", "Esc": "X", "Tab": "T",
    "Left Shift": "^", "Right Shift": "!", "Ctrl": "%", "Alt": "&",
}
MNEMONICS.update({c: c.lower() for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"})
MNEMONICS.update({c: c for c in "0123456789"})
HEADERS = {
    "Mouse Left": "ML", "Mouse Right": "MR",
    "Keypad 8": "KP8", "Keypad 2": "KP2", "Keypad 4": "KP4", "Keypad 6": "KP6", "Keypad 7": "KP7", "Keypad 9": "KP9",
    "Keypad 1": "KP1", "Keypad 3": "KP3", "Keypad 5": "KP5", "Keypad 0": "KP0",
    "Enter": "Ent", "Space": "Spc", "Backspace": "BkSp", "Esc": "Esc", "Tab": "Tab",
    "Left Shift": "LSh", "Right Shift": "RSh", "Ctrl": "Ctl", "Alt": "Alt",
}
AXIS_HEADERS = {"Mouse X": "MX", "Mouse Y": "MY"}
SYSTEM_NAMES = {
    "4DSportsBoxing": "4D Sports Boxing",
}


def mnemonics_for(names):
    """A letter for every button and for nothing else: a button nobody gave a
    letter stops the build (the engine would give it its rule's guess)."""
    missing = [b for b in names if b not in MNEMONICS]
    if missing:
        raise SystemExit("no mnemonic for the buttons %r (MNEMONICS in %s)" % (missing, __file__))
    letters = [MNEMONICS[b] for b in names]
    if len(set(letters)) != len(letters):
        raise SystemExit("two buttons share a mnemonic (MNEMONICS in %s)" % __file__)
    return {b: MNEMONICS[b] for b in names}


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "waterbox.config")
    videos = driver_ids("k_programs")
    sounds = driver_ids("k_sounds")
    assert videos == ["mcga", "ega", "cga", "tandy"], videos
    assert sounds == ["mt32", "sb", "adlib", "speaker", "tandy"], sounds
    names = buttons()
    firmware = []
    for name, size, sha1, what in DISKS:
        firmware.append({
            "id": name,
            "display": "4D Sports Boxing %s" % name,
            "description": ("%s, the image of %s of 4D Sports Boxing (Distinctive Software, 1991, DOS), a 720 KB floppy."
                            " You have to supply it, because this package includes none of the game's files."
                            " Open4DBoxing reads the game's files from the image as the original read them from the"
                            " floppy, and never writes to it. Another image of the same floppy, or one of your own,"
                            " can be used in its place, and the project then records its hash.") % (name, what),
            "size": size,
            "sha1": sha1,
            "name": name,
        })
    for name, size, sha1, kind, what in ROMS:
        firmware.append({
            "id": name,
            "display": "Roland MT-32 %s ROM" % kind,
            "description": ("%s is not one of the game's files. It is %s. You have to supply it when the sound is"
                            " the MT-32's, because this package includes none of it. Another MT-32 ROM that Munt"
                            " knows can be used in its place, and the project then records its hash.") % (name, what),
            "size": size,
            "sha1": sha1,
            "name": name,
            "requiredWhen": {"setting": "sound", "in": ["mt32"]},
        })

    cfg = {
        "coreName": "Open4DBoxing",
        "kind": "game",
        "systemId": "4DSportsBoxing",
        "systemNames": SYSTEM_NAMES,
        "author": "Sergio Martin, from Distinctive Software's 4D Sports Boxing (1991); chimera port by Sergio Martin",
        "url": "https://github.com/ToolAssisted-run/chimera-core-open4dboxing",
        "deterministic": True,
        "memoryLayoutMiB": [32, 8, 8, 8, 64],
        "_memoryLayoutMiB_note": "sbrk, sealed, invisible, plain, mmap. The game's files read from the floppies' images are on the heap; the DOS machine's megabyte, the video card's memory and the game's written files are the program's data; the game's stack (8 MB) is mmap'd (MAP_STACK).",
        "video": {
            "_comment": "The DOS game's 320x200 screen (the MCGA build's 256 colours; the EGA, CGA and Tandy builds' screens rendered to the same picture), shown on a 4:3 monitor.",
            "width": 320,
            "height": 200,
            "virtualWidth": 320,
            "virtualHeight": 240,
            "vsyncNumerator": 25175000,
            "vsyncDenominator": 359200,
            "_vsync_note": "A step is one video frame of the build that runs: 70.086 Hz on the VGA (the MCGA build, declared here), 59.92 Hz on the EGA, the CGA and the Tandy (GetVsyncNumerator/Denominator say which).",
            "getBgra": "GetVideoBgra",
        },
        "audio": {
            "_comment": "The sound of the driver the Sound setting chose (the MT-32's by default), rendered at 44100 Hz for each frame: the PC speaker's, the AdLib's, the Sound Blaster's and the Tandy's mono on both sides, the Roland MT-32's in stereo.",
            "rate": 44100,
            "samplesPerFrame": 4096,
            "channels": 2,
            "get": "GetAudio",
        },
        "lag": {"inputWasRead": "InputWasRead"},
        "input": {
            "name": "4D Sports Boxing",
            "_comment": "The mouse and the PC's keyboard, a button for each key the game reads. The menus take the mouse: its two buttons, and its place in the picture's pixels (the axes, 0-319 by 0-199; the pointer moves when they change, as a mouse moved). In the ring the human boxer's default controls are the numeric keypad (the keyboard's second set: 8 forward, 2 back, 4 and 6 sideways, the corners diagonally) with Enter and the right Shift its two punch buttons; the first set is Q W E / A D / Z X C with Tab and the left Shift. The letters, Space, Backspace and the left Shift (capitals) answer the manual's question and name a boxer; Esc and the Ctrl commands are the game's own. A key held is held: it does not repeat.",
            "buttons": names,
            "mnemonics": mnemonics_for(names),
            "headers": {b: HEADERS[b] for b in names if b in HEADERS},
            "axes": [
                {"name": a, "min": 0, "max": 319 if a.endswith("X") else 199, "neutral": 160 if a.endswith("X") else 100,
                 "header": AXIS_HEADERS[a]}
                for a in axes()
            ],
        },
        "settings": [
            {
                "name": "video",
                "display": "Video Card",
                "type": "enum",
                "options": videos,
                "default": "mcga",
                "description": "Which of the game's four programs runs, one for each video card:"
                    " the MCGA/VGA (256 colours, the default), the EGA (16 colours), the CGA (4 colours)"
                    " or the Tandy 1000 (16 colours). The MCGA's program runs at the VGA's 70 frames a"
                    " second, the others at 60. The game's properties (the boxers' health, stamina"
                    " and endurance) are known for the MCGA's program only.",
            },
            {
                "name": "sound",
                "display": "Sound",
                "type": "enum",
                "options": sounds,
                "default": "mt32",
                "description": "The sound driver the game loads, as its setup chose it: the Roland"
                    " MT-32 (the default), the Sound Blaster (its FM music with the digitised"
                    " announcer and crowd), the AdLib, the PC speaker or the Tandy's sound chip."
                    " The MT-32 needs the two ROMs of an MT-32 (version 1.07, the first generation),"
                    " which the project supplies as firmware.",
            },
            {
                "name": "clock_start",
                "display": "Start Date and Time",
                "type": "string",
                "default": "1991-07-30 14:47:00",
                "description": "The PC's date and time when the game starts, written as"
                    " YYYY-MM-DD HH:MM:SS (the default is the date of the game's programs on its"
                    " floppies). The clock then advances with the game, and the BIOS's tick count"
                    " starts from the time of day. A movie records the start time it ran with.",
            },
        ],
        "firmware": firmware,
    }
    with open(out, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
