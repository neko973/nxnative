#!/bin/bash
# One command that builds The Legend of Zelda: Ocarina of Time (Switch 2) as a Mac app from YOUR OWN dump of the game,
# with the 60 fps settings of this branch built in. Nothing of the game is in this repository.
#
#   ./install-ocarina-mac.sh /path/to/OcarinaOfTime.nup          (a .nup file, or the folder of a dump)
#
# Options (after the path):
#   --yes             install what is missing (Homebrew packages, the Metal toolchain) without asking
#   --allow-damaged   pack a dump some of whose files are damaged (the build stops and names them otherwise)
#   --out <app>       where to put the app (default: next to the dump, "<game name>.app")
#   --work-dir <dir>  where the build keeps its files, about 55 GB (default: a folder next to the dump); use it to
#                     build on another disk
#   --check           only check this Mac and say what is missing; build nothing
#
# To update an app this script built earlier, without the dump and in a few minutes instead of an hour and a half:
#
#   git pull
#   ./install-ocarina-mac.sh --update "/path/to/The Legend of Zelda Ocarina of Time.app"
#
# It builds the new host and launcher from this folder and puts them into the app with the new settings list, the
# built-in settings and the pipeline list, then signs the app again. What it replaces is kept in a folder beside the app
# ("<app name> before update <date>"). The game files, the shaders and your saves are not touched. It stops, and says
# so, when the app's shaders were built for another version of the shader tools than this folder's: then run the
# full install again.
#
# What it does: checks the Mac (Apple silicon, Xcode, the Metal compiler, Homebrew, free disk space), installs the
# two Homebrew packages and the Python modules the build needs (the modules go into a folder of their own here,
# .oot-venv, not into your system), then runs the project's packing script. The build takes 1 h 15 min to 1 h 45 min
# on an M3 Pro and needs about 60 GB of free disk while it runs. It can be run again: finished steps are reused.
set -u
cd "$(dirname "$0")" || exit 1
REPO=$(pwd)
TITLE=0400486024DEC000
NEED_GB=60

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { red "STOPPED: $1"; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }

DUMP=""; YES=0; DAMAGED=0; CHECK=0; OUT=""; WORKDIR=""; UPDATE=""; SELFUPDATE=""; CHECKUPDATE=""; FROMAPP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --allow-damaged) DAMAGED=1 ;;
    --check) CHECK=1 ;;
    --out|-o) shift; OUT="${1:-}" ;;
    --work-dir) shift; WORKDIR="${1:-}" ;;
    --update) shift; UPDATE="${1:-}"; [ -n "$UPDATE" ] || die "--update needs the app's path" "Usage: ./install-ocarina-mac.sh --update \"/path/to/the game.app\"" ;;
    --self-update) shift; SELFUPDATE="${1:-}"; [ -n "$SELFUPDATE" ] || die "--self-update needs the app's path" ;;   # the app's Check for Updates: git pull here, then --update
    --check-update) shift; CHECKUPDATE="${1:-}"; [ -n "$CHECKUPDATE" ] || die "--check-update needs the app's path" ;;   # says UPTODATE or AVAILABLE and what is new; changes nothing
    --from-app) FROMAPP=1 ;;   # started by the app's settings window, which stays open: PROGRESS lines for its bar
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $1" "Run ./install-ocarina-mac.sh --help" ;;
    *) [ -z "$DUMP" ] && DUMP="$1" || die "more than one path given: \"$DUMP\" and \"$1\"" "Put quotes around a path that has spaces in it." ;;
  esac
  shift
