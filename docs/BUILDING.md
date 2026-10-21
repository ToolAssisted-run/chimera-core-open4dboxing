# Building the Open4DBoxing core

This repository builds Open4DBoxing, the reconstruction of 4D Sports Boxing
(Distinctive Software, DOS, 1991), as a Chimera game core: one game rebuilt as
a core, not an emulator. The result is one file, `open4dboxing.chimeraCore`,
which Chimera loads. The steps below are the ones the repository's CI runs
from a fresh clone (`.github/workflows/chimera.yml`).

Placeholders used in this document:

- `<core>`: the checkout of this repository.
- `<chimera>`: a checkout of Chimera
  (https://github.com/ToolAssisted-run/chimera).
- `<minibox>`: `<chimera>/extern/chimera-common-minibox`, the miniBox
  submodule of that checkout. miniBox is the sandbox host and the guest
  toolchain.

## Requirements

- Linux, x86_64. CI builds on GitHub's `ubuntu-24.04` runner (see
  "Troubleshooting" for why not a newer one). Cores are built on Linux; the
  package that comes out runs on Linux and on Windows.
- git, and the packages CI installs:

  ```
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends meson ninja-build build-essential cmake pkg-config python3 mono-complete xvfb libgl1-mesa-dev libegl-dev libx11-dev libxext-dev libasound2-dev
  ```

- The compilers are the distribution's gcc and g++ (`build-essential`).
- `curl`. miniBox's build of the C++ guest toolchain calls it (below).
- The .NET SDK 8.0. CI sets it up with `actions/setup-dotnet@v4`,
  `dotnet-version: '8.0'`. It builds Chimera and runs Chimera's contract
  tests; the core's own build does not use it.

What gets downloaded or built along the way:

- Nothing in this repository's scripts downloads anything. Open4DBoxing and
  Munt (the Roland MT-32, C++) are compiled from the submodules.
- miniBox builds the guest C library (musl) from sources in its own checkout.
- miniBox's C++ guest toolchain is a libstdc++ built for the guest. Its build
  fetches the GCC source that matches the host's gcc (about 84 MB) and
  compiles libstdc++ from it. This step needs the network once.

## Get the sources

```
git clone --recursive https://github.com/ToolAssisted-run/chimera-core-open4dboxing.git <core>
git clone --recursive https://github.com/ToolAssisted-run/chimera.git <chimera>
```

In a clone made without `--recursive`:

```
git submodule update --init --recursive
```

This repository has one submodule, `extern/Open4DBoxing` (the game). Munt is a
submodule of Open4DBoxing itself, at `extern/Open4DBoxing/extern/munt`, so the
checkout must be recursive.

The scripts find miniBox in this order:

1. `-m <miniBox dir>` on the script's command line (`MB=<dir>` for the
   makefiles).
2. The `MINIBOX_DIR` environment variable. CI sets it.
3. `<chimera root>/extern/chimera-common-minibox`, for
   `build-package.sh -r <chimera root>` only.
4. `~/chimera/extern/chimera-common-minibox`.

```
export MINIBOX_DIR=<chimera>/extern/chimera-common-minibox
```

## Build miniBox

This core needs two build directories of miniBox, because Munt is C++:

```
mb=<chimera>/extern/chimera-common-minibox
[ -f "$mb/build/meson-linux/build.ninja" ] || meson setup "$mb/build/meson-linux" "$mb"
meson compile -C "$mb/build/meson-linux"
[ -f "$mb/build/meson-cpp/build.ninja" ] || meson setup "$mb/build/meson-cpp" "$mb" -Dguest_cpp=true
meson compile -C "$mb/build/meson-cpp"
```

- `build/meson-linux` has `source/host/libminiboxhost.so`, the sandbox host
  library that the `run-wbx` harness links.
- `build/meson-cpp` has the C++ guest toolchain: `guest-sysroot` with musl
  and libstdc++, which `waterbox/guest.mk` compiles and links against. If
  `meson compile` leaves `guest-sysroot/lib/libstdc++.a` missing, name the
  targets: `ninja -C "$mb/build/meson-cpp" musl-gcc libstdcxx-installed.stamp
  source/guest/emulibc.c.o source/guest/cxxglue.c.o`.

`guest.mk` compiles with the system's `gcc` and `g++` through the sysroot's
specs file, and looks for libstdc++'s headers under the version that
`gcc -dumpfullversion` prints. The gcc on the PATH must be the one the C++
guest toolchain was built with.

