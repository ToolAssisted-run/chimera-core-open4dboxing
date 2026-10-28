#!/bin/bash
# The frontend half of the tests: the package, as Chimera loads it, playing
# 4D Sports Boxing from the user's floppy images (tests/roms-local, or -d;
# never in the repository): the exhibition of exhibition.plan, 31,200 steps
# from the title through the boxer selection and the manual's question into
# the ring. Without the images only the package is built.
#
# - chimera-run (the engine, no frontend), where there is one: the route from
#   a movie file and from a hand-written project. The Game State,
#   Conventional Memory and Video Memory domains and the last picture must be
#   the native reference's.
# - Chimera itself, headless under Mono on a private Xvfb: the same project
#   opened and played through Lua, its domains compared with the native
#   reference, and saved; the saved project played again by a new Chimera
#   process; the property library (game.list/get/set/describe) tried against
#   the same bytes; the core's own refusal reaching the frontend; the
#   package's keybinds becoming the defaults.
# - With --windows, Chimera's Windows bundle under Wine: the project the Linux
#   frontend saved, played there to the same machine.
#
# Nothing is written under the Chimera folder or in Chimera's default data
# home: the config, the data home, the Base path and the sandbox's log are all
# in build/frontend, and the Windows bundle is played from a copy there.
#
# Usage: ./run-frontend.sh [--chimera <checkout or bundle>] [--chimera-run <path>]
#                          [-m <miniBox dir>] [-p <package>] [-d <dir>] [--windows <bundle>]
#   --chimera   a Chimera checkout (build/Chimera.exe) or a release bundle
#               (Chimera.exe at its top); default ../chimera or ~/chimera
#   -p          test this package instead of building one (a release's, say)
#   -d          the floppies' images and roland/ (the MT-32's ROMs)
#   --windows   Chimera's Windows bundle, run under Wine, with Microsoft's .NET
#               Framework 4.8 in the prefix (docs/BUILDING.md, Troubleshooting)
# MONO and WINE name the commands that run Chimera.exe (default mono, wine).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
wb="$(cd "$here/.." && pwd)"
root="$(cd "$wb/.." && pwd)"
chimera_root=""
crun=""
mb="${MINIBOX_DIR:-}"
package=""
data="${BOXING_DIR:-$root/tests/roms-local}"
windows=""
MONO="${MONO:-mono}"
WINE="${WINE:-wine}"
while [ $# -gt 0 ]; do
	case "$1" in
		--chimera) chimera_root="$2"; shift ;;
		--chimera-run) crun="$2"; shift ;;
		-m) mb="$2"; shift ;;
		-p) package="$2"; shift ;;
		-d) data="$2"; shift ;;
		--windows) windows="$2"; shift ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done
if [ -z "$chimera_root" ]; then
	for candidate in "$root/../chimera" "$HOME/chimera"; do
		[ -d "$candidate" ] && { chimera_root="$candidate"; break; }
	done
fi
[ -n "$chimera_root" ] && [ -d "$chimera_root" ] || { echo "chimera not found; pass --chimera" >&2; exit 1; }
chimera_root="$(cd "$chimera_root" && pwd)"
# a checkout keeps the frontend in build/, a release bundle at its top
if [ -f "$chimera_root/build/Chimera.exe" ]; then chimera_home="$chimera_root/build"; else chimera_home="$chimera_root"; fi
emu_exe="$chimera_home/Chimera.exe"
[ -n "$crun" ] || crun="$chimera_home/dll/chimera-run"
[ -n "$mb" ] || mb="$chimera_root/extern/chimera-common-minibox"
rn="$root/build/native/run-native"

work="$root/build/frontend"
rm -rf "$work"
mkdir -p "$work/data"

ok=0
failed=0
skipped=0
report() {
	printf "%-26s %-6s %s\n" "$1" "$2" "$3"
	case "$2" in PASS) ok=$((ok+1)) ;; SKIP) skipped=$((skipped+1)) ;; *) failed=$((failed+1)) ;; esac
}
summary() { echo; echo "$ok ok, $failed failed, $skipped skipped"; }
printf "%-26s %-6s %s\n" "Check" "Result" "Detail"
printf "%-26s %-6s %s\n" "-----" "------" "------"

[ -x "$rn" ] || { echo "native reference not built (make -f native.mk)" >&2; exit 1; }

