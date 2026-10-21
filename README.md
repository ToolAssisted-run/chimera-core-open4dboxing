# chimera-core-open4dboxing

[Open4DBoxing](https://github.com/ToolAssisted-run/Open4DBoxing), the
reconstruction of 4D Sports Boxing (Distinctive Software, DOS, 1991), as a
[Chimera](https://github.com/ToolAssisted-run/chimera) **game core**
(`"kind": "game"`, see Chimera's `docs/game-cores.md`): the whole game - the
intro, the exhibitions, the Gym, the Main Event, every fight and panel -
stepped one video frame at a time in miniBox's sandbox, packaged as
`open4dboxing.chimeraCore`.

**Built on upstream Open4DBoxing, unpatched**: Open4DBoxing compiled from
source, with Munt's libmt32emu for the Roland MT-32, and the core's own stack
switch, file layer and host in place of its SDL frontend.

## What it is

- **4D Sports Boxing from the user's own floppies**: the two 720 KB floppies'
  images, `disk1.img` and `disk2.img`, are the project's **firmware**; the
  package carries none of the game's data. Open4DBoxing reads the game's files
  from the images in memory, as the original read them from its floppies,
  unpacks the PKLITE-packed programs as it loads them, and never writes to the
  images. A missing image is named. An image of the project's own (another
  dump of the same floppy) is taken as it is, and the project pins its hash.
- **A step is one video frame** of the build that runs: the VGA's 70.086 Hz
  for the MCGA program, 59.92 Hz for the EGA, CGA and Tandy programs. The
  game's clocks - the timer chip, the BIOS's ticks, DOS's date and time - go
  by the instructions the recompiled program runs (22,000 a millisecond, the
  speed of the DOSBox-X machine Open4DBoxing was checked against
  instruction for instruction), so a run is the same run everywhere. The PC's
  date and time at the start is a setting.
- **The controls are the mouse and the PC's keyboard**, a button for each key
  the game reads: the mouse's two buttons and its place in the picture's
  pixels (the menus take the mouse); the numeric keypad (the human boxer's
  default controls: 8 forward, 2 back, 4 and 6 sideways, the corners
  diagonally) with Enter and the right Shift its punch buttons, the first set
  Q W E / A D / Z X C with Tab and the left Shift; the letters, the digits,
  Space and Backspace (the manual's question, a boxer's name); Esc, Ctrl and
  Alt. A key held is held - it does not repeat, as in Open4DBoxing's own
  frontend - and the pointer moves when the mouse's place changes, as a mouse
  moved.
- **The game's saves** (its boxers, the Main Event, the system panel's
  defaults) are written where the game writes them, in guest memory, so a
  savestate carries them; the floppies' images are never changed.
- **Settings** recorded in the project: the video card (the MCGA/VGA, the
  default; the EGA; the CGA; the Tandy 1000 - the game came as four programs,
  one a card), the sound (the Roland MT-32, the default; the Sound Blaster;
  the AdLib; the PC speaker; the Tandy), and the date and time the PC's clock
  starts at.
- **The Roland MT-32** is Munt's libmt32emu, fed the MT15 driver's bytes at
  their time and mixed with the game's sound in stereo. It needs an MT-32's
  two ROMs (v1.07, the first generation; the DOSBox-X and OpenSamurai cores'
  firmware ids and hashes), which the project brings as firmware when the
  sound is the MT-32's.
- **Memory**: the DOS machine's 640 KB as the program has it (its data segment
  where the original had it), the video memory (A000-BFFF), the EGA's four
  planes, and a small Game State block (the frames shown, whether the game
  ended, the build) - domains in place. **Properties** by name over them, for
  the MCGA program: each boxer's health, stamina and endurance (the D, P and O
  bars under its name), whether it is down, the round's punches thrown and
  landed, which name the manual's question asks for, and the C library's
  random state.

## Using it in Chimera

Chimera includes no cores and downloads none. Download the `.chimeraCore`
package from this repository's
[Releases](https://github.com/ToolAssisted-run/chimera-core-open4dboxing/releases)
page, or build it, and put it in the `Cores` folder beside `Chimera.exe`;
File > Core Manager lists it. The same file works on Linux and on Windows.
The floppies' images and the MT-32's ROMs are yours to supply, as the
project's firmware.

The game asks the manual's question before a fight, as the original does:
keep the manual at hand.

## Building

```
git submodule update --init --recursive
make -C waterbox -f native.mk -j$(nproc)    # the native reference and the harnesses
make -C waterbox -f guest.mk -j$(nproc)     # core.wbx
./waterbox/build-package.sh                 # build/package/open4dboxing.chimeraCore
```

miniBox is taken from `MB=`/`MINIBOX_DIR`, else
`~/chimera/extern/chimera-common-minibox`; it must be built with its C++ guest
toolchain (`build/meson-cpp`, `-Dguest_cpp=true`), since Munt is C++, as well
as its host (`build/meson-linux`). `./waterbox/build-package.sh -r <chimera>`
writes the package into a Chimera checkout's `build/Cores` instead.

The build step by step, as CI does it: [docs/BUILDING.md](docs/BUILDING.md).
What was decided and measured: [docs/PLAN.md](docs/PLAN.md). For a coding
agent: [AGENTS.md](AGENTS.md).

## Gate

```
./waterbox/run-gate.sh
```

Native == sandbox (picture, sound, every step's length, every memory domain)
over the title, an exhibition into the fight, the EGA's, CGA's and Tandy's
titles and the MT-32's; determinism, a savestate before every step, a new host
mid-run, turbo; the pictures; each setting reaching the game; the keys in the
game's own keyboard table; the game's end at the first wrong answer; the
property table, a poke and a freeze; the refusals; an image of the project's
own; the package - each new leg seen to fail on a break of its own. The
MT-32's sound is held to the sandbox, not to the native reference: Munt builds
its tables in floating point, and glibc's libm and musl's round differently.

The game is the user's: put the floppies' images (disk1.img, disk2.img) in
`tests/roms-local` and the MT-32's ROMs (MT32_CONTROL.ROM, MT32_PCM.ROM) in
`tests/roms-local/roland`, or pass `-d`. Without them only the build, the
declarations and the no-files refusal run.

```
./waterbox/tests/run-frontend.sh --chimera <chimera> [--windows <Windows bundle>]
```

The frontend gate: the same exhibition played through `chimera-run` and
through Chimera itself (headless), each ending on the native reference's
memory; the project Chimera saved played again by a new process, and by
Chimera's Windows build under Wine; the property library, the core's refusal,
the keybinds. See [docs/BUILDING.md](docs/BUILDING.md).
