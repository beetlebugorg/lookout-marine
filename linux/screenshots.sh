#!/bin/sh
# Capture the documentation screenshots for the Linux host.
#
# Runs the app in an OFF-SCREEN sway session, so a shot is reproducible and
# never picks up the live desktop (no compositor rounding, shadow or wallpaper
# bleed), then grabs the output with grim. See docs/screenshots.md for the
# canonical chart / camera / size every host is expected to match.
#
#   usage: screenshots.sh [day|settings|all] [-o DIR]
#
# Requires: sway, grim (and a built ./build/lookout-marine).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
app=$here/build/lookout-marine
outdir=$here/../docs
shot=${1:-all}
[ "${2:-}" = "-o" ] && outdir=$3

# ---- the canonical shot spec (keep in sync with docs/screenshots.md) --------
CHART=${LOOKOUT_CHART:-$HOME/.cache/chartplotter/NOAA}
VIEW=${LOOKOUT_VIEW:--76.482,38.976,13.7}   # Annapolis Harbor + the Naval Academy
LOGICAL=${LOOKOUT_SIZE:-1400x900}           # logical window size, in points
SCALE=${LOOKOUT_SCALE:-2}                   # HiDPI factor -> 2800x1800 px

[ -x "$app" ] || { echo "build it first: ninja -C $here/build" >&2; exit 1; }
command -v sway >/dev/null || { echo "need sway (headless compositor)" >&2; exit 1; }
command -v grim >/dev/null || { echo "need grim" >&2; exit 1; }

lw=${LOGICAL%x*}
lh=${LOGICAL#*x}

# One shot: boot a headless sway, run the app in it, grab, exit.
#   $1 out.png   $2 window action to activate first (may be empty)
capture () {
  out=$1
  action=${2:-}
  log=$(mktemp /tmp/lk-shot-log-XXXXXX)
  cfg=$(mktemp /tmp/lk-shot-cfg-XXXXXX)
  inner=$(mktemp /tmp/lk-shot-run-XXXXXX.sh)

  cat > "$inner" <<INNER
#!/bin/sh
set -u
LOOKOUT_OPEN="$CHART" LOOKOUT_VIEW="$VIEW" "$app" >>"$log" 2>&1 &
pid=\$!
i=0; while [ \$i -lt 90 ]; do            # wait for a tessellated frame
  grep -q 'verts=[1-9][0-9][0-9]' "$log" 2>/dev/null && break
  sleep 0.5; i=\$((i+1))
done
sleep 5                                   # let prefetch + labels settle
if [ -n "$action" ]; then
  # GtkApplicationWindow exports win.* actions on the session bus.
  gdbus call --session -d org.beetlebug.LookoutMarine \\
    -o /org/beetlebug/LookoutMarine/window/1 \\
    -m org.gtk.Actions.Activate "$action" '@av []' '@a{sv} {}' >>"$log" 2>&1 || true
  sleep 4
fi
grim -o HEADLESS-1 "$out" >>"$log" 2>&1
kill \$pid 2>/dev/null || true
sleep 0.5
swaymsg exit >/dev/null 2>&1 || true
INNER
  chmod +x "$inner"

  # The output must be logical x scale physical px, or the app's minimum size
  # overflows it and the chrome is clipped out of frame.
  cat > "$cfg" <<CFG
output HEADLESS-1 resolution $((lw * SCALE))x$((lh * SCALE)) scale $SCALE
default_border none
default_floating_border none
for_window [title="Mariner Settings"] floating enable, move position center
exec $inner
CFG

  WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 sway -c "$cfg" >/dev/null 2>&1 || true
  rm -f "$cfg" "$inner"
  if [ -f "$out" ]; then
    echo "wrote $out"
    rm -f "$log"
  else
    echo "FAILED: $out — app log at $log" >&2
    exit 1
  fi
}

mkdir -p "$outdir"
case "$shot" in
  day)      capture "$outdir/linux-day.png" "" ;;
  settings) capture "$outdir/linux-settings.png" settings ;;
  all)      capture "$outdir/linux-day.png" ""
            capture "$outdir/linux-settings.png" settings ;;
  *) echo "usage: screenshots.sh [day|settings|all] [-o DIR]" >&2; exit 1 ;;
esac