done
[ $CHECK = 1 ] || [ -n "$UPDATE" ] || [ -n "$SELFUPDATE" ] || [ -n "$CHECKUPDATE" ] || [ -n "$DUMP" ] || die "no dump given" "Usage: ./install-ocarina-mac.sh /path/to/OcarinaOfTime.nup" "(your own dump of the game: a .nup file or a dump folder)"
UPDATE="${UPDATE%/}"
if [ -n "$UPDATE" ]; then
  [ -z "$DUMP" ] || die "--update takes the app alone, not a dump as well" "Usage: ./install-ocarina-mac.sh --update \"/path/to/the game.app\""
  [ -d "$UPDATE/Contents/Resources/dm" ] && [ -f "$UPDATE/Contents/Info.plist" ] || die "\"$UPDATE\" is not an app this script built" "Give the path of the .app (drag it from Finder into the Terminal window)."
fi
[ -z "$DUMP" ] || [ -e "$DUMP" ] || die "there is nothing at \"$DUMP\"" "Give the path of your .nup file or dump folder. Drag it from Finder into the Terminal window to get its path."

ask() {   # ask "question": yes with --yes, else asks; no terminal = no
  [ $YES = 1 ] && return 0
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1"; read -r a; case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}


# --update: the new host, settings list, built-in settings and pipeline list into an app built earlier. Nothing here needs the dump: the host is built from this folder alone, and the
# settings list is made from the rewritten modules' tables the app carries. The app's shader library must be of a chain this folder's host can load: its own, or one of UPDATE_CHAINS, the
# chains whose libraries hold the same shaders (e87f5802f90a: the same translator sources as 3d08bd9723b0, built with another .NET runtime). A change to the shader tools or to the game's
# patches must empty that list: such an update needs the full install.
UPDATE_CHAINS="e87f5802f90a"
update_app() {
  APP="$UPDATE"; DM="$APP/Contents/Resources/dm"; PL="$APP/Contents/Info.plist"; CH="$REPO/dm/gfx/nvn/dmsh_chain.h"
  step "3/4  The app"
  TID=$(/usr/libexec/PlistBuddy -c "Print :DMTitleID" "$PL" 2>/dev/null || true)
  [ "$TID" = "$TITLE" ] || die "\"$APP\" is not Ocarina of Time for Switch 2 (title ID ${TID:-none}, expected $TITLE)"
  [ -f "$DM/main.fixups.tsv" ] && [ -f "$APP/Contents/MacOS/dmhost" ] || die "the app lacks files this script's builds have (Contents/MacOS/dmhost, Contents/Resources/dm/main.fixups.tsv)" "Run the full install instead."
  # fixed strings: pgrep reads its argument as a pattern, and "(native)" in a path never matched. From the app's own window (--from-app) the launcher runs and only the game counts
  # (a command line that begins with the path: a grep for it would find itself in the list)
  running() { ps -axo command= | awk -v p="$1" 'index($0, p) == 1 { f = 1 } END { exit !f }'; }
  if running "$APP/Contents/MacOS/dmhost" || running "$APP/Contents/Helpers/GameMode.app/Contents/MacOS/dmhost"; then die "the game is running" "Quit it, then run this again."; fi
  if [ $FROMAPP = 0 ] && running "$APP/Contents/MacOS/nxnative"; then die "the game's settings window is open" "Quit it, then run this again."; fi
  [ -w "$APP/Contents/MacOS" ] && [ -w "$DM" ] || die "cannot write into \"$APP\"" "Check the app's permissions, or copy it to a folder of your own."
  WANT=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"$/\1/p' "$CH")
  [ -n "$WANT" ] || die "no shader chain version in dm/gfx/nvn/dmsh_chain.h"
  HAVE=""; for f in "$APP/Contents/Resources/msl"/b-*; do [ -e "$f" ] || continue; n=$(basename "$f"); n=${n#b-}; HAVE="$HAVE ${n%.img}"; done
  USE=""
  case " $HAVE " in *" $WANT "*) USE="$WANT" ;; esac
  if [ -z "$USE" ]; then for c in $UPDATE_CHAINS; do case " $HAVE " in *" $c "*) USE="$c"; break ;; esac; done; fi
  [ -n "$USE" ] || die "the app's shaders (chain${HAVE:- none}) were built for another version of the shader tools than this folder's ($WANT)" "This update needs the full install:  ./install-ocarina-mac.sh /path/to/your/dump.nup" "(with the build's work folder still there, the steps that did not change are reused)."
  if [ "$USE" = "$WANT" ]; then echo "The app's shader library: chain $USE"; else echo "The app's shader library: chain $USE (the same shaders as this folder's $WANT; the host is built for it)"; fi
  SAVED_CH=""
  restore_chain() { if [ -n "$SAVED_CH" ]; then cp "$SAVED_CH" "$CH" && rm -f "$SAVED_CH"; SAVED_CH=""; fi; }
  trap restore_chain EXIT INT TERM
  if [ "$USE" != "$WANT" ]; then
    SAVED_CH=$(mktemp "${TMPDIR:-/tmp}/dmsh_chain.XXXXXX") && cp "$CH" "$SAVED_CH" || die "cannot keep a copy of dm/gfx/nvn/dmsh_chain.h"
    sed -i '' "s/^#define DMSH_CHAIN \"$WANT\"\$/#define DMSH_CHAIN \"$USE\"/" "$CH"
  fi

  step "4/4  Building the host and putting it into the app (a few minutes)"
  LOG="$REPO/install-ocarina-mac.log"; echo "Log: $LOG"
  creep 10 45 240 "Building the game program" & CREEP=$!
  if ! ( cd "$REPO/dm/host" && PATH="$VENV/bin:$PATH" make -s GAME=$TITLE dmhost ) >"$LOG" 2>&1; then
    kill $CREEP 2>/dev/null; restore_chain; tail -20 "$LOG" >&2; die "the host did not build" "The compiler's last lines are above and in $LOG."
  fi
  kill $CREEP 2>/dev/null; wait $CREEP 2>/dev/null; restore_chain; trap - EXIT INT TERM
  progress 48 "Putting the new files into the app"
  HOST="$REPO/dm/host/dmhost"
  strings -a "$HOST" | grep -q "$USE" || die "the host that was built is not for chain $USE" "See $LOG."
  KEEP="${APP%.app} before update $(date +%Y-%m-%d-%H%M)"
  mkdir -p "$KEEP" || die "cannot make the folder \"$KEEP\""
  cp -p "$APP/Contents/MacOS/dmhost" "$APP/Contents/MacOS/nxnative" "$PL" "$KEEP/" || die "cannot copy the old host and launcher into \"$KEEP\""
  for f in launcher.json env.txt pso_manifest.tsv; do [ ! -f "$DM/$f" ] || cp -p "$DM/$f" "$KEEP/"; done
  LANG_DEF=$(/usr/libexec/PlistBuddy -c "Print :DMLanguage" "$PL" 2>/dev/null || echo en-US)
  if ! SETTINGS_PLATFORM=mac GFXAPI=nvn DM_LANG="$LANG_DEF" "$VENV/bin/python" "$REPO/dm/games/settings.py" $TITLE "$DM" "" "$KEEP/launcher.new.json" >>"$LOG" 2>&1; then
    tail -5 "$LOG" >&2; die "the settings list could not be made" "Nothing in the app was changed. See $LOG."
  fi
  cp "$HOST" "$APP/Contents/MacOS/dmhost" && chmod 755 "$APP/Contents/MacOS/dmhost" || die "cannot write the host into the app" "The old one is in \"$KEEP\"."
  mv "$KEEP/launcher.new.json" "$DM/launcher.json"
  cp "$REPO/dm/games/$TITLE/mac-60fps.env" "$DM/env.txt"
  cp "$REPO/dm/games/$TITLE/pso_manifest.tsv" "$DM/pso_manifest.tsv"
  COMMIT=$(git -C "$REPO" rev-parse --short=12 HEAD 2>/dev/null || true)
  # Info.plist's DMSettings as dm/mac/pack_app.py settings_rules writes it: what the launcher accepts as each setting's saved choice
  "$VENV/bin/python" -c '
import json, plistlib, sys
pl, lj, commit = sys.argv[1:4]
info = plistlib.load(open(pl, "rb"))
rules = []
for s in json.load(open(lj, encoding="utf-8"))["settings"]:
    if s["kind"] == "range": rules.append({"env": s["env"], "min": float(s["min"]), "max": float(s["max"])})
    elif s["kind"] == "choice": rules.append({"env": s["env"], "values": [o[0] for o in s["options"]]})
    elif s["kind"] == "toggle": rules.append({"env": s["env"], "values": [s.get("on", "1"), s.get("off", "0")]})
info["DMSettings"] = rules
if commit: info["DMCommit"] = commit
open(pl, "wb").write(plistlib.dumps(info))
' "$PL" "$DM/launcher.json" "$COMMIT" || die "the app's Info.plist could not be updated" "Put the old files back from \"$KEEP\"."
  # The launcher built again (new settings may need it: Game Mode picks the host it starts) and the host under the bundle Game Mode takes (dm/mac/pack_app.py)
  if ! "$VENV/bin/python" -c '
import sys
sys.path[:0] = [sys.argv[1] + "/dm/mac"]
import pack_app
print("launcher and Game Mode host:", pack_app.update_launcher(sys.argv[2]))
' "$REPO" "$APP" >>"$LOG" 2>&1; then
    tail -8 "$LOG" >&2; die "the launcher could not be built" "Put the old files back from \"$KEEP\" (dmhost and nxnative into Contents/MacOS, Info.plist into Contents, the rest into Contents/Resources/dm). See $LOG."
  fi
  mkdir -p "$HOME/Library/Application Support/nxnative/$TITLE" && printf '%s\n' "$REPO/install-ocarina-mac.sh" > "$HOME/Library/Application Support/nxnative/$TITLE/update.path"   # where the app's Check for Updates finds this script
  echo "Signing the app (it reads the whole game image: two or three minutes) ..."
  creep 55 97 200 "Signing the app (two or three minutes)" & CREEP=$!
  find "$APP" -name '._*' -type f -delete 2>/dev/null
  codesign --force --sign - "$APP/Contents/Helpers/GameMode.app" >>"$LOG" 2>&1 && codesign --force --sign - "$APP/Contents/MacOS/dmhost" >>"$LOG" 2>&1 && codesign --force --sign - "$APP" >>"$LOG" 2>&1 && codesign --verify "$APP" >>"$LOG" 2>&1 \
    || { kill $CREEP 2>/dev/null; die "the app could not be signed" "See $LOG. The old host, settings and Info.plist are in \"$KEEP\"."; }
  kill $CREEP 2>/dev/null; wait $CREEP 2>/dev/null; progress 100 "Updated"
  echo
  bold "Updated: $APP"
  echo
  echo "- The game files, the shaders and your saves were not touched. What was replaced is in"
  echo "  \"$KEEP\"; delete that folder once the game runs."
  echo "- The first start may prepare a few more pipelines behind the progress screen (seconds, not minutes)."
  echo "- In the settings window: Full resolution (off unless you turn it on), Texture filtering, Texture size and Game Mode; Render scale now counts from the game's own size (docs/settings.md says what they do)."
}

