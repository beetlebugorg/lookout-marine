#!/bin/sh
# Capture the mariner-settings frames for the macOS host.
#
# One frame per section of the settings window. Each frame comes from its OWN
# app instance, launched with LOOKOUT_SHOW=settings:<section>, so a frame never
# depends on what the previous one left selected, scrolled or focused. See
# docs/docs/developer-guide/screenshots.md for the chart / camera / format the
# hosts share, and linux/screenshots.sh for the same job on the Linux host.
#
#   usage: screenshots.sh [SECTION|all] [-o DIR]
#
#     SECTION  display | depths | text | charts | vessels | alarms |
#              connections | advanced        (default: all)
#     -o DIR   write there instead of docs/docs/img
#
#   env overrides: LOOKOUT_APP LOOKOUT_CHART LOOKOUT_VIEW LOOKOUT_PLUGINS
#                  LOOKOUT_NMEA LOOKOUT_SETTLE LOOKOUT_CAP LOOKOUT_EXPECT
#                  LOOKOUT_KEEP=1 keeps the temp dir and the app logs
#
# A caution the Linux host does not have. There, a throwaway XDG_CONFIG_HOME
# keeps the frame on the ENGINE's defaults and out of the developer's saved
# state. Here there is no equivalent: CFPreferences resolves the domain from
# the login session, so HOME does not move it, and every instance this script
# starts reads and writes the SAME `org.beetlebug.lookout-marine` domain the
# developer's own app uses. Opening the settings window re-saves `mariner.v1`,
# so a run normalises the scheme, depth unit and contours to the engine's
# defaults — which is what the frames should show, but back up the domain
# first if the machine holds settings worth keeping:
#   defaults export org.beetlebug.lookout-marine ~/lookout-prefs.plist
#
# This script BUILDS NOTHING. Build the app yourself first:
#   xcodebuild -project macos/LookoutMarine.xcodeproj -scheme LookoutMarine \
#              -configuration Debug -derivedDataPath macos/build-mac
#
# Requires: swiftc, screencapture (both ship with macOS), python3 with Pillow.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
shot=${1:-all}
outdir=$repo/docs/docs/img
[ "${2:-}" = "-o" ] && outdir=$3

# ---- the canonical frame (keep in sync with docs/…/screenshots.md) ----------
APP=${LOOKOUT_APP:-$here/build-mac/Build/Products/Debug/LookoutMarine.app}
CHART=${LOOKOUT_CHART:-$HOME/Charts/ENC_ROOT}
VIEW=${LOOKOUT_VIEW:--76.4638,38.9745,14.5}   # Annapolis, the demo camera
PLUGINS=${LOOKOUT_PLUGINS:-$repo/zig-out/plugins}
NMEA=${LOOKOUT_NMEA:-127.0.0.1:10110}         # the replay server
SETTLE=${LOOKOUT_SETTLE:-9}                   # seconds after the window is up
CAP=${LOOKOUT_CAP:-1600}                      # served width; never UPscaled

# The settings window's own size, in POINTS. A frame that is not this size
# means the window was resized and the autosaved frame followed it. On a
# Retina display the capture is twice this in pixels.
EXPECT=${LOOKOUT_EXPECT:-720x592}

SECTIONS="display depths text charts vessels alarms connections plugins advanced"

# ---- preflight -------------------------------------------------------------
bin=$APP/Contents/MacOS/LookoutMarine
[ -x "$bin" ] || { echo "no app at $APP — build it first (see the header)" >&2; exit 1; }
[ -d "$CHART" ] || { echo "no chart library at $CHART" >&2; exit 1; }
[ -d "$PLUGINS" ] || { echo "no plugin directory at $PLUGINS" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "need swiftc (Xcode command line tools)" >&2; exit 1; }
python3 -c 'import PIL' 2>/dev/null || { echo "need python3 with Pillow, to write webp" >&2; exit 1; }

# The frame is a LIGHT one, beside linux-settings.webp. macOS gives the app the
# desktop's appearance and there is no per-process override, so say so and stop
# rather than commit a dark frame into a light set.
if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo Light)" = "Dark" ]; then
  echo "the desktop is in Dark mode; the docs frames are light. Switch and re-run." >&2
  exit 1
fi

# Stale binary? Say which files moved past it and carry on: rebuilding is the
# operator's call, and a frame from a known-old build still beats no frame.
stale=$(find "$repo/src" "$here/LookoutMarine" -type f \( -name '*.zig' -o -name '*.swift' \) \
        -newer "$bin" 2>/dev/null | sed "s|^$repo/||" | head -12)