## Build the core

### Patches

There are none. Open4DBoxing is built as upstream has it, and this repository
has no `patches/` directory. `waterbox/apply-patches.sh` is still there and
both makefiles run it; with no patches it only checks that
`extern/Open4DBoxing` is checked out, prints `no patches to apply` and
succeeds.

### The native reference and the guest

```
cd <core>
make -C waterbox -f native.mk -j"$(nproc)"
make -C waterbox -f guest.mk -j"$(nproc)"
```

- `native.mk` builds the native reference with the host's gcc and g++: the
  same Open4DBoxing, Munt and core sources as the guest. It makes
  `build/native/run-native`, which drives the core's exports directly, and
  `build/native/run-wbx`, which drives `core.wbx` through the miniBox host as
  the frontend does. The gate compares the two.
- `guest.mk` builds `build/guest/core.wbx` with the C++ guest toolchain. The
  file counts as built only after miniBox's `check-wbx.sh` passes it (no
  thread-local storage, no `%fs`, no red zone).

The four recompiled programs are large C files (`ega_core.c` alone is 140,000
lines): a build takes three minutes on many cores, most of it those files.

## Build the package

```
./waterbox/build-package.sh -r <chimera>
```

Usage: `./waterbox/build-package.sh [-m <miniBox dir>] [-r <chimera root>] [-o <out dir>]`

- `-r <chimera root>` writes
  `<chimera root>/build/Cores/open4dboxing.chimeraCore` and removes any
  `<chimera root>/build/CoreCache/open4dboxing-*` directory. This is what CI
  runs.
- `-o <out dir>` writes `<out dir>/open4dboxing.chimeraCore` instead.
- With neither, the file is `build/package/open4dboxing.chimeraCore`.

The script runs `guest.mk`, checks `core.wbx`, and packs it with
`waterbox/waterbox.config`, `waterbox/default_keybinds.json`,
`waterbox/file_slots.json`, the licences (from
`waterbox/package-licenses.json`) and a `build.json` that records what built
it. It writes the archive twice and stops if the two differ. The package's
version is the commit it was built from: CI passes `CORE_VERSION`; by hand the
script stamps `<commit>+local` (`<commit>-dirty+local` when tracked files
differ from HEAD), which Chimera's publish script refuses.

## Install it into Chimera

Chimera includes no cores and downloads nothing. A core gets into Chimera as a
file somebody puts in its `Cores` folder: `<chimera>/build/Cores/` in a source
checkout (where `build-package.sh -r <chimera>` writes), the `Cores` folder
beside `Chimera.exe` in a release bundle, or the folder chosen in
File > Core Manager > Change folder... File > Core Manager lists it. The same
file works on Linux and on Windows. In Chimera a new project picks the core in
File > New Project... (Kind: Game).

## Run the gates

### The core gate

```
./waterbox/run-gate.sh
```

Usage: `./waterbox/run-gate.sh [-q] [-m <miniBox dir>] [-d <game dir>]`

- `-q` skips the build and tests what is built. A `core.wbx` older than a
  source then fails the `build:fresh` leg.
- `-d` names the folder that holds the floppies' images (default
  `tests/roms-local`; `BOXING_DIR` also sets it).

It builds the native reference and the guest, then proves that the sandboxed
core plays exactly as the native reference does (picture, sound, every step's
length, the clock, every memory domain) over the title, an exhibition from the
title through the boxers' choice, the manual's question and the ring into the
fight, the EGA's, CGA's and Tandy's titles and the MT-32's; that a second
sandboxed run is the same; that a run that skips half its pictures plays the
same game; that a savestate before every step loses nothing; and that a new
host can finish a run from a state taken half way. It then checks the
pictures, each setting reaching the game (the four builds and their frame
rates, the five sound drivers, the MT-32 by default, the clock), the keys in
the game's own keyboard table, the game's end after three wrong answers, the
property table, a poke and a freeze, the refusals, an image of the project's
own, that the game's stack is asked for as a stack (`MAP_STACK`), and that the
package is the same twice.

The MT-32's sound is held to the sandbox, not to the native reference. Munt
builds its tables in floating point, and glibc's libm and musl's round
differently.

It prints one line per leg (PASS, FAIL or SKIP) and ends with
`<n> ok, <n> failed, <n> skipped`. The exit status is 0 only when nothing
failed. Its work files and pictures are in `build/gate/`.

