# AGENTS.md - Open4DBoxing core for Chimera

This repository builds Open4DBoxing, the reconstruction of 4D Sports Boxing
(Distinctive Software, DOS, 1991), as a game core for Chimera
(https://github.com/ToolAssisted-run/chimera), a frontend for tool-assisted
speedruns. It is a game core: one game rebuilt as a core and stepped one
video frame at a time, not an emulator. It produces one file,
`open4dboxing.chimeraCore`, which Chimera's sandbox (miniBox) runs on Linux
and on Windows. The package carries none of the game's data and no MT-32 ROM.

## Layout

- `extern/Open4DBoxing` - submodule: the game (upstream Open4DBoxing), built
  unpatched; there is no `patches/` directory. Munt, the Roland MT-32, is its
  own submodule at `extern/Open4DBoxing/extern/munt`.
- `waterbox/boxing-driver.c`, `game-state.c`, `coro.c`, `files.c`,
  `wbx-entry.c` - the core itself.
- `waterbox/munt-config.h` - Munt's `config.h`, the core's own.
- `waterbox/gen-config.py` - writes `waterbox/waterbox.config`.
- `waterbox/waterbox.config` - what Chimera is told: kind, settings, buttons,
  axes, the firmware list. Generated.
- `waterbox/file_slots.json`, `default_keybinds.json`,
  `package-licenses.json` - packed as they are.
- `waterbox/sources.mk`, `native.mk`, `guest.mk` - the build.
- `waterbox/apply-patches.sh`, `build-package.sh`, `run-gate.sh` - scripts.
- `waterbox/run-native.c`, `run-wbx.c`, `gate-harness.h` - the gate's two
  harnesses.
- `waterbox/tests/` - the gate's checkers, its scenario (`exhibition.plan`)
  and the converter of a scenario into one of its movies (`plan2movie.py`);
  the frontend gate (`run-frontend.sh`), with the project it writes
  (`make-project.py`) and the Lua that plays it in Chimera (`frontend.lua`).
- `tests/roms-local/` - the floppies' images and the MT-32's ROMs for the
  gate; `build/` - everything built. Both gitignored.
- `docs/BUILDING.md` - the build in detail; `docs/PLAN.md` - the decisions
  and the measurements.
- `.github/workflows/chimera.yml` - CI: the authoritative build recipe.

## Set up the build environment

On Ubuntu 24.04, as CI does:

```
sudo apt-get update
sudo apt-get install -y --no-install-recommends meson ninja-build build-essential cmake pkg-config python3 mono-complete xvfb libgl1-mesa-dev libegl-dev libx11-dev libxext-dev libasound2-dev
git submodule update --init --recursive
git clone --recursive https://github.com/ToolAssisted-run/chimera.git <chimera>
export MINIBOX_DIR=<chimera>/extern/chimera-common-minibox
[ -f "$MINIBOX_DIR/build/meson-linux/build.ninja" ] || meson setup "$MINIBOX_DIR/build/meson-linux" "$MINIBOX_DIR"
meson compile -C "$MINIBOX_DIR/build/meson-linux"
[ -f "$MINIBOX_DIR/build/meson-cpp/build.ninja" ] || meson setup "$MINIBOX_DIR/build/meson-cpp" "$MINIBOX_DIR" -Dguest_cpp=true
meson compile -C "$MINIBOX_DIR/build/meson-cpp"
```

The `meson-cpp` build fetches the GCC source matching the host's gcc (about
84 MB) to build libstdc++ for the guest. On a host with GCC 15 (Ubuntu 26.04)
that build stops on `basename`: see docs/BUILDING.md, "Troubleshooting".

## Build

```
make -C waterbox -f native.mk -j"$(nproc)"    # build/native/run-native, run-wbx
make -C waterbox -f guest.mk -j"$(nproc)"     # build/guest/core.wbx
./waterbox/build-package.sh -r <chimera>      # <chimera>/build/Cores/open4dboxing.chimeraCore
```

