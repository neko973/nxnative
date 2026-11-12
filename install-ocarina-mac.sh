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

DUMP=""; YES=0; DAMAGED=0; CHECK=0; OUT=""; WORKDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --allow-damaged) DAMAGED=1 ;;
    --check) CHECK=1 ;;
    --out|-o) shift; OUT="${1:-}" ;;
    --work-dir) shift; WORKDIR="${1:-}" ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $1" "Run ./install-ocarina-mac.sh --help" ;;
    *) [ -z "$DUMP" ] && DUMP="$1" || die "more than one path given: \"$DUMP\" and \"$1\"" "Put quotes around a path that has spaces in it." ;;
  esac
  shift
done
[ $CHECK = 1 ] || [ -n "$DUMP" ] || die "no dump given" "Usage: ./install-ocarina-mac.sh /path/to/OcarinaOfTime.nup" "(your own dump of the game: a .nup file or a dump folder)"
[ -z "$DUMP" ] || [ -e "$DUMP" ] || die "there is nothing at \"$DUMP\"" "Give the path of your .nup file or dump folder. Drag it from Finder into the Terminal window to get its path."

ask() {   # ask "question": yes with --yes, else asks; no terminal = no
  [ $YES = 1 ] && return 0
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1"; read -r a; case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

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
APP=$(grep -ao '[^ ]*/[^/]*\.app' "$LOG" | tail -1)
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
