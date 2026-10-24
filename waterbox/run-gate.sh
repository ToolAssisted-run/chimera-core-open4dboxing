#!/bin/bash
# The core gate. The sandboxed core must play 4D Sports Boxing exactly as the
# native reference does (the same driver, Open4DBoxing and Munt built for the
# host) - picture, sound, every step's length, the clock and every memory
# domain - survive a savestate before every step and a new host in the middle
# of a run, and then:
#   - show the title and the credits, and go through an exhibition: the boxers
#     chosen with the mouse, the manual's question answered on the keyboard,
#     the ring, the round started, the human boxer on the keypad
#   - take its settings: each of the four builds (its own pictures and frame
#     rate), each sound driver (the MT-32's with its ROMs), the PC's clock
#   - give the game its keys as its own keyboard table has them
#   - with the cosmetic camera on, show the cameras' keys' views and leave the
#     game alone: the same memory, sound, clock and steps as without it
#   - take the first 64 buttons packed in FrameAdvance's mask as well, as
#     Chimera does, without pressing the function keys past them
#   - end when the manual's question is answered wrongly, as the original
#     does, and be a frame of nothing after
#   - export a property table that holds to chimera's docs/game-cores.md, and
#     obey a poke and hold a freeze through it
#   - refuse a project without the floppies' images, a file that is not a
#     floppy's image, floppies without the game, and the MT-32's sound without
#     its ROMs, each saying so; and take an image of the project's own
#   - ask for its game stack as a stack (MAP_STACK)
#   - package deterministically
#
# The game is the user's 4D Sports Boxing, never in the repository: the gate
# takes the floppies' images from tests/roms-local (disk1.img, disk2.img; the
# MT-32's ROMs in tests/roms-local/roland), or -d <dir>. Without them only the
# build, the declarations and the refusal of a project with no files run.
#
# Usage: ./run-gate.sh [-q] [-m <miniBox dir>] [-d <game dir>]
#   -q skips the build (uses what is built)
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
mb="${MINIBOX_DIR:-$HOME/chimera/extern/chimera-common-minibox}"
data="${BOXING_DIR:-$root/tests/roms-local}"
quick=0
while getopts "qm:d:" opt; do
	case "$opt" in
		q) quick=1 ;;
		m) mb="$OPTARG" ;;
		d) data="$OPTARG" ;;
		*) exit 2 ;;
	esac
done
mb="$(cd "$mb" 2>/dev/null && pwd)" || { echo "miniBox not found; pass -m or set MINIBOX_DIR" >&2; exit 1; }

nat="$root/build/native"
wbx="$root/build/guest/core.wbx"
work="$root/build/gate"
rm -rf "$work"
mkdir -p "$work"

ok=0
failed=0
skipped=0
report() {
	printf "%-30s %-6s %s\n" "$1" "$2" "$3"
	case "$2" in PASS) ok=$((ok+1)) ;; SKIP) skipped=$((skipped+1)) ;; *) failed=$((failed+1)) ;; esac
}
printf "%-30s %-6s %s\n" "Check" "Result" "Detail"
printf "%-30s %-6s %s\n" "-----" "------" "------"

digests() { grep -E '^(frames|vsync|videoHash|audioHash|stepsHash|lagFrames|clock|domain\[)'; }
# what a turbo run can be held to: all but the whole-run picture hash, which a
# run that skipped half its conversions cannot match - the half it drew is
# compared instead
turboDigests() { grep -E '^(frames|vsync|tailVideoHash|audioHash|stepsHash|lagFrames|clock|domain\[)'; }
# the MT-32's sound is not held to the native reference: Munt builds its tables
# with floating point, and glibc's libm and musl's round differently (the
# DOSBox-X and OpenSamurai cores' open item). The sandbox, which is what
# Chimera runs, is held to itself; natively everything else is compared
noAudio() { grep -vE '^audioHash='; }
# a program that stops stepping would spin forever; no run here takes an hour
native() { timeout 1800 "$nat/run-native" "$@"; }
boxed() { timeout 3600 "$nat/run-wbx" "$wbx" "$@"; }
# the property at a step of a trace (column 4 on is --trace-props, in order)
at() { awk -v s="$2" -v c="$3" '$1 == s { print $(3 + c) }' "$1"; }
pixels() { tail -c +19 "$1" | sha1sum | cut -c1-16; }
png() { python3 "$here/tests/tga2png.py" "$work/$1.tga" "$work/$1.png" 2 2>/dev/null; }
# a byte of the game's data segment (the MCGA build's, 3173h) in a dump of Conventional Memory
dsbyte() { python3 -c "import sys; print(open(sys.argv[1], 'rb').read()[0x31730 + int(sys.argv[2], 16)])" "$1" "$2" 2>/dev/null; }

