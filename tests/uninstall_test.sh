#!/bin/sh
# v1.6.0 uninstall.sh - offline behaviour test.
#
# The real uninstall.sh is path-rewritten into a sandbox so it can be executed
# on a PC: every /data/adb/tpdp and /sys/... path is redirected to a temp tree.
# Nothing outside the temp dir is touched and the pkill patterns match nothing.
#
#   sh tests/uninstall_test.sh
#
# Verifies the three holes fixed in v1.6.0:
#   - HPD is only forced high with real external VBUS (no panic path on removal)
#   - port_type is rewritten to dual only when pinned to sink
#   - a stale/reused web.pid is not blindly killed
# and that the module data directory is removed.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../tab-dp-watchdog/uninstall.sh"
[ -f "$SRC" ] || { echo "FATAL: $SRC not found"; exit 1; }

TMP="/tmp/uninstall_test.$$"
mkdir -p "$TMP/sys" "$TMP/adb/tpdp"
HPD="$TMP/sys/hpd"
PCLK="$TMP/sys/pclk"
PORT="$TMP/sys/port_type"
VBUS="$TMP/sys/usb_online"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# path-rewritten copy of the shipped script
sed -e "s#/data/adb/tpdp#$TMP/adb/tpdp#g" \
    -e "s#/sys/kernel/debug/drm_dp/hpd#$HPD#g" \
    -e "s#/sys/kernel/debug/drm_dp/max_pclk_khz#$PCLK#g" \
    -e "s#/sys/class/typec/port0/port_type#$PORT#g" \
    -e "s#/sys/class/power_supply/usb/online#$VBUS#g" \
    "$SRC" > "$TMP/un.sh"

setup() {  # setup <usb_online|MISSING> <port_type string> [web.pid content]
    rm -rf "$TMP/adb/tpdp"; mkdir -p "$TMP/adb/tpdp"
    printf 'WAKE_GATE=1\n' > "$TMP/adb/tpdp/config"
    printf '300000\n'      > "$TMP/adb/tpdp/pclk_org"
    printf 'off\n'         > "$TMP/adb/tpdp/video.state"
    : > "$TMP/adb/tpdp/video_off"
    [ -n "${3:-}" ] && printf '%s\n' "$3" > "$TMP/adb/tpdp/web.pid"
    rm -f "$VBUS"
    case "$1" in MISSING) : ;; *) printf '%s\n' "$1" > "$VBUS" ;; esac
    printf '%s\n' "$2" > "$PORT"
    printf '0\n' > "$HPD"
    printf '675000\n' > "$PCLK"
}

echo "=== v1.6.0 uninstall.sh: offline behaviour test ==="
echo "source: $SRC"
echo

# ---- T1: external power present -> normal restoration --------------------
echo "T1  usb/online=1, port_type=[dual] -> HPD restored, tpdp removed"
setup 1 '[dual] source sink'
sh "$TMP/un.sh" > "$TMP/out1.txt" 2>/dev/null; rc=$?
check "script exits 0"                       '[ "$rc" -eq 0 ]'
check "HPD forced high"                      '[ "$(cat "$HPD")" = "1" ]'
check "tpdp removed"                         '[ ! -d "$TMP/adb/tpdp" ]'
check "pclk restored from saved pclk_org"    '[ "$(cat "$PCLK")" = "300000" ]'
check "healthy port_type left alone"         '[ "$(cat "$PORT")" = "[dual] source sink" ]'
check "reports cleanup complete"             'grep -q "cleanup complete" "$TMP/out1.txt"'
echo

# ---- T2: no external power -> MUST NOT force HPD high -------------------
echo "T2  usb/online=0 (tablet sourcing) -> HPD stays low (panic path avoided)"
setup 0 '[dual] source sink'
sh "$TMP/un.sh" > "$TMP/out2.txt" 2>/dev/null; rc=$?
check "script exits 0"                       '[ "$rc" -eq 0 ]'
check "HPD NOT forced high"                  '[ "$(cat "$HPD")" != "1" ]'
check "explains why it stayed off"           'grep -q "no external VBUS" "$TMP/out2.txt"'
check "tpdp still removed"                   '[ ! -d "$TMP/adb/tpdp" ]'
echo

# ---- T3: node missing (recovery context) -> allow -----------------------
echo "T3  usb/online node missing -> restore allowed (do not strand the user)"
setup MISSING '[dual] source sink'
sh "$TMP/un.sh" > "$TMP/out3.txt" 2>/dev/null
check "HPD forced high"                      '[ "$(cat "$HPD")" = "1" ]'
echo

# ---- T4: sink-only port left by the removed governor --------------------
echo "T4  port_type=[sink] only -> restored to dual"
setup 1 '[sink]'
sh "$TMP/un.sh" > "$TMP/out4.txt" 2>/dev/null
check "port_type rewritten to dual"          '[ "$(cat "$PORT")" = "dual" ]'
check "reported in output"                   'grep -q "port_type restored" "$TMP/out4.txt"'
echo

# ---- T5: stale web.pid must not kill an unrelated process ---------------
echo "T5  web.pid pointing at a live non-httpd process -> not killed"
# $$ of this test shell is a live process whose cmdline has no 'httpd'
setup 1 '[dual] source sink' "$$"
sh "$TMP/un.sh" > "$TMP/out5.txt" 2>/dev/null
check "test shell survived"                  'kill -0 $$ 2>/dev/null'
check "no false 'stopped web UI' claim"      '! grep -q "stopped web UI" "$TMP/out5.txt"'
echo

echo "=== result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