# ---------------------------------------------------------------- the package
mkdir -p "$work/pkg"
pkg="$work/pkg/open4dboxing.chimeraCore"
if [ -n "$package" ]; then
	if [ -f "$package" ] && cp "$package" "$pkg"; then
		report "package" PASS "given: $(basename "$package"), sha1 $(sha1sum < "$pkg" | cut -c1-40)"
	else
		report "package" FAIL "no package at $package"; summary; exit 1
	fi
elif sh "$wb/build-package.sh" -m "$mb" -o "$work/pkg" > "$work/package.log" 2>&1; then
	report "package" PASS "$(grep 'package sha1' "$work/package.log")"
else
	report "package" FAIL "see build/frontend/package.log"; summary; exit 1
fi

if [ ! -f "$data/disk1.img" ] || [ ! -f "$data/disk2.img" ]; then
	report "game" SKIP "no floppy images of 4D Sports Boxing (disk1.img, disk2.img) in $data (-d); they are never in the repository"
	summary; exit 0
fi

# the project's firmware: the floppies, and the MT-32's ROMs for the default
# sound; without the ROMs the project names the Sound Blaster
files=("disk1.img=$data/disk1.img" "disk2.img=$data/disk2.img")
settings='{}'
if [ -f "$data/roland/MT32_CONTROL.ROM" ] && [ -f "$data/roland/MT32_PCM.ROM" ]; then
	files+=("MT32_CONTROL.ROM=$data/roland/MT32_CONTROL.ROM" "MT32_PCM.ROM=$data/roland/MT32_PCM.ROM")
	sound="the MT-32 (the default)"
else
	settings='{"sound":"sb"}'
	sound="the Sound Blaster (no MT-32 ROMs in $data/roland)"
fi
fw=()
for f in "${files[@]}"; do fw+=(--firmware "$f"); done

steps=31200
python3 "$here/plan2movie.py" "$here/exhibition.plan" "$work/exhibition.movie"

# the native reference: the movie, each domain after the last step (a run
# dumps one), its last picture and the property table
domains=("Game State:gs" "Conventional Memory:cm" "Video Memory:vm")
for d in "${domains[@]}"; do
	name="${d%%:*}" key="${d##*:}" wd="$work/native-${d##*:}"
	mkdir -p "$wd"
	for f in "${files[@]}"; do cp "${f#*=}" "$wd/${f%%=*}"; done
	printf '%s' "$settings" > "$wd/settings"
	extra=()
	[ "$key" = gs ] && extra=(--screenshot "$((steps - 1)):$work/native.last.tga" --props-json "$work/props.json")
	"$rn" "$wd" --frames "$steps" --movie "$work/exhibition.movie" --dump-domain "$name" "$work/native.$key.bin" \
		"${extra[@]}" > "$work/native-$key.log" 2>&1 &
done
wait
want() { sha256sum < "$work/native.$1.bin" | cut -c1-64; }
same_as_native() {   # same_as_native <prefix of three dumps>
	cmp -s "$work/native.gs.bin" "$1.gs.bin" && cmp -s "$work/native.cm.bin" "$1.cm.bin" && cmp -s "$work/native.vm.bin" "$1.vm.bin"
}
for k in gs cm vm; do [ -s "$work/native.$k.bin" ] || { report "native" FAIL "no $k dump (build/frontend/native-$k.log)"; summary; exit 1; }; done

python3 "$here/make-project.py" "$pkg" "$work/test.chimeraProject" "$steps" "${fw[@]}" --movie "$work/exhibition.movie" \
	--settings "$settings" --log-out "$work/test.log"

# what the property checks expect, from the core's own table and the reference's bytes
python3 - "$work/props.json" "$work/native.cm.bin" "$work/expect" <<'EOF'
import json, struct, sys
props = {p["name"]: p for p in json.load(open(sys.argv[1]))["properties"]}
cm = open(sys.argv[2], "rb").read()
h, q = props["Blue.Health"], props["Manual Question.Boxer"]
value = struct.unpack_from("<H", cm, q["offset"])[0]
open(sys.argv[3], "w").write(f'{len(props)} {h["offset"]} {struct.unpack_from("<h", cm, h["offset"])[0]}\n'
                             f'{q.get("values", {}).get(str(value), value)}\n')
EOF
read -r nprops health_at health_want < "$work/expect"
question_want="$(sed -n 2p "$work/expect")"

# ---------------------------------------------------------------- chimera-run
if [ ! -x "$crun" ]; then
	report "engine" SKIP "no chimera-run at $crun (--chimera-run)"