- `build-package.sh` runs `guest.mk` again, so the first two lines can be
  replaced by `./waterbox/run-gate.sh`, which runs both.
- `build-package.sh -o <dir>` writes to `<dir>` instead; with neither option
  the package is `build/package/open4dboxing.chimeraCore`.
- A hand-built package is stamped `<commit>+local` (`-dirty` when tracked
  files differ from HEAD). It is for testing. CI stamps the commit.

## Install the core into Chimera

A core is a file in Chimera's `Cores` folder: `<chimera>/build/Cores/` in a
source checkout, the `Cores` folder beside `Chimera.exe` in a release bundle,
or the folder chosen in File > Core Manager > Change folder...

## Test before you commit

```
./waterbox/run-gate.sh
```

- It must end with `0 failed`; it exits non-zero otherwise.
- The game legs need the user's floppy images in `tests/roms-local`
  (`disk1.img`, `disk2.img`) and the MT-32's two ROMs in
  `tests/roms-local/roland`. Without the images the gate runs only the build,
  the stack check, the declarations and the no-files refusal. That is all CI
  can run. A change to the game's behaviour is not tested until the gate has
  run with the images.
- `run-gate.sh -q` skips the build; the `build:fresh` leg fails if a source
  is newer than `core.wbx`.
- The MT-32's sound is held to the sandbox only, not to the native reference.
- Results and pictures: `build/gate/`.

The frontend gate plays the same exhibition through Chimera itself:

```
./waterbox/tests/run-frontend.sh --chimera <chimera checkout or release bundle> [--windows <Windows bundle>]
```

- It must end with `0 failed`. It needs the native reference built, Mono,
  Xvfb and the floppies' images; `--windows` runs Chimera's Windows bundle
  under Wine (`docs/BUILDING.md`, "The frontend gate").
- Run it after a change to what the frontend sees: the declarations, the
  keybinds, the properties, the refusals, the input.

CI also runs Chimera's contract tests against the package
(`docs/BUILDING.md`, "Chimera's contract tests").

## Rules of this repository

- `extern/Open4DBoxing` is a submodule and is built unpatched. A change to the
  game goes upstream and arrives here by moving the pin. Never commit inside
  the submodule.
- Determinism is the product. The guest must not read host time, host
  randomness or anything else that differs between runs: the game's clocks go
  by the instructions it runs. A savestate must round-trip. The gate checks
  both; a change that breaks either is a bug.
- `waterbox/waterbox.config` is generated. Change the driver or
  `gen-config.py`, then run `python3 waterbox/gen-config.py`. The gate's
  `wire:config==driver` leg fails when they disagree (and when the gate's
  movie letters are not the declared mnemonics, or run-wbx's memory layout is
  not the declared one).
- The game's stack comes from `mmap` with `MAP_STACK` (`coro.c`). The gate's
  `stacks:map-stack` leg holds this; Windows needs it.
- Run the gate before committing. A new leg needs a negative control: break
  the thing it checks, see the leg fail, revert.
- Never commit the floppies' images or the MT-32's ROMs. Never add network
  access.
- Shell scripts stay executable (git mode 100755). Docs are plain ASCII.
- Commit subjects say what is now true, most with a prefix: `feat:`,
  `fix:`, `build:`, `ci:`. A pin move names the upstream commit:
  `feat: Open4DBoxing <commit> - <what it brings>`. The body says in prose
  what changed and what was measured.
- Do not edit `.github/workflows` unless the task is the workflow.

## Where to read more

- `docs/BUILDING.md` - requirements, every script option, the files the core
  needs, troubleshooting.
- `docs/PLAN.md` - what was decided, and why.
- `README.md` - what the core is and how the game behaves in it.
- In the Chimera checkout: `docs/game-cores.md`, `docs/porting-a-core.md`,
  `docs/new-core.md`, `docs/core-manager.md`, `docs/gates.md`.
