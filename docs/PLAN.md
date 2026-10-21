# The Open4DBoxing core: what was decided, and why

A design log, newest last. Chimera's `docs/new-core.md` is the route this
followed; the nearest core, `chimera-core-opensamurai` (the same author's
reconstruction of another DOS game, built the same way), is where the
structure came from.

## 2026-10-21: feasibility

- **A new core, a game core.** Open4DBoxing is one game rebuilt (4D Sports
  Boxing, Distinctive Software, 1991): the four programs recompiled whole from
  their machine code into C, on a runtime that gives them the PC they expect.
  It is `"kind": "game"`, as OpenSamurai and SDLPoP2 are.
- **Licence.** Open4DBoxing is GPL-3.0-or-later; Munt's libmt32emu
  LGPL-2.1-or-later. Both allow a modified binary package with their texts.
  The game's data is never in the package: the user's floppies are firmware.
- **One thread, one clock.** Open4DBoxing is single-threaded and its clocks
  (the timer chip, the BIOS's ticks, DOS's date and time) go by the
  instructions the recompiled program runs, 22,000 a millisecond - the speed
  of the DOSBox-X machine it was checked against instruction for instruction.
  Nothing in it reads the host's time; the start's date and time is a setting.
- **The picture** is the game's own: the 320x200 screen (the EGA's planes and
  the CGA's and Tandy's modes rendered to the same 256-colour indexes by
  Open4DBoxing) through the DAC.
- **What the user brings**: the two floppies' images (disk1.img, disk2.img,
  the SHA-1s Open4DBoxing's README gives), and an MT-32's ROMs for its sound.
- **What a public runner can gate**: the build, the declarations, the
  refusal of a project without files. Everything that runs the game runs
  where the images are.

## The structure (from the OpenSamurai core)

- `game_run()` is the game as one blocking call. It runs on a stack of its own
  (`coro.c`, `MAP_STACK`), and each video frame it passes (`GameHost.frame`)
  ends the step: the picture converted, the frame's sound rendered, the stack
  left where it is until the next step. A savestate between two steps carries
  the suspended game whole, its stack being guest memory.
- The game's files: Open4DBoxing reads the floppies' images in memory
  (`disks.c`) and serves the game's files from them (`dos.c`); the images are
  mounted under their names, and the link wraps `fopen`, `opendir`,
  `readdir`, `closedir` and `remove` (`files.c`) so that the game's own
  directory lists the images and what the game wrote, and its writes live in
  guest memory. It writes BCDATA1.DAT and BCDATA2.DAT (its boxers, the Main
  Event; 2 KB each) and CONFIG1.DAT (8 bytes), measured over the Gym, the
  panels, the options and the career scenarios; the Gym's export goes to
  drives A: and B:, which the machine does not have.
- The native reference (`run-native`) links the same driver and library as
  the guest; the gate compares the two step by step.

## Decisions