if [ -n "$stale" ]; then
  echo "NOTE: $bin is older than these sources — the frames show the OLD build:"
  echo "$stale" | sed 's/^/        /'
  echo
fi

tmp=$(mktemp -d /tmp/lk-shot-macos-XXXXXX)
# LOOKOUT_KEEP=1 leaves the app logs behind: when a frame does not come out,
# the reason is in them and nowhere else.
cleanup () { [ "${LOOKOUT_KEEP:-0}" = 1 ] && echo "kept $tmp" || rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

# ---- the window picker -----------------------------------------------------
# `screencapture -l` wants a CGWindowID and macOS ships no tool that prints
# one. Owner PID *and* title, because the chart window and the settings window
# belong to the same process — and because another Lookout Marine (the
# developer's own) may be on screen, which this must never touch.
cat > "$tmp/lkwin.swift" <<'SWIFT'
import CoreGraphics
import Foundation

let wantPid = Int(CommandLine.arguments[1])!
let wantTitle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                      kCGNullWindowID) as? [[String: Any]] ?? []
for w in info {
    guard (w[kCGWindowOwnerPID as String] as? Int) == wantPid else { continue }
    guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
    let title = w[kCGWindowName as String] as? String ?? ""
    if !wantTitle.isEmpty && title != wantTitle { continue }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = b["Width"] as? Double ?? 0
    let height = b["Height"] as? Double ?? 0
    guard width > 300 && height > 300 else { continue }
    print("\(w[kCGWindowNumber as String] as? Int ?? 0) \(Int(width))x\(Int(height))")
}
SWIFT
swiftc -O -o "$tmp/lkwin" "$tmp/lkwin.swift"

# A settings window captured while it is NOT the front app comes out with grey
# traffic lights, a grey selection in the sidebar and grey toggles — a frame
# that reads as an abandoned window next to the others. Something does steal
# the front during a run (a previous instance letting go of it, most often),
# so take the front back and check that it was given.
cat > "$tmp/lkfront.swift" <<'SWIFT'
import AppKit

let pid = pid_t(CommandLine.arguments[1])!
guard let app = NSRunningApplication(processIdentifier: pid) else {
    print("gone"); exit(2)
}
app.activate(options: [.activateAllWindows])
usleep(800_000)
let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
print(front == pid ? "front" : "back")
exit(front == pid ? 0 : 1)
SWIFT
swiftc -O -o "$tmp/lkfront" "$tmp/lkfront.swift"

# ---- the plugin set the frames show ----------------------------------------
# org.beetlebug.* only. The SDK's language samples (org.example.windline.*)
# are not what a mariner has installed, and one of them TRAPS in lk_start —
# which today empties the settings schema of every OTHER plugin too, so the
# window loses Vessels, Alarms and Connections. Stage the shipped set instead
# of shooting around the bug.
mkdir -p "$tmp/plugins"
cp "$PLUGINS"/org.beetlebug.* "$tmp/plugins/" 2>/dev/null ||
  { echo "no org.beetlebug.* plugins in $PLUGINS" >&2; exit 1; }
echo "plugins staged: $(ls "$tmp"/plugins/*.wasm | wc -l | tr -d ' ') from $PLUGINS"

# ---- is the instrument feed free? ------------------------------------------
# The Connections frame is only worth taking when the seeded row goes green.
# The replay server serves ONE client, so an app already running holds it.
feed_ok () {
  python3 - "$NMEA" <<'PY'
import socket, sys
host, _, port = sys.argv[1].rpartition(":")
try:
    s = socket.create_connection((host, int(port)), 3)
    s.settimeout(4)
    sys.exit(0 if s.recv(1) else 1)
except Exception:
    sys.exit(1)
PY
}

# ---- one frame -------------------------------------------------------------
# The served frame: webp at quality 88, capped at CAP px wide. A window frame
# is never UPscaled to the cap — the protocol asks for sharp glyphs at 100%,
# and the settings window is narrower than the cap to begin with.
towebp () {
  python3 - "$1" "$2" "$CAP" <<'PY'
import sys
from PIL import Image
src, dst, cap = sys.argv[1], sys.argv[2], int(sys.argv[3])
im = Image.open(src).convert("RGBA")
if im.width > cap:
    im = im.resize((cap, round(im.height * cap / im.width)), Image.LANCZOS)
im.save(dst, "WEBP", quality=88, method=6)
print("wrote %s  %dx%d" % (dst, im.width, im.height))
PY
  rm -f "$1"
}

# Every instance of THIS binary that is running now. `open -n` does not report
# the process it starts, so the new one is whatever this set gains — and the
# set is also the guarantee that nothing else is ever signalled.
instances () { pgrep -f "^$bin$" | sort | tr '\n' ' '; }