# The app's Check for Updates (dm/mac/Launcher.swift) runs these two. PROGRESS <percent> <text> lines are for its bar
progress() { if [ $FROMAPP = 1 ]; then echo "PROGRESS $1 $2"; fi; }
creep() {   # creep <from> <to> <seconds> <text> &: the bar moving through a step that takes long and says nothing
  local i=0 n=$(( $3 / 2 )); while [ $i -lt $n ]; do progress $(( $1 + ($2 - $1) * i / n )) "$4"; sleep 2; i=$((i + 1)); done
}
self_update() {   # $1: the app; $2: 1 = only say whether there is something new
  local app="${1%/}" pl appc up behind headc
  pl="$app/Contents/Info.plist"; [ -f "$pl" ] || die "\"$app\" is not an app"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "this folder is not a git clone, so it cannot fetch updates" "Get one:  git clone -b ocarina-mac-60fps https://github.com/neko973/nxnative.git" "and run  ./install-ocarina-mac.sh --update \"$app\"  from it once."
  up=$(git -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || die "this folder's branch does not follow a branch of the fork" "Get a clone:  git clone -b ocarina-mac-60fps https://github.com/neko973/nxnative.git" "and run  ./install-ocarina-mac.sh --update \"$app\"  from it once."
  progress 2 "Looking for a new version"
  git -C "$REPO" fetch --quiet "${up%%/*}" 2>/dev/null || die "the fork could not be reached" "Check the internet connection and try again."
  appc=$(/usr/libexec/PlistBuddy -c "Print :DMCommit" "$pl" 2>/dev/null || true)
  behind=$(git -C "$REPO" rev-list --count 'HEAD..@{u}'); headc=$(git -C "$REPO" rev-parse --short=12 '@{u}')
  if [ "$2" = 1 ]; then
    if [ "$behind" = 0 ] && [ "$(git -C "$REPO" rev-parse --short=12 HEAD)" = "$appc" ]; then echo "UPTODATE $appc"; exit 0; fi
    echo "AVAILABLE $headc"
    { git -C "$REPO" log --no-merges --format='NEW %s' "$appc..@{u}" 2>/dev/null || git -C "$REPO" log --no-merges --format='NEW %s' 'HEAD..@{u}'; } | head -8
    exit 0
  fi
  if [ "$behind" != 0 ]; then
    progress 5 "Downloading the new version"
    git -C "$REPO" merge --ff-only --quiet '@{u}' 2>/dev/null || die "this folder has changes of its own that the update would overwrite" "In $REPO:  git status  shows them."
  fi
  if [ "$(git -C "$REPO" rev-parse --short=12 HEAD)" = "$appc" ]; then echo "UPTODATE $appc"; exit 0; fi
  # the script as the update brought it, not the one bash is reading
  if [ $FROMAPP = 1 ]; then exec /bin/bash "$REPO/install-ocarina-mac.sh" --update "$app" --from-app --yes; else exec /bin/bash "$REPO/install-ocarina-mac.sh" --update "$app" --yes; fi
}
[ -z "$CHECKUPDATE" ] || self_update "$CHECKUPDATE" 1
[ -z "$SELFUPDATE" ] || self_update "$SELFUPDATE" 0

step "1/5  This Mac"
[ "$(uname -s)" = Darwin ] || die "this builds a Mac app and runs on a Mac only"
[ "$(uname -m)" = arm64 ] || die "this needs a Mac with Apple silicon (M1 or later)" "The game's own code runs natively, which an Intel Mac cannot do." "If this IS an Apple silicon Mac, the Terminal is running under Rosetta: turn that off in the Terminal app's Get Info window."
OSV=$(sw_vers -productVersion); OSMAJ=${OSV%%.*}
[ "$OSMAJ" -ge 26 ] 2>/dev/null || die "macOS $OSV is too old: the renderer needs Metal 4 (macOS 26 or later)"
echo "Apple silicon, macOS $OSV"
MEMGB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
[ "$MEMGB" -ge 16 ] || red "note: this Mac has $MEMGB GB of memory; the game uses about 11 GB, so 16 GB is the practical minimum"

DEV=$(xcode-select -p 2>/dev/null || true)
case "$DEV" in
  "") die "Xcode is not installed" "Install Xcode from the App Store, open it once, then run this again." ;;
  *CommandLineTools*) die "the Command Line Tools are selected, but the build needs the full Xcode" "Install Xcode from the App Store, open it once, then run:" "    sudo xcode-select -s /Applications/Xcode.app" "and run this again." ;;