else
	: > "$work/empty.rom"
	( cd "$work" && "$crun" "$pkg" empty.rom test.log --settings "$settings" "${fw[@]}" \
		--dump "Game State=$work/run.gs.bin" --dump "Conventional Memory=$work/run.cm.bin" --dump "Video Memory=$work/run.vm.bin" \
		--screenshot "$((steps - 1))=$work/run.last.tga" --meta "$work/run.meta" > "$work/run.log" 2>&1 )
	if grep -q '^status=OK' "$work/run.meta" 2>/dev/null && same_as_native "$work/run" &&
	   python3 "$here/compare-pictures.py" "$work/native.last.tga" "$work/run.last.tga" > "$work/run.pic" 2>&1; then
		report "engine:movie" PASS "$steps steps from a movie file: the three domains and the last picture are the reference's"
	else
		report "engine:movie" FAIL "$(grep -m1 detail= "$work/run.meta" 2>/dev/null) $(cat "$work/run.pic" 2>/dev/null) (build/frontend/run.log)"
	fi

	( cd "$work" && "$crun" --project "$work/test.chimeraProject" "$pkg" "${fw[@]}" \
		--dump "Game State=$work/proj.gs.bin" --dump "Conventional Memory=$work/proj.cm.bin" --dump "Video Memory=$work/proj.vm.bin" \
		--meta "$work/proj.meta" > "$work/proj.log" 2>&1 )
	if grep -q '^status=OK' "$work/proj.meta" 2>/dev/null && same_as_native "$work/proj"; then
		report "engine:project" PASS "a project with no files, the floppies its firmware ($sound): the same machine"
	else
		report "engine:project" FAIL "$(grep -m1 detail= "$work/proj.meta" 2>/dev/null) (build/frontend/proj.log)"
	fi
fi

# ---------------------------------------------------------------- Chimera itself
if [ ! -f "$emu_exe" ]; then
	report "frontend" SKIP "Chimera not built: $emu_exe"
	summary; [ "$failed" -eq 0 ]; exit