The game is the user's and is never in the repository. The gate takes it from
`tests/roms-local`, which is gitignored:

- `tests/roms-local/disk1.img`, `tests/roms-local/disk2.img`: the two
  floppies' images (the hashes in Open4DBoxing's README, "Getting the game").
- `tests/roms-local/roland/`: the MT-32's ROMs, `MT32_CONTROL.ROM` and
  `MT32_PCM.ROM`.

Without the images only the build, the stack check, the declarations
(`wire:config==driver`) and the refusal of a project with no files run, and
everything else is one `game SKIP` line: this is what CI runs. Without the
MT-32's ROMs the MT-32's legs are skipped.

This repository has no frontend gate script yet (`docs/PLAN.md`).

### Chimera's contract tests

CI runs Chimera's own tests against the package it just built. They need
Chimera built first:

```
cd <chimera>
meson setup build/meson-linux --prefix "$PWD/build" --libdir dll
meson compile -C build/meson-linux
meson install -C build/meson-linux
dotnet build source/gui/Chimera.sln -c Release /nodeReuse:false -p:UseSharedCompilation=false
```

Then, with the package in `<chimera>/build/Cores`:

```
cd <chimera>
CHIMERA_CORES_DIR="$PWD/build/Cores" dotnet test source/gui/Chimera.Tests.Client.Common/Chimera.Tests.Client.Common.csproj \
  -c Release --nologo \
  --filter "FullyQualifiedName~InstalledCorePackagesTests|FullyQualifiedName~MnemonicUniquenessTests"
```

They prove the package is readable, is built for an ABI this frontend runs,
makes a working factory, binds only inputs Chimera sends and buttons its
controller declares, declares a letter for every button, and stamps a version.
They need none of the game's files.

## Files the core needs at run time

The package carries none of the game's data and no MT-32 ROM. The user
provides the two floppies' images, and the project brings them as firmware;
`waterbox/waterbox.config` declares each with its size and SHA-1:

- `disk1.img`, 737,280 bytes, SHA-1 `5b324abec67baa90a44c04bb9cc82ba50f4fb962`
- `disk2.img`, 737,280 bytes, SHA-1 `c63aa4787b3a7860ec07b171ad3b47da1a41e58e`

With the Sound setting at `mt32` (the default), also a Roland MT-32's two
ROMs, `MT32_CONTROL.ROM` (v1.07) and `MT32_PCM.ROM`. The ROMs are no files of
the game's; another MT-32 ROM that Munt knows may take their place.

A missing image is refused by name, and so is an image that is not a FAT12
floppy or floppies without the build the Video setting asks for. An image of
the user's own (another dump of the same floppy) may take an original's place:
the core takes it as it is and the project pins its hash. The project has no
file slots: what the game saves lives in the machine's memory.

## Troubleshooting

- `miniBox not found` from the gate or the package script: pass `-m` or export
  `MINIBOX_DIR`.
- `miniBox's C++ guest toolchain is missing: .../build/meson-cpp/guest-sysroot`:
  miniBox was built without `-Dguest_cpp=true`, or its toolchain targets were
  not built. See "Build miniBox".
- `conflicting types for 'basename'` while miniBox builds libstdc++ (in
  libbacktrace's `cp-demangle.c`): the host's GCC is 15 or newer (Ubuntu
  26.04), which compiles C as C23, where the guest musl's `char *basename();`
  declares a function of no arguments. Build on a host with GCC 13 or 14 (CI
  uses `ubuntu-24.04`), or put a `gcc` first on the PATH that runs the real
  one with `-std=gnu17` before its arguments (an explicit `-std` later on the
  line still wins), for both miniBox's build and this core's.
- `could not download the GCC <version> source from any mirror`: miniBox's C++
  toolchain build needs the network to fetch the GCC source.
- `extern/Open4DBoxing is not checked out`: run
  `git submodule update --init --recursive`.
- `build:fresh FAIL` in the gate: `-q` was used on a `core.wbx` older than a
  source. Run the gate without `-q`.
- `stacks:map-stack FAIL`: the game's stack must come from `mmap` with
  `MAP_STACK`. Linux runs the core either way; on Windows miniBox cannot
  deliver a fault on a stack page it was not told about.
- The MT-32's `audioHash` differs between `run-native` and `run-wbx`: that is
  expected, see "The core gate".
- `packaging is not deterministic`: two archives of the same staging folder
  differed. The package's SHA-1 is the core's identity, so the script stops.
