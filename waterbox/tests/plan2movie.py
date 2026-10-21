#!/usr/bin/env python3
"""A scenario in Open4DBoxing's plan language (its tools/mkscript.py) as one of
the gate's movies (gate-harness.h): one line per step, the buttons held on it
as their mnemonics, and @X,Y where the mouse moves.

  key F NAME          a key tapped at F (held 12 steps)
  press F NAME, release F NAME, hold F NAME N   a key pressed, released, held N steps
  type F TEXT...      the text typed from F on, a key every 24 steps (capitals with the left Shift), then Enter
  mouse F X Y         the pointer to X,Y (the picture's pixels)
  click F             a left click at F (held 30 steps)
  end F               the movie's length

Key names as mkscript's: a-z, 0-9, enter, space, backspace, esc, tab, lshift, rshift, lctrl, lalt, kp0-kp9.

usage: plan2movie.py <plan> <movie>
"""
import sys

NAMES = {"enter": "N", "space": "_", "backspace": "B", "esc": "X", "tab": "T", "lshift": "^", "rshift": "!",
         "lctrl": "%", "lalt": "&", "kp8": "U", "kp2": "D", "kp4": "L", "kp6": "R", "kp7": "Q", "kp9": "E",
         "kp1": "Z", "kp3": "C", "kp5": "K", "kp0": "O"}


def letter(name):
    if len(name) == 1 and (name.isdigit() or "a" <= name <= "z"):
        return name
    if name in NAMES:
        return NAMES[name]
    sys.exit(f"plan2movie: no button for the key {name!r}")


def main():
    events = []  # (step, letter, down)
    moves = {}
    end = 0
    for line in open(sys.argv[1]):
        p = line.split()
        if not p or p[0].startswith("#"):
            continue
        f = int(p[1])
        if p[0] == "key":
            events += [(f, letter(p[2]), 1), (f + 12, letter(p[2]), 0)]
        elif p[0] == "press":
            events.append((f, letter(p[2]), 1))
        elif p[0] == "release":
            events.append((f, letter(p[2]), 0))
        elif p[0] == "hold":
            events += [(f, letter(p[2]), 1), (f + int(p[3]), letter(p[2]), 0)]
        elif p[0] == "type":
            t = f
            for ch in " ".join(p[2:]):
                k = "_" if ch == " " else letter(ch.lower())
                if ch.isupper():
                    events += [(t, "^", 1), (t + 14, "^", 0)]
                events += [(t + 2, k, 1), (t + 12, k, 0)]
                t += 24
            events += [(t, "N", 1), (t + 12, "N", 0)]
        elif p[0] == "mouse":
            moves[f] = (int(p[2]), int(p[3]))
        elif p[0] == "click":
            events += [(f, "<", 1), (f + 30, "<", 0)]
        elif p[0] == "end":
            end = f
        else:
            sys.exit(f"plan2movie: no such plan line: {line.strip()}")
    end = max([end] + [e[0] + 1 for e in events] + [m + 1 for m in moves])
    held = set()
    by_step = {}
    for step, k, down in sorted(events, key=lambda e: (e[0], -e[2])):
        by_step.setdefault(step, []).append((k, down))
    with open(sys.argv[2], "w") as out:
        out.write(f"# {sys.argv[1]}\n")
        for step in range(end):
            for k, down in by_step.get(step, []):
                (held.add if down else held.discard)(k)
            line = "".join(sorted(held))
            if step in moves:
                line += "@%d,%d" % moves[step]
            out.write(line + "\n")


if __name__ == "__main__":
    main()