fi
export LD_LIBRARY_PATH="$chimera_home/dll:$chimera_home:/usr/lib/x86_64-linux-gnu"
export MONO_CRASH_NOFILE=1 MONO_WINFORMS_XIM_STYLE=disabled ALSOFT_DRIVERS=null
export CHIMERA_DATA_HOME="$work/data" MINIBOX_LOG="$work/minibox.log"
xvfb_pid=""
cleanup() { [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null; }
trap cleanup EXIT
if [ -z "${DISPLAY:-}" ]; then
	command -v Xvfb > /dev/null || { report "frontend" SKIP "no Xvfb"; summary; exit 0; }
	for n in 90 91 92 93 94 95 96 97 98 99; do
		if [ ! -e "/tmp/.X11-unix/X$n" ]; then
			Xvfb ":$n" -screen 0 1280x1024x24 +extension GLX -nolisten tcp > "$work/xvfb.log" 2>&1 & xvfb_pid=$!
			export DISPLAY=":$n"; break
		fi
	done
	sleep 1
fi

# what the home check counts from: before Chimera first starts
touch "$work/configured"
sleep 1
# a config of its own, written before the first start with the Base path (and
# so every folder Chimera makes by default) in the work dir; the first start
# fills in the rest
config="$work/config.ini"
base_config() {   # base_config <config> <Base path> [more JSON members]
	python3 -c 'import json, sys; c = json.loads("{" + sys.argv[3] + "}"); c["PathEntries"] = {"Paths": [{"Type": "Base", "Path": sys.argv[2], "System": "Global_NULL"}]}; json.dump(c, open(sys.argv[1], "w"), indent=2)' "$@"
}
base_config "$config" "$work" ""
echo 'client.exit()' > "$work/exit.lua"
( cd "$work" && timeout 120 $MONO "$emu_exe" --headless "--config=$config" "--lua=$work/exit.lua" ) > "$work/bootstrap.log" 2>&1

gfw=()
for f in "${files[@]}"; do gfw+=("--firmware=$f"); done
gui() {
	# gui <tag> <config> <project> <frames> [save] [props]
	local tag="$1" cfg="$2" project="$3" nframes="$4"
	mkdir -p "$work/$tag"
	printf 'frames=%s\nmeta=%s\nsave=%s\nprops=%s\nhealth=%s\n' "$nframes" "$work/$tag/meta.txt" "${5:-0}" "${6:-0}" "$health_at" > "$work/$tag/job.txt"
	( cd "$work" && MINIHAWK_JOB="$work/$tag/job.txt" timeout 900 $MONO "$emu_exe" --headless "--config=$cfg" \
		"--core=$pkg" "${gfw[@]}" "--project=$project" "--lua=$here/frontend.lua" ) > "$work/$tag.log" 2>&1
	echo $?
}
meta() { sed -n "s/^$2=//p" "$work/$1/meta.txt" 2>/dev/null; }
hashes_ok() {   # hashes_ok <tag>: the domains Lua hashed are the reference's
	[ "$(meta "$1" status)" = "OK" ] && [ "$(meta "$1" frames)" = "$steps" ] &&
	[ "$(meta "$1" hash_gs | tr A-F a-f)" = "$(want gs)" ] && [ "$(meta "$1" hash_cm | tr A-F a-f)" = "$(want cm)" ] &&
	[ "$(meta "$1" hash_vm | tr A-F a-f)" = "$(want vm)" ]
}
hashes_detail() { echo "status $(meta "$1" status) $(meta "$1" detail) frames $(meta "$1" frames)/$steps gs $(meta "$1" hash_gs | cut -c1-12) cm $(meta "$1" hash_cm | cut -c1-12) vm $(meta "$1" hash_vm | cut -c1-12)"; }

cp "$work/test.chimeraProject" "$work/gui.chimeraProject"
gui gui "$config" "$work/gui.chimeraProject" "$steps" 1 1 > /dev/null
if hashes_ok gui; then
	report "gui:project" PASS "the project opened in Chimera: after $(meta gui frames) frames ($(meta gui lag) lag) the three domains are the reference's"
else
	report "gui:project" FAIL "$(hashes_detail gui) (build/frontend/gui.log)"
fi

# the project as Chimera saved it is a movie of its own writing: a new
# process plays it to the same machine
if [ "$(meta gui saved)" = "1" ] && ! cmp -s "$work/test.chimeraProject" "$work/gui.chimeraProject"; then
	cp "$work/gui.chimeraProject" "$work/saved.chimeraProject"
	gui saved "$config" "$work/saved.chimeraProject" "$steps" > /dev/null
	if hashes_ok saved; then
		report "gui:saved-replay" PASS "the project Chimera saved, played by a new Chimera: the same three domains after $steps frames"
	else
		report "gui:saved-replay" FAIL "$(hashes_detail saved) (build/frontend/saved.log)"
	fi
else
	report "gui:saved-replay" FAIL "the project was not saved: $(meta gui saved)"
fi

# the property library: the table is the one the core exports, a value read
# by its name is its bytes, a set takes, a read-only one and a name the core
# does not have are refused, and a value with names is named
if [ "$(meta gui game_list)" = "absent" ]; then
	report "gui:game-properties" SKIP "this Chimera has no game.* library"
elif [ "$(meta gui game_list)" = "$nprops" ] && [ "$(meta gui health)" = "$health_want" ] && [ "$(meta gui health_bytes)" = "$health_want" ] &&
     [ "$(meta gui health_set)" = "true" ] && [ "$(meta gui health_after)" = "4321" ] && [ "$(meta gui health_bytes_after)" = "4321" ] &&
     [ "$(meta gui frame_set)" = "false" ] && [ "$(meta gui unknown)" = "nil" ] && [ "$(meta gui question_label)" = "$question_want" ]; then
	report "gui:game-properties" PASS "game.list() has the core's $nprops; Blue.Health by name is its bytes ($health_want), set to 4321 took; Frame (read only) refused; the question asks for $question_want"
else
	report "gui:game-properties" FAIL "list $(meta gui game_list)/$nprops, health $(meta gui health)/$(meta gui health_bytes)/$health_want, set $(meta gui health_set)->$(meta gui health_after)/$(meta gui health_bytes_after), frame $(meta gui frame_set), unknown $(meta gui unknown), question '$(meta gui question_label)'/'$question_want' $(meta gui game_error)"
fi

# the core's own refusal reaches the frontend: a start date that is not a
# date, which Chimera passes on as a string and only the core refuses
python3 - "$work/test.chimeraProject" "$work/bad-clock.chimeraProject" <<'EOF'
import json, sys
p = json.load(open(sys.argv[1]))
p["settings"]["clock_start"] = "1991-02-29 12:00:00"
json.dump(p, open(sys.argv[2], "w"), indent="\t")
EOF
code="$(gui refuse "$config" "$work/bad-clock.chimeraProject" 10)"
if grep -qF 'The start date and time is "1991-02-29 12:00:00". It is written YYYY-MM-DD HH:MM:SS, from 1980 on.' "$work/refuse.log"; then
	report "gui:refusal" PASS "the core's load error is what Chimera shows (headless: exit $code with the text)"
else
	report "gui:refusal" FAIL "exit $code; $(grep -m1 -i 'start date\|error' "$work/refuse.log" | cut -c1-100)"
fi

# the bindings the package ships become the frontend's defaults
python3 "$here/forget-controller.py" "$config" "$work/config.keys.ini" "4D Sports Boxing"
gui keys "$work/config.keys.ini" "$work/test.chimeraProject" 1 > /dev/null
if [ "$(meta keys status)" = "OK" ] && python3 "$here/check-keybinds.py" "$work/config.keys.ini" "$wb/default_keybinds.json" "4D Sports Boxing" > "$work/keys.txt" 2>&1; then
	report "gui:keybinds" PASS "$(cat "$work/keys.txt")"
else
	report "gui:keybinds" FAIL "$(head -1 "$work/keys.txt" 2>/dev/null) (build/frontend/keys.log)"
fi

# nothing written under Chimera's folder or in its default data home: no
# file or folder there is newer than the first start
data_home="${XDG_DATA_HOME:-$HOME/.local/share}/chimera"
written="$(find "$chimera_home" "$data_home" -newer "$work/configured" 2>/dev/null | head -3 | tr '\n' ' ')"
if [ -z "$written" ]; then
	report "gui:writes-nothing-home" PASS "nothing in Chimera's folder or in $data_home: the config, data home, Base path and logs all in build/frontend"
else
	report "gui:writes-nothing-home" FAIL "written: $written"
fi

# ---------------------------------------------------------------- Windows
if [ -z "$windows" ]; then
	report "windows" SKIP "no Windows bundle (--windows)"
	summary; [ "$failed" -eq 0 ]; exit
fi
wpath() { $WINE winepath.exe -w "$1" 2> /dev/null | tr -d '\r'; }
if [ ! -f "$windows/Chimera.exe" ] || [ "$(meta gui saved)" != "1" ]; then
	report "windows:saved-replay" FAIL "no Chimera.exe in $windows, or no saved project to play"
	summary; exit 1
fi
mkdir -p "$work/win/data"
# a copy of the bundle, so that a run leaves the one given as it was
cp -a "$windows" "$work/win/chimera"
# Wine runs everything as an administrator and calls itself an old Windows
# 10: the warnings Chimera shows for those would wait for a click
base_config "$work/win/config.ini" "$(wpath "$work/win")" '"SkipSuperuserPrivsCheck": true, "SkipOutdatedOsCheck": true'
printf 'frames=%s\nmeta=%s\nsave=0\nprops=0\nhealth=0\n' "$steps" "$(wpath "$work/win/meta.txt")" > "$work/win/job.txt"
wfw=()
for f in "${files[@]}"; do wfw+=("--firmware=${f%%=*}=$(wpath "${f#*=}")"); done
winrun() {   # winrun <log> <Chimera's arguments...>: on Wine's desktop, which the
	# first window of a .NET program does not bring up by itself
	local log="$1"; shift
	( cd "$work/win/chimera" && $WINE explorer.exe > /dev/null 2>&1 &
	  sleep 5
	  cd "$work/win/chimera" && MINIHAWK_JOB="$(wpath "$work/win/job.txt")" CHIMERA_DATA_HOME="$(wpath "$work/win/data")" \
		timeout 900 $WINE Chimera.exe --headless "--config=$(wpath "$work/win/config.ini")" "$@" > "$log" 2>&1
	  echo "exit=$?" >> "$log"
	  $WINE wineboot.exe -k > /dev/null 2>&1 )
}
echo 'client.exit()' > "$work/win/exit.lua"
winrun "$work/win/bootstrap.log" "--lua=$(wpath "$work/win/exit.lua")"
cp "$work/gui.chimeraProject" "$work/win/saved.chimeraProject"
winrun "$work/win.log" "--core=$(wpath "$pkg")" "${wfw[@]}" "--project=$(wpath "$work/win/saved.chimeraProject")" "--lua=$(wpath "$here/frontend.lua")"
if hashes_ok win; then
	report "windows:saved-replay" PASS "the project the Linux frontend saved, played by Chimera's Windows build under Wine: the same three domains after $steps frames"
else
	report "windows:saved-replay" FAIL "$(hashes_detail win) (build/frontend/win.log)"
fi

summary
[ "$failed" -eq 0 ]