# ------------------------------------------------------------------ 1. build
if [ "$quick" -eq 0 ]; then
	if make -C "$here" -f native.mk MB="$mb" -j"$(nproc)" > "$work/native-make.log" 2>&1 &&
	   make -C "$here" -f guest.mk MB="$mb" -j"$(nproc)" > "$work/guest-make.log" 2>&1; then
		report "build" PASS "native reference, harnesses and core.wbx (check-wbx clean)"
	else
		report "build" FAIL "see build/gate/*-make.log"
	fi
fi
[ -x "$nat/run-native" ] && [ -x "$nat/run-wbx" ] && [ -f "$wbx" ] || { echo "nothing built to test" >&2; exit 1; }
# a gate over an old core.wbx proves nothing about the sources: every source
# and the patch series must be older than what is tested
stale="$(find "$here" -maxdepth 1 \( -name '*.c' -o -name '*.h' -o -name '*.mk' \) \
	! -name 'run-*.c' ! -name 'gate-harness.h' -newer "$wbx" | head -3; find "$root/patches" -name '*.patch' -newer "$wbx" 2>/dev/null | head -1)"
if [ -n "$stale" ]; then
	report "build:fresh" FAIL "core.wbx is older than $(echo $stale | tr '\n' ' ')"
fi

# The game runs on a stack of its own, which must be asked for as a stack
# (mmap, MAP_STACK): on Windows miniBox cannot deliver a fault on a page the
# stack pointer is in unless it was told the page is a stack, and the x68k core
# died there on its first frame. Linux runs the core either way.
if nm "$root/build/guest/core/coro.o" 2>/dev/null | grep -q ' U mmap$'; then
	report "stacks:map-stack" PASS "the game's stack is mmap'd (MAP_STACK), not malloc'd"
else
	report "stacks:map-stack" FAIL "coro.o does not take its stack from mmap"
fi

# ------------------------------------------------------------------ 2. the declarations
if python3 "$here/tests/check-wire.py" "$root" > "$work/wire.txt" 2>&1; then
	report "wire:config==driver" PASS "$(cat "$work/wire.txt")"
else
	report "wire:config==driver" FAIL "$(tail -1 "$work/wire.txt")"
fi