- **The input.** The mouse's two buttons and its place, and the keys the game
  reads: the keypad (the human boxer's default controls), Enter, Space,
  Backspace, Esc, Tab, both Shifts, Ctrl, Alt, the letters and the digits -
  57 buttons, each with a letter of its own for a movie. The arrow keys reach
  the game as the keypad's (its keyboard table is indexed by the scan code
  alone) and are not buttons; no function key is read by the game (no read of
  either keyboard table at F1-F10's codes).
- **The mouse's place** is two axes in the picture's pixels (0-319 by
  0-199): what TAStudio shows is where the pointer is. The driver moves the
  pointer only when the axes change, as a mouse sends nothing while it lies
  still, so the game may still place it itself.
- **A key held is held**: no typematic repeat, as Open4DBoxing's own frontend
  ignores the host's repeats.
- **No lag frames**: the game reads its keyboard through its own interrupt
  handler and the mouse when it likes, so every step is one it could have
  read them in (`InputWasRead` is 1), as in the OpenSamurai core.
- **The sound**: the MT-32 by default (the owner's decision for game cores,
  2026-09-29). The chips' sound is mixed as Open4DBoxing's frontend mixes it
  (the PC speaker's first: it writes; the others add), mono on both sides; the
  MT-32's is stereo and added.
- **The default start date** is the date of the game's programs on its
  floppies, 1991-07-30 14:47.
- **Properties** for the MCGA program only, whose data segment (3173h) the
  findings map: the other builds keep the same data elsewhere.
- **The firmware** may be the project's own (the owner's decision for game
  cores, 2026-09-29): an image whose hash is not the declared one is taken as
  it is; refused are a missing image, a file that is not a FAT12 floppy, and
  floppies without the program the Video setting asks for.
- **CI on ubuntu-24.04**: GCC 15 (Ubuntu 26.04, which `ubuntu-latest` is
  moving to) compiles C as C23, where the guest musl's `char *basename();`
  declares a function of no arguments, and miniBox's guest libstdc++ stops
  building in libbacktrace. Measured on jaffanator2 (Ubuntu 26.04.1, GCC
  15.2.0); the same build passes there with a `gcc` that adds `-std=gnu17`.
  This is miniBox's to fix, for every C++ core.

## Measurements

- 2,000 steps of the title: native == sandboxed in every digest (picture,
  sound, step lengths, the four domains), 3 s each on jaffanator2.
- The exhibition (`waterbox/tests/exhibition.plan`): the title's EXHIBITION
  at step 4100, the boxer selection by 4300 (Paul Savage, the human, against
  The Champ), the manual's question from about 8300 (this run's: Mac the
  ouch), the ring, the round started at 29000 (1:59.5 on its clock), the human
  on the keypad - 31,200 steps, 48 s natively. The keys reach the game's own
  keyboard table (DS:6D08: 48h held with keypad 8, 1Ch with Enter).
- The core gate (`waterbox/run-gate.sh`, jaffanator2, 2026-10-21): 58 legs, 0
  failed, 0 skipped, in 13 minutes. Six runs - the title (2,000 steps), the
  exhibition (31,200), the EGA's, CGA's and Tandy's titles, the MT-32's -
  each native == sandboxed, deterministic, the same under turbo, lossless with
  a savestate before every step, and finished by a new host from half way; the
  nine pictures pinned (looked at: the title, the credits, the boxer
  selection, the manual's question, the round's start at 1:59.5, the fight,
  and the three other builds' titles); four programs with their own pictures
  at 70.086 and 59.92 Hz; five drivers, five sounds (the MT-32's stereo); the
  MT-32 by default; the clock's ticks; the keys in the game's table; the game's
  end at a wrong answer (step 15145: the real game quits at the first, not
  after three tries - Open4DBoxing's findings said three, and were corrected);
  the property table, a poke (the question made to want Glump Fistwhistle, and
  taken) and a freeze; seven refusals and acceptances of the firmware; a
  package the same twice.
- Each leg new to this core seen to fail on a break of its own (a copy of the
  core with one thing broken, rebuilt, the leg's own check run): keypad 8
  sent as keypad 9's code - `keys:table` sees 48h up; the clock setting
  ignored - `settings:clock` sees the same ticks; the game's end not noted -
  `game:ends` sees Ended 0; the video setting ignored - `settings:video` sees
  the EGA run be the MCGA run; the driver's state in memory no savestate
  carries (ECL_INVISIBLE) - `session` sees the new host's frames restart; the
  question's property two bytes off - the poke leg sees the name refused; the
  mouse never moved - `picture:question` sees the clicks miss DONE. The legs
  carried over from the OpenSamurai core (equivalence, determinism, turbo,
  savestates, the stack) were not broken again here.
- Chimera's contract tests (`InstalledCorePackagesTests`,
  `MnemonicUniquenessTests`) against the package alone: 22 passed, run with
  Mono on another machine (Ubuntu 26.04 has no Mono package, so jaffanator2
  cannot run .NET Framework tests). The same tests on a copy whose Mouse Left
  was bound to `WMouse Q` fail `KeybindsNameKeysAndMouseInputsChimeraSends`,
  naming it: they read this package.

## Open

- The frontend gate (`waterbox/tests/run-frontend.sh`, docs/new-core.md
  section 8): a project through the real frontend, headless, and a movie
  replayed on Linux and on Windows. Not yet done.
- Properties for the EGA, CGA and Tandy programs.
- The joystick (Open4DBoxing emulates the game port; Chimera's axes could
  drive it).