esac
XV=$(xcodebuild -version 2>&1 | head -1) || true
case "$XV" in
  Xcode*) echo "$XV" ;;
  *) die "Xcode does not run yet ($XV)" "Open Xcode once and accept its license, or run:  sudo xcodebuild -license accept" ;;
esac
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  echo "The Metal compiler (a separate download of Xcode, about 700 MB) is not installed."
  if [ $CHECK = 0 ] && ask "Download it now?"; then xcodebuild -downloadComponent MetalToolchain || die "the Metal toolchain did not install" "Try it in Xcode: Settings > Components > Metal Toolchain."
  else die "the Metal compiler is missing" "Install it with:  xcodebuild -downloadComponent MetalToolchain" "(or in Xcode: Settings > Components > Metal Toolchain), then run this again."; fi
fi
echo "Metal compiler: $(xcrun -sdk macosx metal --version 2>&1 | head -1)"

step "2/5  Tools"
BREW=$(command -v brew || true); [ -n "$BREW" ] || { [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew; }
[ -n "$BREW" ] || die "Homebrew is not installed" "Install it from https://brew.sh (one line to paste into the Terminal), then run this again."
eval "$("$BREW" shellenv)" 2>/dev/null || true
MISSING=""
command -v zstd >/dev/null 2>&1 || MISSING="$MISSING zstd"
command -v glslangValidator >/dev/null 2>&1 || MISSING="$MISSING glslang"
PY=""
for c in python3.14 python3.13 python3.12 python3; do
  p=$(command -v "$c" 2>/dev/null || true); [ -n "$p" ] || continue
  if "$p" -c 'import sys, platform; sys.exit(0 if sys.version_info >= (3, 12) and platform.machine() == "arm64" else 1)' 2>/dev/null; then PY="$p"; break; fi
done
[ -n "$PY" ] || MISSING="$MISSING python@3.13"
if [ -n "$MISSING" ]; then
  echo "Missing Homebrew packages:$MISSING"
  if [ $CHECK = 1 ]; then die "packages are missing" "Install them with:  brew install$MISSING"; fi
  ask "Install them with Homebrew now?" || die "packages are missing" "Install them with:  brew install$MISSING" "then run this again."
  # shellcheck disable=SC2086
  "$BREW" install $MISSING || die "Homebrew could not install:$MISSING"
  if [ -z "$PY" ]; then for c in python3.13 "$("$BREW" --prefix)/opt/python@3.13/bin/python3.13"; do p=$(command -v "$c" 2>/dev/null || true); [ -n "$p" ] && PY="$p" && break; done; fi
  [ -n "$PY" ] || die "no Python 3.12 or later was found after the install" "Open a new Terminal window and run this again."
fi
echo "Python: $PY ($("$PY" -c 'import platform; print(platform.python_version())'))"
echo "zstd, glslang: found"

VENV="$REPO/.oot-venv"
if [ $CHECK = 0 ]; then
  if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
    rm -rf "$VENV"; "$PY" -m venv "$VENV" || die "could not make the Python folder $VENV"
  fi
  MODS='lz4 capstone>=5,<6 fonttools zbic'
  "$VENV/bin/python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 14) else 1)' 2>/dev/null || MODS="$MODS backports.zstd"
  if ! "$VENV/bin/python" -c 'import lz4.block, capstone, fontTools, zbic, sys; sys.exit(0 if capstone.cs_version()[0] == 5 else 1)' 2>/dev/null; then
    echo "Installing the Python modules into .oot-venv (lz4, capstone 5, fonttools, zbic) ..."
    # shellcheck disable=SC2086
    "$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1
    "$VENV/bin/python" -m pip install --quiet $MODS || die "the Python modules did not install" "Check the internet connection and run this again."
  fi
  echo "Python modules: ready"
fi

[ -z "$UPDATE" ] || { update_app; exit 0; }

step "3/5  Disk space"
WHERE="$REPO"; [ -n "$DUMP" ] && { if [ -d "$DUMP" ]; then WHERE="$DUMP"; else WHERE=$(dirname "$DUMP"); fi; }
if [ -n "$WORKDIR" ]; then mkdir -p "$WORKDIR" || die "cannot make the work folder $WORKDIR"; WHERE="$WORKDIR"; fi
FREE_GB=$(( $(df -k "$WHERE" | awk 'NR==2 {print $4}') / 1048576 ))
echo "$FREE_GB GB free where the build keeps its files ($WHERE)"
if [ "$FREE_GB" -lt "$NEED_GB" ]; then
  red "A first build needs about $NEED_GB GB free while it runs (the unpacked game 24 GB, the shaders 20 GB, the pipelines 8 GB, the app)."
  [ $CHECK = 1 ] || ask "Go on anyway?" || die "not enough free disk space" "Free some space (emptying the Trash counts) and run this again."
fi
if [ $CHECK = 1 ]; then echo; bold "This Mac is ready. Run:  ./install-ocarina-mac.sh /path/to/your/dump.nup"; exit 0; fi

step "4/5  Building the app (1 h 15 min to 1 h 45 min; leave the Mac plugged in and awake)"
ARGS=(--platform mac-app --env-file "$REPO/dm/games/$TITLE/mac-60fps.env" --allow-other-metal --allow-shader-regressions --progress lines)
[ $DAMAGED = 1 ] && ARGS+=(--allow-damaged)
[ -n "$OUT" ] && ARGS+=(--out "$OUT")
[ -n "$WORKDIR" ] && ARGS+=(--work-dir "$WORKDIR")
LOG="$REPO/install-ocarina-mac.log"
echo "Log: $LOG"
caffeinate -i "$VENV/bin/python" scripts/build_ipa_from_nsp.py "$DUMP" "${ARGS[@]}" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
if [ "$RC" != 0 ]; then
  echo
  red "The build stopped (exit code $RC). Its last lines are above and in $LOG."
  if grep -q "allow-damaged" "$LOG"; then
    echo "Your dump has files that are damaged (the lines above name them). To pack them as they are, run:"
    echo "    ./install-ocarina-mac.sh \"$DUMP\" --allow-damaged"
    echo "The game ran here with three such texture files; a fresh dump is the clean fix."
  elif grep -qi "No space left\|not enough.*space\|disk.*full" "$LOG"; then
    echo "The disk filled up. Free space and run the same command again: finished steps are reused."
  elif grep -q "is not a title this\|no profile\|provisional profile" "$LOG"; then
    echo "The dump does not look like Ocarina of Time for Switch 2 (title ID $TITLE). Check which file you gave."
  else
    echo "Run the same command again once the cause is fixed: finished steps are reused."
  fi
  exit "$RC"
fi

step "5/5  Done"
mkdir -p "$HOME/Library/Application Support/nxnative/$TITLE" && printf '%s\n' "$REPO/install-ocarina-mac.sh" > "$HOME/Library/Application Support/nxnative/$TITLE/update.path"   # where the app's Check for Updates finds this script
APP=$(sed -n 's/^app: \(.*\.app\)$/\1/p' "$LOG" | tail -1)   # the packer's last line; a path may have spaces
[ -n "$APP" ] || APP=$(grep -ao '[^ ]*/[^/]*\.app' "$LOG" | tail -1)
[ -n "$OUT" ] && APP="$OUT"
bold "The app: ${APP:-next to your dump, named after the game}"
cat <<EOF

- Open it from Finder. The FIRST start prepares the graphics pipelines behind a progress screen for several
  minutes; later starts take seconds.
- It runs fullscreen with the frame rate set to 60; the app's settings window offers 30 / 40 / 60.
- The settings this branch was tested with are built into the app. To change one, see the comment at the top of
  dm/games/$TITLE/mac-60fps.env.
- Saves are in ~/Library/Application Support/nxnative/$TITLE/save and are kept when you rebuild.
- The build's work folder (next to your dump, ${TITLE}_build, or the --work-dir one) can be deleted once the app runs;
  keeping it makes a later rebuild much faster. Its shader/cache/cas.db alone is 10 GB you can delete at any time.
- Something wrong? The game's log is ~/Library/Logs/nxnative/$TITLE.log; the guide is docs/ocarina-of-time-mac-60fps.md.
EOF
