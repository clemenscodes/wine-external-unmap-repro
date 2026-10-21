#!/usr/bin/env bash
# Runs repro.exe under Wine on a private Xvfb display with openbox as the
# window manager, changes the window's visibility from another X client, and
# logs both sides: what the app's Win32 side believes (app.log) and what the X
# server shows (x11.log). Wine's own view of the state tracking goes to
# wine.log.
#
#   ./run-repro.sh unmap     external XUnmapWindow, later XMapWindow (the bug)
#   ./run-repro.sh iconify   external iconify, later activate (the control)
#
# Timeline (seconds from app start): 3 external hide, 6 the app calls
# SetWindowPos itself, 8 external show, 12 the app exits.
set -euo pipefail

mode="${1:-unmap}"
case "$mode" in
  unmap | iconify) ;;
  *)
    echo "usage: $0 unmap|iconify" >&2
    exit 2
    ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/out/$mode"
rm -rf "$out"
mkdir -p "$out"

export WINEPREFIX="$here/.wineprefix"
export WINEDEBUG="${WINEDEBUG:-warn+event,warn+x11drv}"
export WINEDLLOVERRIDES="mscoree,mshtml="

make -C "$here" --no-print-directory repro.exe

display_number=99
export DISPLAY=":$display_number"
Xvfb "$DISPLAY" -screen 0 1920x1080x24 -nolisten tcp >"$out/xvfb.log" 2>&1 &
xvfb_pid=$!
openbox_pid=""
cleanup() {
  wineserver -k 2>/dev/null || true
  [ -n "$openbox_pid" ] && kill "$openbox_pid" 2>/dev/null || true
  kill "$xvfb_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 50); do
  xdpyinfo >/dev/null 2>&1 && break
  sleep 0.1
done
openbox --sm-disable >"$out/openbox.log" 2>&1 &
openbox_pid=$!
sleep 1

if [ ! -f "$WINEPREFIX/system.reg" ]; then
  echo "creating the Wine prefix (first run only)..."
  wineboot --init >/dev/null 2>&1
  wineserver -w
fi

start=$(date +%s.%N)
stamp() { printf '[%5d ms]' "$(echo "($(date +%s.%N) - $start) * 1000 / 1" | bc)"; }

wine "$here/repro.exe" >"$out/app.log" 2>"$out/wine.log" &
app_pid=$!

window=""
for _ in $(seq 100); do
  window=$(xdotool search --name '^Repro Window$' 2>/dev/null | head -1 || true)
  [ -n "$window" ] && break
  sleep 0.1
done
if [ -z "$window" ]; then
  echo "repro window never appeared, see $out/wine.log" >&2
  exit 1
fi
# Restart the host clock at the moment the window shows up, so both logs count
# from (roughly, within the 100 ms poll) the same instant: the app's own clock
# starts right before it shows the window.
start=$(date +%s.%N)

x_state() {
  local info map size wm_state
  info=$(xwininfo -id "$window" 2>/dev/null)
  map=$(echo "$info" | sed -n 's/.*Map State: //p')
  size=$(echo "$info" | sed -n 's/.*-geometry //p')
  wm_state=$(xprop -id "$window" WM_STATE 2>/dev/null | sed -n 's/.*window state: //p')
  echo "$(stamp) x11 map=${map:-?} WM_STATE=${wm_state:-none} geometry=${size:-?}"
}

: >"$out/x11.log"
(
  while kill -0 "$app_pid" 2>/dev/null; do
    x_state
    sleep 0.25
  done
) >>"$out/x11.log" &
sampler_pid=$!

sleep 3
if [ "$mode" = unmap ]; then
  echo "$(stamp) host xdotool windowunmap" >>"$out/x11.log"
  xdotool windowunmap "$window"
else
  echo "$(stamp) host xdotool windowminimize" >>"$out/x11.log"
  xdotool windowminimize "$window"
fi

sleep 5
if [ "$mode" = unmap ]; then
  echo "$(stamp) host xdotool windowmap" >>"$out/x11.log"
  xdotool windowmap "$window"
else
  echo "$(stamp) host xdotool windowactivate" >>"$out/x11.log"
  xdotool windowactivate "$window"
fi

wait "$app_pid" || true
wait "$sampler_pid" 2>/dev/null || true

echo "== $mode: app (Win32 side) and x11 (host side), merged by time (+-100 ms)"
# Samples are printed only when they change; events always.
LC_ALL=C sort -t']' -k1,1 -s "$out/app.log" "$out/x11.log" |
  awk '{
    body = substr($0, index($0, "]") + 2)
    kind = substr(body, 1, index(body, " ") - 1)
    if (kind == "state" || kind == "x11") {
      if (last[kind] == body) next
      last[kind] = body
    }
    print "  " $0
  }'
if [ "$mode" = unmap ]; then
  echo "== verdict"
  failed=0
  check() {
    if [ "$2" = yes ]; then
      echo "  PASS $1"
    else
      echo "  FAIL $1"
      failed=1
    fi
  }
  grep -qE "WM_SHOWWINDOW show=0|HIDE" "$out/app.log" && hidden=yes || hidden=no
  check "the app learns about the external unmap" "$hidden"
  remapped=$(sed -n '/host xdotool windowunmap/,/host xdotool windowmap/p' "$out/x11.log" |
    sed '1,/IsUnMapped/d' | grep -c "IsViewable" || true)
  [ "$remapped" = 0 ] && stayed=yes || stayed=no
  check "the window stays unmapped across the app's own SetWindowPos" "$stayed"
  # SetWindowPos(SWP_SHOWWINDOW) sends no WM_SHOWWINDOW, so count the SHOW flag:
  # once for the app's own initial show, once more for the external map.
  [ "$(grep -c "WM_WINDOWPOSCHANGED.* SHOW" "$out/app.log")" -ge 2 ] && shown=yes || shown=no
  check "the app learns about the external map" "$shown"
fi
echo "== wine state tracking (warnings)"
grep -E "unexpected|mismatch|Ignoring|reparenting|not yet hidden" "$out/wine.log" | sed 's/^/  /' || echo "  (none)"
echo "full logs: $out"