capture () {
  section=$1
  out=$outdir/settings-$section.webp
  raw=$tmp/$section.png
  log=$tmp/$section.log

  # Launched through LaunchServices, not by exec'ing the binary: an app started
  # straight from the shell intermittently comes up with no session in front of
  # it, and then the SwiftUI scene never appears at all — no window, no log, a
  # process idling in its event loop for as long as you leave it.
  before=$(instances)
  open -n --env LOOKOUT_OPEN="$CHART" \
          --env LOOKOUT_VIEW="$VIEW" \
          --env LOOKOUT_PLUGINS="$tmp/plugins" \
          --env LOOKOUT_NMEA="$NMEA" \
          --env LOOKOUT_SHOW="settings:$section" \
          --stdout "$log" --stderr "$log" \
          "$APP" || { echo "$section: open failed" >&2; return 1; }

  pid=""
  i=0
  while [ $i -lt 40 ]; do
    fresh=""
    for p in $(instances); do
      case " $before " in *" $p "*) : ;; *) fresh="$fresh $p" ;; esac
    done
    set -- $fresh
    # Exactly one, or leave every one of them alone: two mean somebody else
    # launched the app in the same second, and guessing would kill their copy.
    [ $# -gt 1 ] && { echo "$section: $# new instances at once — not touching any" >&2
                      return 1; }
    [ $# -eq 1 ] && { pid=$1; break; }
    sleep 0.5
    i=$((i + 1))
  done
  [ -n "$pid" ] || { echo "$section: the app never started" >&2; return 1; }

  # Only ever this pid. Never `killall`, never by name: the developer's own
  # instance is usually on screen and must survive the run.
  quit () { kill -TERM "$pid" 2>/dev/null || true; }

  geom=""
  i=0
  while [ $i -lt 120 ]; do                      # up to 60s to map 7,000 cells
    geom=$("$tmp/lkwin" "$pid" "Mariner Settings" 2>/dev/null | head -1)
    [ -n "$geom" ] && break
    kill -0 "$pid" 2>/dev/null || { echo "$section: app exited early, log:" >&2
                                    tail -5 "$log" >&2; return 1; }
    sleep 0.5
    i=$((i + 1))
  done
  [ -n "$geom" ] || { echo "$section: no settings window after 60s" >&2; quit; return 1; }

  wid=${geom%% *}
  size=${geom#* }
  # The rows settle after the window maps: a connection goes green, a status
  # line arrives, the chart behind finishes its first draw.
  sleep "$SETTLE"

  i=0
  while [ $i -lt 3 ]; do
    "$tmp/lkfront" "$pid" >/dev/null 2>&1 && break
    i=$((i + 1))
  done
  [ $i -lt 3 ] || echo "  warning: could not bring the window to the front —" \
                       "the frame will look like a background window" >&2

  screencapture -o -x -l"$wid" "$raw"
  quit
  # Let it go before the next launch, so the pid diff stays unambiguous.
  i=0
  while kill -0 "$pid" 2>/dev/null && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done

  [ -f "$raw" ] || { echo "$section: screencapture wrote nothing" >&2; return 1; }
  towebp "$raw" "$out"
  [ "$size" = "$EXPECT" ] ||
    echo "  warning: window was ${size}px, expected $EXPECT (someone resized it;" \
         "the frame autosaves as 'mariner-settings')" >&2
  if grep -q "not loaded" "$log"; then
    echo "  warning: a plugin did not load —"
    grep "not loaded" "$log" | sed 's/^/            /'
  fi
}

# ---- go --------------------------------------------------------------------
mkdir -p "$outdir"
case " $SECTIONS all " in
  *" $shot "*) : ;;
  *) echo "usage: screenshots.sh [$(echo "$SECTIONS" | tr ' ' '|')|all] [-o DIR]" >&2
     exit 1 ;;
esac

want=$shot
[ "$shot" = all ] && want=$SECTIONS

case " $want " in
  *" connections "*)
    feed_ok || echo "NOTE: nothing readable at $NMEA — the Connections frame will" \
                    "show the seeded row RECONNECTING. The replay server takes one" \
                    "client at a time; quit the app that holds it, or point" \
                    "LOOKOUT_NMEA at a free one." ;;
esac

fail=0
for s in $want; do
  echo "== $s"
  # A launch does occasionally die before its window maps. One retry, then
  # say so: eight frames should not need a babysitter.
  capture "$s" || { echo "   retrying $s" >&2
                    capture "$s" || { echo "FAILED: $s" >&2; fail=1; } }
done
exit $fail
