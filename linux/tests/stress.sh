#!/bin/sh
# Put the chart renderer through sustained pan and zoom, and say whether it
# survived.
#
# This is NOT part of `meson test`: it needs a GPU and a real chart, and a build
# runner has neither. It is the test for the one failure the widget suites
# cannot reach — the renderer seizing under a long pan — because the shell only
# forwards deltas and everything that can seize lives below it.
#
# The app drives itself through LOOKOUT_STRESS (ui/dev-hooks.c). Every operation
# goes through the main loop, so a renderer that stops answering stops the run
# with it and the completion line never arrives. That is the verdict.
#
#   usage: stress.sh <chart-path> [ops] [interval_ms] [fullscreen_every]
#
# $LK_SIZE and $LK_SCALE set the output the run draws into (default 1600x1000
# at 1). A fractional scale supersamples, which is what a HiDPI desktop asks of
# the renderer, so raise them to put real pressure on it.
#
# $LK_SESSION=1 runs in the DESKTOP'S OWN compositor instead of a headless sway.
# A seizure can belong to the compositor and the driver as much as to the app,
# so a run that passes headless and fails here has told you where to look. It
# opens a real window on the desktop and drives it, so expect the screen to move.
#
# $LK_VALIDATE=1 turns the Khronos validation layer on, with synchronization
# validation, so a bad draw or an unsynchronised access is named rather than
# guessed at. It is slow: use fewer ops.
#
# Passes when the run completes and the log carries no Vulkan error.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
app=$here/../build/lookout-marine
chart=${1:?usage: stress.sh <chart-path> [ops] [interval_ms] [fullscreen_every]}
ops=${2:-3000}
interval=${3:-4}
fs=${4:-0}

[ -x "$app" ] || { echo "build it first: ninja -C $here/../build" >&2; exit 1; }
[ -n "${LK_SESSION:-}" ] || command -v sway >/dev/null || {
  echo "need sway (headless compositor), or LK_SESSION=1 to use the desktop's" >&2
  exit 1
}

log=$(mktemp /tmp/lk-stress-XXXXXX.log)
cfg=$(mktemp /tmp/lk-stress-cfg-XXXXXX)
inner=$(mktemp /tmp/lk-stress-run-XXXXXX.sh)
conf=$(mktemp -d /tmp/lk-stress-conf-XXXXXX)

# The run has to end even if the app seizes, or this script hangs with it. The
# budget is the run's own time plus a minute to open the chart.
budget=$(( ops * interval / 1000 + 90 ))

cat > "$inner" <<INNER
#!/bin/sh
export XDG_CONFIG_HOME="$conf" XDG_DATA_HOME="$conf/data" GTK_THEME=Adwaita
if [ -n "${LK_VALIDATE:-}" ]; then   # names the offending call, at a heavy cost
  export VK_LOADER_LAYERS_ENABLE=VK_LAYER_KHRONOS_validation
  export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
  export VK_LAYER_VALIDATE_SYNC=1
fi
export LOOKOUT_OPEN="$chart"
export LOOKOUT_STRESS="$ops,$interval,$fs@6"
"$app" >>"$log" 2>&1 &
pid=\$!
i=0
while [ \$i -lt $budget ]; do
  grep -q 'stress: completed' "$log" 2>/dev/null && break
  kill -0 \$pid 2>/dev/null || break        # it died; stop waiting
  sleep 1
  i=\$((i + 1))
done
kill \$pid 2>/dev/null || true
sleep 1
swaymsg exit >/dev/null 2>&1 || true
INNER
chmod +x "$inner"

cat > "$cfg" <<CFG
output HEADLESS-1 resolution ${LK_SIZE:-1600x1000} scale ${LK_SCALE:-1}
default_border none
exec $inner
CFG

if [ -n "${LK_SESSION:-}" ]; then
  "$inner"
else
  WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 sway -c "$cfg" >/dev/null 2>&1 || true
fi
rm -f "$cfg" "$inner"; rm -rf "$conf"

status=0
if grep -q 'stress: completed' "$log"; then
  echo "PASS  $(grep 'stress: completed' "$log")"
else
  echo "FAIL  the run did not complete: the renderer stopped answering" >&2
  echo "      last progress: $(grep 'stress:' "$log" | tail -1)" >&2
  status=1
fi

if grep -q 'vk error' "$log"; then
  echo "FAIL  $(grep -c 'vk error' "$log") Vulkan error(s):" >&2
  grep 'vk error' "$log" | sort | uniq -c | sed 's/^/      /' >&2
  status=1
fi

echo "log: $log"
exit $status
