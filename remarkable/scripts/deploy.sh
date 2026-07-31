#!/usr/bin/env bash
# Copy the viewer onto a reMarkable over SSH. Assumes developer mode / SSH is
# enabled and the tablet is reachable (USB default: root@10.11.99.1).
#
# Two forms:
#   scripts/deploy.sh dist/rm2 charts/tiles/US5MD1MC.pmtiles           # a bundle dir
#   scripts/deploy.sh build-rm2/lookout-marine charts/tiles/CELL.pmtiles # a bare binary
#
# Third arg overrides the host (default root@10.11.99.1). Charts sync with rsync
# when BOTH ends have it (incremental — only changed files transfer); otherwise
# it falls back to a tar-over-ssh stream (busybox / old-macOS safe). The binary +
# launcher go over scp/ssh. Tip: `ssh-copy-id root@10.11.99.1` once to skip
# password prompts.
set -euo pipefail

SRC="${1:?path to a dist/<device> bundle dir OR a lookout-marine binary}"
CHART="${2:?path to a baked <CELL>.pmtiles, or a directory of them}"
HOST="${3:-root@10.11.99.1}"
DEST="/home/root/lookout-marine"

[ -e "$SRC" ]   || { echo "not found: $SRC" >&2; exit 1; }
[ -e "$CHART" ] || { echo "chart not found: $CHART" >&2; exit 1; }

# Show a live transfer meter when `pv` is available (brew/apt install pv);
# otherwise stream straight through. Portable (no size probe needed).
_pv_warned=0
progress() {
    if command -v pv >/dev/null 2>&1; then
        pv -N "$1"
    else
        [ "$_pv_warned" = 0 ] && { echo "   (install 'pv' for a progress bar)" >&2; _pv_warned=1; }
        cat
    fi
}

echo ">> deploying to $HOST:$DEST"

if [ -d "$SRC" ]; then
    # Self-contained bundle: stream the whole tree as a tar over one ssh.
    echo ">> sending bundle ($(du -sh "$SRC" | cut -f1)) ..."
    tar -C "$SRC" -cf - . | progress "bundle" | ssh "$HOST" "mkdir -p '$DEST/charts' && tar -C '$DEST' -xf -"
else
    # Bare binary + the on-device launcher. Copy the binary to a temp name then
    # rename it into place: a still-running lookout-marine holds the executable
    # (ETXTBSY / "dest open Failure"), but rename() just repoints the name while
    # the old inode keeps running — so redeploy-over-running works.
    ssh "$HOST" "mkdir -p '$DEST/charts'"
    scp "$SRC" "$HOST:$DEST/lookout-marine.new"
    ssh "$HOST" "mv -f '$DEST/lookout-marine.new' '$DEST/lookout-marine'"
    scp "$(dirname "$0")/../device/launch.sh" "$HOST:$DEST/launch.sh"
fi

# Ship the monochrome "ink" colour profile next to the binary (main.cpp points
# TILE57_COLORPROFILE at it via applicationDirPath). Best-effort: if it is absent
# the engine just falls back to its embedded colours.
INK="$(dirname "$0")/../assets/colorProfile.ink.xml"
if [ -f "$INK" ]; then
    echo ">> sending ink colour profile ..."
    scp "$INK" "$HOST:$DEST/colorProfile.ink.xml"
fi

echo ">> sending chart(s) $(basename "$CHART") ..."
ssh "$HOST" "mkdir -p '$DEST/charts'"
[ -d "$CHART" ] && RUN_ARG="$DEST/charts" || RUN_ARG="$DEST/charts/$(basename "$CHART")"

if command -v rsync >/dev/null 2>&1 && ssh "$HOST" 'command -v rsync >/dev/null 2>&1'; then
    # rsync: incremental — only changed/new chart files cross the wire, so
    # re-deploying an unchanged (or lightly-changed) chart set is near-instant.
    # A trailing slash on a directory copies its CONTENTS into charts/.
    # --exclude '._*': drop macOS AppleDouble sidecars (not real archives).
    if [ -d "$CHART" ]; then
        rsync -a --progress --exclude='._*' "$CHART"/ "$HOST:$DEST/charts/"
    else
        rsync -a --progress "$CHART" "$HOST:$DEST/charts/"
    fi
elif [ -d "$CHART" ]; then
    # Fallback (no rsync on a busybox device / old host): full tar-over-ssh.
    echo "   (no rsync on both ends — full copy; install rsync for incremental)"
    tar --exclude='._*' -C "$CHART" -cf - . | progress "charts" | ssh "$HOST" "tar -C '$DEST/charts' -xf -"
else
    scp "$CHART" "$HOST:$DEST/charts/"
fi
ssh "$HOST" "chmod +x '$DEST/lookout-marine' '$DEST/launch.sh'"

echo ">> done. On the tablet:  $DEST/launch.sh $RUN_ARG"