# a work dir: the files the project would mount, and a settings file. The
# gate's runs are the Sound Blaster's unless they name the sound: the MT-32,
# the default, is not held to the native reference - its own run says mt32,
# and settings:sound-default what a project that names no sound gets.
workdir() {
	local wd="$work/$1" s="$2"
	mkdir -p "$wd"
	for f in disk1.img disk2.img; do [ -f "$data/$f" ] && cp "$data/$f" "$wd/"; done
	for f in "$data"/roland/*.ROM; do [ -f "$f" ] && cp "$f" "$wd/"; done
	case "$s" in *'"sound"'*) ;; '{}') s='{"sound":"sb"}' ;; *) s="{\"sound\":\"sb\",${s#\{}" ;; esac
	printf '%s' "$s" > "$wd/settings"
	echo "$wd"
}

# ------------------------------------------------------------------ 3. no files
wd="$work/nofiles"; mkdir -p "$wd"; printf '{"sound":"sb"}' > "$wd/settings"
boxed "$wd" --frames 1 > "$work/nofiles.txt" 2>/dev/null
if grep -qx "loadError=error.needs_disk"$'\x1f'"disk1.img" "$work/nofiles.txt"; then
	report "refuse:no-files" PASS "$(sed -n 's/^loadError=//p' "$work/nofiles.txt")"
else
	report "refuse:no-files" FAIL "$(head -1 "$work/nofiles.txt")"
fi

if [ ! -f "$data/disk1.img" ] || [ ! -f "$data/disk2.img" ]; then
	report "game" SKIP "no floppy images of 4D Sports Boxing (disk1.img, disk2.img) in $data"
	echo; echo "$ok ok, $failed failed, $skipped skipped"
	[ "$failed" -eq 0 ]; exit
fi
roms=0
[ -f "$data/roland/MT32_CONTROL.ROM" ] && [ -f "$data/roland/MT32_PCM.ROM" ] && roms=1

# ------------------------------------------------------------------ 4. refusals
refusal() {   # name, the expected loadError, then what to do to the work dir
	local name="$1" want="$2" wd
	wd="$(workdir "refuse-$name" '{}')"
	(cd "$wd" && eval "$3")
	boxed "$wd" --frames 1 > "$work/r-$name.txt" 2>/dev/null
	native "$wd" --frames 1 > "$work/r-$name.n.txt" 2>/dev/null
	if grep -qxF "loadError=$want" "$work/r-$name.txt" && cmp -s <(grep loadError "$work/r-$name.txt") <(grep loadError "$work/r-$name.n.txt"); then
		report "refuse:$name" PASS "$want"
	else
		report "refuse:$name" FAIL "$(grep -m1 . "$work/r-$name.txt")"
	fi
}
refusal missing-disk "error.needs_disk"$'\x1f'"disk2.img" "rm disk2.img"
refusal not-a-floppy "error.disks_unreadable"$'\x1f'"disk1.img: not a FAT disk's image (its boot sector's figures)" \
	"python3 -c \"open('disk1.img', 'wb').write(bytes(737280))\""
refusal not-the-game "error.program_not_on_disks"$'\x1f'"4DBMCGA.EXE" "cp disk2.img disk1.img"
if [ "$roms" = 1 ]; then
	refusal mt32-without-roms "error.needs_mt32_rom"$'\x1f'"MT32_PCM.ROM" \
		"rm MT32_PCM.ROM; printf '{\"sound\":\"mt32\"}' > settings"
fi

# an image of the project's own is taken in the original's place (Chimera pins
# its hash; user-decided 2026-09-29): disk1.img with its last sector, which no
# file holds, changed plays the title as the original does
wd="$(workdir custom-orig '{}')"
orig="$(boxed "$wd" --frames 800 2>/dev/null | grep -E '^(loadError|frames|videoHash|domain)')"
wd="$(workdir custom-image '{}')"
python3 -c "import sys; p=sys.argv[1]; d=bytearray(open(p,'rb').read()); d[-512:]=bytes(b ^ 0x55 for b in d[-512:]); open(p,'wb').write(d)" "$wd/disk1.img"
custom="$(boxed "$wd" --frames 800 2>/dev/null | grep -E '^(loadError|frames|videoHash|domain)')"
if ! echo "$custom$orig" | grep -q loadError && [ -n "$custom" ] && [ "$custom" = "$orig" ] && ! cmp -s "$wd/disk1.img" "$data/disk1.img"; then
	report "firmware:custom" PASS "a disk1.img of the project's own (its last, unused sector changed) is taken: the same 800 steps"
else
	report "firmware:custom" FAIL "custom [$(echo $custom | head -c 80)] original [$(echo $orig | head -c 80)]"
fi

# ------------------------------------------------------------------ 5. the runs
python3 "$here/tests/plan2movie.py" "$here/tests/exhibition.plan" "$work/exhibition.movie"
python3 "$here/tests/plan2movie.py" "$here/tests/exhibition.plan" "$here/tests/camera.plan" "$work/camera.movie"
# name, steps, settings, what the run does
tests=(
	"title|2000|{}|title"
	"exhibition|31200|{}|exhibition"
	"camera|31200|{\"cosmetic_camera\":true}|camera"
	"ega|2000|{\"video\":\"ega\"}|title"
	"cga|2000|{\"video\":\"cga\"}|title"
	"tandy|2000|{\"video\":\"tandy\"}|title"
)
[ "$roms" = 1 ] && tests+=("mt32|2000|{\"sound\":\"mt32\"}|title")
test_args() {
	case "$1" in
		title) args=(--screenshot "700:$work/$2-title.tga" --screenshot "1999:$work/$2-credits.tga") ;;
		exhibition) args=(--movie "$work/exhibition.movie" --screenshot "4300:$work/select.tga" --screenshot "8300:$work/question.tga"
			--screenshot "29150:$work/round.tga" --screenshot "31199:$work/fight.tga") ;;
		camera) args=(--movie "$work/camera.movie" --screenshot "29150:$work/camera-round.tga" --screenshot "31199:$work/camera-fight.tga") ;;
	esac
}
for t in "${tests[@]}"; do
	IFS='|' read -r name frames settings what <<< "$t"
	wd="$(workdir "$name" "$settings")"
	test_args "$what" "$name"
	args+=(--frames "$frames")
	cmpnat=digests
	[ "$name" = mt32 ] && cmpnat=noAudio

	if ! native "$wd" "${args[@]}" > "$work/$name.native.txt" 2> "$work/$name.native.err"; then
		report "$name:equivalence" FAIL "native runner: $(tail -1 "$work/$name.native.err")"; continue
	fi
	if ! boxed "$wd" "${args[@]}" --props-json "$work/$name.box.json" > "$work/$name.box.txt" 2> "$work/$name.box.err"; then
		report "$name:equivalence" FAIL "sandbox runner: $(tail -1 "$work/$name.box.err")"; continue
	fi
	digests < "$work/$name.native.txt" | $cmpnat > "$work/nat.txt"
	digests < "$work/$name.box.txt" | $cmpnat > "$work/boxcmp.txt"
	digests < "$work/$name.box.txt" > "$work/box.txt"
	boxed "$wd" "${args[@]}" 2>/dev/null | digests > "$work/again.txt"
	if cmp -s "$work/box.txt" "$work/again.txt"; then
		report "$name:determinism" PASS "a second sandboxed run is the same"
	else
		report "$name:determinism" FAIL "$(diff "$work/box.txt" "$work/again.txt" | tr '\n' ' ' | head -c 110)"
	fi
	if cmp -s "$work/nat.txt" "$work/boxcmp.txt"; then
		report "$name:equivalence" PASS "$frames steps, native == sandboxed ($(grep -c . "$work/boxcmp.txt") digests$([ "$name" = mt32 ] && echo '; the MT-32 sound held to the sandbox'))"
	else
		report "$name:equivalence" FAIL "$(diff "$work/nat.txt" "$work/boxcmp.txt" | tr '\n' ' ' | head -c 110)"; continue
	fi

	boxed "$wd" "${args[@]}" 2>/dev/null | turboDigests > "$work/tnorm.txt"
	boxed "$wd" "${args[@]}" --turbo 2>/dev/null | turboDigests > "$work/turbo.txt"
	if cmp -s "$work/tnorm.txt" "$work/turbo.txt"; then
		report "$name:turbo" PASS "half the pictures unconverted, same game and same second half"
	else
		report "$name:turbo" FAIL "$(diff "$work/tnorm.txt" "$work/turbo.txt" | tr '\n' ' ' | head -c 110)"
	fi

	boxed "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/rr.txt"
	if cmp -s "$work/box.txt" "$work/rr.txt"; then
		report "$name:savestate" PASS "saved and loaded before every step: lossless"
	else
		report "$name:savestate" FAIL "$(diff "$work/box.txt" "$work/rr.txt" | tr '\n' ' ' | head -c 110)"
	fi

	boxed "$wd" "${args[@]}" --session 2> "$work/ss.err" | digests > "$work/ss.txt"
	if cmp -s "$work/box.txt" "$work/ss.txt"; then
		report "$name:session" PASS "a new host finished the run from a state at step $((frames / 2))"
	else
		report "$name:session" FAIL "$(diff "$work/box.txt" "$work/ss.txt" | tr '\n' ' ' | head -c 110)"
	fi
done

# ------------------------------------------------------------------ 6. what the runs showed
# the pictures, as the gate last saw them (look at build/gate/*.png)
for shot in "title-title:700 (the title):46cfd161bbc933c3" "title-credits:1999 (the credits):b2ea8fcb2a88b79b" "select:4300 (the blue boxer chosen):26ba1aa61c738252" \
	"question:8300 (the manual's question):d4dd62855fac67e5" "round:29150 (the round begun):74a87751d4496156" "fight:31199 (the fight):9b890bf9ebb18be4" \
	"ega-title:700 (the EGA's title):78dd5ef96e5ae0ed" "cga-title:700 (the CGA's title):608d34170cdd16da" "tandy-title:700 (the Tandy's title):ce62e28bfb6b5b61"; do
	IFS=':' read -r file what want <<< "$shot"
	png "$file"
	got="$(pixels "$work/$file.tga")"
	if [ "$got" = "$want" ]; then
		report "picture:$file" PASS "step $what is the picture it was (build/gate/$file.png)"
	else
		report "picture:$file" FAIL "step $what: pixels $got, expected $want (build/gate/$file.png)"
	fi
done

# the MT-32 plays: its sound is stereo (the chips' is the same on both sides)
if [ "$roms" = 1 ]; then
	if python3 - "$wbx" "$work/mt32" "$nat/run-wbx" > "$work/mt32.txt" 2>&1 <<'EOF'
import struct, subprocess, sys
wbx, wd, run = sys.argv[1:]
subprocess.run([run, wbx, wd, "--frames", "2000", "--audio", wd + "/a.raw"], capture_output=True, check=True)
d = open(wd + "/a.raw", "rb").read()
s = struct.unpack("<%dh" % (len(d) // 2), d)
stereo = sum(1 for i in range(0, len(s), 2) if s[i] != s[i + 1])
peak = max(abs(x) for x in s)
assert stereo > 1000 and peak > 1000, (stereo, peak)
print(f"2000 steps: {len(s) // 2} sound frames, {stereo} of them with left and right apart, peak {peak}")
EOF
	then
		report "sound:mt32" PASS "$(cat "$work/mt32.txt")"
	else
		report "sound:mt32" FAIL "$(tail -1 "$work/mt32.txt")"
	fi
else
	report "sound:mt32" SKIP "no MT-32 ROMs (MT32_CONTROL.ROM, MT32_PCM.ROM) in $data/roland"
fi

# the cosmetic camera: its run (the exhibition with F2, F5 and F9 in the round)
# is the exhibition's game - every memory domain, the sound, the clock, the
# steps - and its picture the game's until the first key, then the cameras'
gameOnly() { grep -E '^(frames|vsync|audioHash|stepsHash|lagFrames|clock|domain\[)'; }
if [ -s "$work/camera.box.txt" ] && [ -s "$work/exhibition.box.txt" ]; then
	gameOnly < "$work/exhibition.box.txt" > "$work/cam-ex.txt"
	gameOnly < "$work/camera.box.txt" > "$work/cam-cam.txt"
	if cmp -s "$work/cam-ex.txt" "$work/cam-cam.txt" && [ "$(grep -c . "$work/cam-cam.txt")" -gt 3 ]; then
		report "camera:game" PASS "the camera's keys pressed, the game the exhibition's ($(grep -c . "$work/cam-cam.txt") digests: memory, sound, clock, steps)"
	else
		report "camera:game" FAIL "$(diff "$work/cam-ex.txt" "$work/cam-cam.txt" | tr '\n' ' ' | head -c 110)"
	fi
	png camera-round; png camera-fight
	if [ "$(pixels "$work/camera-round.tga")" = "$(pixels "$work/round.tga")" ] &&
	   [ "$(pixels "$work/camera-fight.tga")" != "$(pixels "$work/fight.tga")" ] &&
	   [ "$(sed -n "s/^videoHash=//p" "$work/camera.box.txt")" != "$(sed -n "s/^videoHash=//p" "$work/exhibition.box.txt")" ]; then
		report "camera:pictures" PASS "step 29150 the game's picture (no key yet), step 31199 F9's view (build/gate/camera-fight.png)"
	else
		report "camera:pictures" FAIL "step 29150 $(pixels "$work/camera-round.tga") (game $(pixels "$work/round.tga")), step 31199 $(pixels "$work/camera-fight.tga") (game $(pixels "$work/fight.tga"))"
	fi
else
	report "camera:game" SKIP "no exhibition runs (no floppies' images)"
fi

# Chimera's packing: the frontend drives this core's 67 buttons through
# SetButton and may pack the first 64 in FrameAdvance's mask too; the function
# keys F8-F10 are buttons 64-66, never in that mask (the shift wraps: keypad 8,
# bit 2, would press F10). The exhibition and the camera run with the mask the
# same as without it - the round's keypad 8 the game's, no camera's
for name in exhibition camera; do
	[ -s "$work/$name.box.txt" ] || continue
	settings='{}'; [ "$name" = camera ] && settings='{"cosmetic_camera":true}'
	wd="$(workdir "$name" "$settings")"
	test_args "$name" "$name"
	boxed "$wd" "${args[@]}" --frames 31200 --packed 2>/dev/null | digests > "$work/$name.packed.txt"
	digests < "$work/$name.box.txt" > "$work/$name.unpacked.txt"
	if cmp -s "$work/$name.unpacked.txt" "$work/$name.packed.txt"; then
		report "packed:$name" PASS "the first 64 buttons in FrameAdvance's mask too, as Chimera packs them: the same run"
	else
		report "packed:$name" FAIL "$(diff "$work/$name.unpacked.txt" "$work/$name.packed.txt" | tr '\n' ' ' | head -c 110)"
	fi
done

# ------------------------------------------------------------------ 7. the settings
# each build its own pictures, at its own frame rate: the VGA's 70.086 Hz, the
# others' 59.92
v() { sed -n "s/^videoHash=//p" "$work/$1.box.txt"; }
r() { sed -n "s/^vsync=//p" "$work/$1.box.txt"; }
if [ "$(printf '%s\n' "$(v title)" "$(v ega)" "$(v cga)" "$(v tandy)" | sort -u | wc -l)" = 4 ] &&
   [ "$(r title)" = 25175000/359200 ] && [ "$(r ega)" = 14318180/238944 ] && [ "$(r cga)" = 14318180/238944 ] && [ "$(r tandy)" = 14318180/238944 ]; then
	report "settings:video" PASS "mcga, ega, cga and tandy: four programs' pictures; 70.086 Hz on the VGA, 59.92 on the others"
else
	report "settings:video" FAIL "video $(v title) $(v ega) $(v cga) $(v tandy); vsync $(r title) $(r ega) $(r cga) $(r tandy)"
fi

# each sound driver reaches the game: its own sound (and its own timing - the
# driver's work is the program's - so its own pictures too)
for s in sb adlib speaker tandy; do
	wd="$(workdir "sound-$s" "{\"sound\":\"$s\"}")"
	boxed "$wd" --frames 2000 2>/dev/null | grep -E '^(frames|videoHash|audioHash)' > "$work/sound-$s.txt"
done
sa() { sed -n "s/^audioHash=//p" "$work/sound-$1.txt"; }
mt32a="$( [ "$roms" = 1 ] && sed -n 's/^audioHash=//p' "$work/mt32.box.txt")"
count=$([ "$roms" = 1 ] && echo 5 || echo 4)
if [ "$(cat "$work"/sound-*.txt | grep -c '^frames=2000$')" = 4 ] &&
   [ "$(printf '%s\n' "$(sa sb)" "$(sa adlib)" "$(sa speaker)" "$(sa tandy)" $mt32a | sort -u | wc -l)" = "$count" ]; then
	report "settings:sound" PASS "sb, adlib, speaker, tandy$([ "$roms" = 1 ] && echo ' and mt32'): $count drivers, $count sounds over 2000 steps"
else
	report "settings:sound" FAIL "audio $(sa sb) $(sa adlib) $(sa speaker) $(sa tandy) $mt32a"
fi
# the MT-32 is the default: a project that names no sound plays the mt32 run's sound
if [ "$roms" = 1 ]; then
	wd="$(workdir sound-default '{"sound":"x"}')"; printf '{}' > "$wd/settings"
	dflt="$(boxed "$wd" --frames 2000 2>/dev/null | sed -n 's/^audioHash=//p')"
	if [ -n "$dflt" ] && [ "$dflt" = "$mt32a" ] && [ "$dflt" != "$(sa sb)" ]; then
		report "settings:sound-default" PASS "no sound setting: the MT-32's sound (the mt32 run's, 2000 steps)"
	else
		report "settings:sound-default" FAIL "default $dflt, mt32 $mt32a, sb $(sa sb)"
	fi
fi

# the PC's clock: another start is another BIOS tick count in the machine's
# memory, the same title; a date that is not one is refused
wd="$(workdir clock '{"clock_start":"1999-12-31 23:59:00"}')"
boxed "$wd" --frames 800 --dump-domain "Conventional Memory" "$work/clock.bin" > "$work/clock.txt" 2>/dev/null
wd="$(workdir clock-default '{}')"
boxed "$wd" --frames 800 --dump-domain "Conventional Memory" "$work/clock-default.bin" > /dev/null 2>&1
ticks() { python3 -c "import sys, struct; print(struct.unpack_from('<I', open(sys.argv[1], 'rb').read(), 0x46C)[0])" "$1" 2>/dev/null; }
wd="$(workdir clock-bad '{"clock_start":"1991-02-29 12:00:00"}')"
bad="$(boxed "$wd" --frames 1 2>/dev/null | sed -n 's/^loadError=//p')"
t1="$(ticks "$work/clock.bin")"; t0="$(ticks "$work/clock-default.bin")"
if [ -n "$t1" ] && [ -n "$t0" ] && [ "$t1" != "$t0" ] && [ "$bad" = "error.clock_start_setting"$'\x1f'"1991-02-29 12:00:00" ]; then
	report "settings:clock" PASS "1999-12-31 23:59: BIOS ticks $t1 at step 800 (the default's $t0); 1991-02-29 refused"
else
	report "settings:clock" FAIL "ticks $t1 vs $t0; bad: $bad"
fi

# ------------------------------------------------------------------ 8. the keyboard
# a key held is in the game's own keyboard table (DS:6D08, indexed by the scan
# code) while it is held: the exhibition's keypad 8 at step 29215, its Enter at 29250
wd="$work/exhibition"
boxed "$wd" --frames 29216 --movie "$work/exhibition.movie" --dump-domain "Conventional Memory" "$work/keys-kp8.bin" > /dev/null 2>&1
boxed "$wd" --frames 29251 --movie "$work/exhibition.movie" --dump-domain "Conventional Memory" "$work/keys-enter.bin" > /dev/null 2>&1
if [ "$(dsbyte "$work/keys-kp8.bin" 6D50)" = 1 ] && [ "$(dsbyte "$work/keys-kp8.bin" 6D24)" = 0 ] &&
   [ "$(dsbyte "$work/keys-enter.bin" 6D24)" = 1 ] && [ "$(dsbyte "$work/keys-enter.bin" 6D50)" = 0 ]; then
	report "keys:table" PASS "keypad 8 held: the game's table has 48h down (and not Enter); Enter held: 1Ch down (and not 48h)"
else
	report "keys:table" FAIL "48h $(dsbyte "$work/keys-kp8.bin" 6D50)/$(dsbyte "$work/keys-enter.bin" 6D50), 1Ch $(dsbyte "$work/keys-kp8.bin" 6D24)/$(dsbyte "$work/keys-enter.bin" 6D24)"
fi

# ------------------------------------------------------------------ 9. the game's own end
# the manual's question answered wrongly: the game ends at once, as the
# original does (Open4DBoxing's copy-wrong scenario: the real game ended at its
# first wrong answer's Enter), and every step after is a frame of nothing
cat > "$work/wrong.plan" <<'EOF'
key 4100 enter
mouse 5000 135 65
click 5400
click 8000
type 15000 nobody
end 20000
EOF
python3 "$here/tests/plan2movie.py" "$work/wrong.plan" "$work/wrong.movie"
wd="$(workdir wrong '{}')"
boxed "$wd" --frames 20000 --movie "$work/wrong.movie" --trace "$work/wrong.trace" --trace-props "Ended,Frame" > "$work/wrong.txt" 2>/dev/null
ended="$(awk '$1 ~ /^[0-9]+$/ && $4 == 1 { print $1; exit }' "$work/wrong.trace")"
frames_at_end="$(at "$work/wrong.trace" 19999 2)"
if [ -n "$ended" ] && [ "$(at "$work/wrong.trace" 19999 1)" = 1 ] && [ "$frames_at_end" -le "$((ended + 1))" ]; then
	report "game:ends" PASS "a wrong answer (nobody): the game ended at step $ended (Ended), and showed no frame after"
else
	report "game:ends" FAIL "ended at [$ended], Ended at the last step $(at "$work/wrong.trace" 19999 1), frames $frames_at_end"
fi

# ------------------------------------------------------------------ 10. the properties
if python3 "$here/tests/check-properties.py" "$work/exhibition.box.json" "$work/exhibition.box.txt" > "$work/props.txt" 2>&1; then
	report "properties:table" PASS "$(cat "$work/props.txt")"
else
	report "properties:table" FAIL "$(tail -1 "$work/props.txt")"
fi
# a poke through the table: the manual's question made to ask for Glump
# Fistwhistle (3) after it was asked (the run's own is Mac the ouch), and that
# name typed: the game takes it and goes on; and a freeze: the blue boxer's
# health held at 8000 through the round, where the game gives it back up to
# 16384 a few hundred a step - after every step it is still near 8000
cat > "$work/poke.plan" <<'EOF2'
key 4100 enter
mouse 5000 135 65
click 5400
click 8000
type 15000 Glump Fistwhistle
end 20000
EOF2
python3 "$here/tests/plan2movie.py" "$work/poke.plan" "$work/poke.movie"
wd="$work/exhibition"
boxed "$wd" --frames 20000 --movie "$work/poke.movie" --poke "14000:Manual Question.Boxer=3" \
	--trace "$work/poke.trace" --trace-props "Manual Question.Boxer,Ended" > /dev/null 2>&1
boxed "$wd" --frames 31200 --movie "$work/exhibition.movie" --freeze "29200-31199:Blue.Health=8000" \
	--trace "$work/freeze.trace" --trace-props "Blue.Health" > /dev/null 2>&1
off="$(awk '$1 ~ /^[0-9]+$/ && $1 >= 29200 && ($4 > 9000 || $4 < 0)' "$work/freeze.trace" | wc -l)"
if [ "$(at "$work/poke.trace" 13999 1)" = 7 ] && [ "$(at "$work/poke.trace" 14000 1)" = 3 ] && [ "$(at "$work/poke.trace" 19999 2)" = 0 ] &&
   [ "$off" = 0 ] && [ "$(at "$work/freeze.trace" 29199 1)" = 16384 ]; then
	report "properties:poke-freeze" PASS "the question poked from Mac the ouch (7) to Glump Fistwhistle (3): that name taken; Blue.Health frozen at 8000: at most 9000 after every step"
else
	report "properties:poke-freeze" FAIL "question $(at "$work/poke.trace" 13999 1) -> $(at "$work/poke.trace" 14000 1), ended $(at "$work/poke.trace" 19999 2); freeze off on $off steps"
fi

# ------------------------------------------------------------------ 11. the package
if sh "$here/build-package.sh" -m "$mb" -o "$work/pkg1" > "$work/pkg1.log" 2>&1 &&
   sh "$here/build-package.sh" -m "$mb" -o "$work/pkg2" > "$work/pkg2.log" 2>&1 &&
   cmp -s "$work/pkg1/open4dboxing.chimeraCore" "$work/pkg2/open4dboxing.chimeraCore"; then
	report "package" PASS "$(grep 'package sha1' "$work/pkg1.log"), the same twice"
else
	report "package" FAIL "see build/gate/pkg*.log"
fi

echo
echo "$ok ok, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
