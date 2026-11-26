#!/bin/sh
# otgcut.sh - offline logic test (v1.9.1).
#
# Runs the real daemon against a fake sysfs tree for a few seconds per case.
# No tablet, no root, no real power nodes.
#
#   sh tests/otgcut_test.sh
#
# What is asserted:
#   1. OTG_CUT=0 exits immediately without touching anything.
#   2. VBUS absent + PD partner present  -> otg/online is forced to 0.
#   3. VBUS absent + plain OTG partner   -> otg/online is left at 1 (a USB
#      stick session must never be cut).
#   4. A single write is not enough: the fake kernel re-arms otg=1, and the
#      daemon must cut it again (that repetition is the whole point).
#   5. VBUS returning stops the cutting, and the heartbeat is written.
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)/tab-dp-watchdog/otgcut.sh
[ -f "$SRC" ] || { echo "!! missing $SRC"; exit 1; }

T=/tmp/otgcut_test
FAIL=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }

setup() {
    rm -rf "$T"
    mkdir -p "$T/sys/class/power_supply/usb" \
             "$T/sys/class/power_supply/otg" \
             "$T/sys/class/power_supply/battery" \
             "$T/sys/class/typec/port0-partner" \
             "$T/sys/class/typec/port0" \
             "$T/sys/class/drm/card0-DP-1" \
             "$T/tpdp"
    echo 1      > "$T/sys/class/power_supply/usb/online"
    echo 1      > "$T/sys/class/power_supply/otg/online"
    echo -1609  > "$T/sys/class/power_supply/battery/current_now"
    echo yes    > "$T/sys/class/typec/port0-partner/supports_usb_power_delivery"
    echo source > "$T/sys/class/typec/port0/power_role"
    echo disconnected > "$T/sys/class/drm/card0-DP-1/status"
    echo "test-boot-id" > "$T/boot_id"
    [ -f "$T/tpdp/config" ] || : > "$T/tpdp/config"
}

# path-rewrite a copy of the real daemon so it only ever sees the fake tree.
# The counts are lowered for the test only: on a PC a `sleep 0.2` actually
# takes ~0.3s, so the shipping values (20 polls to release, 25 to heartbeat)
# would need ~7s per case. The logic under test is the same.
stage() {
    sed -e "s#/proc/sys/kernel/random/boot_id#$T/boot_id#g" \
        -e "s#/sys/#$T/sys/#g" \
        -e "s#^LOGDIR=/data/adb/tpdp#LOGDIR=$T/tpdp#" \
        -e "s#^CUT_RELEASE=20#CUT_RELEASE=4#" \
        -e "s#^CUT_STRIKES=3#CUT_STRIKES=2#" \
        -e "s#hb\" -ge 25#hb\" -ge 3#" \
        "$SRC" > "$T/otgcut.sh"
    chmod 0755 "$T/otgcut.sh"
}

run_for() {   # run_for <seconds>
    if command -v timeout >/dev/null 2>&1; then
        timeout "$1" sh "$T/otgcut.sh" >/dev/null 2>&1
    else
        sh "$T/otgcut.sh" >/dev/null 2>&1 &
        _p=$!
        sleep "$1"
        kill "$_p" 2>/dev/null
        wait "$_p" 2>/dev/null
    fi
    return 0
}

otg() { cat "$T/sys/class/power_supply/otg/online" 2>/dev/null; }

echo "== case 1: OTG_CUT=0 exits without acting =="
setup
echo "OTG_CUT=0" > "$T/tpdp/config"
stage
echo 0 > "$T/sys/class/power_supply/usb/online"
run_for 2
[ "$(otg)" = "1" ] && pass "otg untouched when disabled" || fail "otg=$(otg) (expected 1)"
grep -q 'disabled by config' "$T/tpdp/log" 2>/dev/null && pass "logged the opt-out" || fail "no opt-out log line"

echo "== case 2: VBUS absent + PD partner -> cut applied =="
setup
stage
echo 0 > "$T/sys/class/power_supply/usb/online"
run_for 3
[ "$(otg)" = "0" ] && pass "otg forced to 0" || fail "otg=$(otg) (expected 0)"
grep -q 'cutting the tablet 5V boost' "$T/tpdp/log" 2>/dev/null && pass "armed and logged" || fail "no arm log line"
grep -q 'otg boost cut' "$T/tpdp/log" 2>/dev/null && pass "recorded the cut" || fail "no cut log line"

echo "== case 3: VBUS absent + plain OTG partner -> left alone =="
setup
echo no > "$T/sys/class/typec/port0-partner/supports_usb_power_delivery"
stage
echo 0 > "$T/sys/class/power_supply/usb/online"
run_for 3
[ "$(otg)" = "1" ] && pass "otg untouched for a non-PD partner" || fail "otg=$(otg) (expected 1)"
grep -q 'plain OTG session' "$T/tpdp/log" 2>/dev/null && pass "logged the skip reason" || fail "no skip log line"

echo "== case 4: kernel re-arms otg -> daemon cuts again =="
setup
stage
echo 0 > "$T/sys/class/power_supply/usb/online"
# simulate the charger driver putting the boost back 1s after each write
( i=0; while [ $i -lt 6 ]; do sleep 1; echo 1 > "$T/sys/class/power_supply/otg/online"; i=$((i+1)); done ) &
_kick=$!
run_for 4
kill "$_kick" 2>/dev/null; wait "$_kick" 2>/dev/null
n=$(grep -c 'otg boost cut' "$T/tpdp/log" 2>/dev/null || echo 0)
[ "$n" -ge 2 ] && pass "cut repeatedly ($n times) while VBUS stayed absent" \
                || fail "only $n cut(s), expected >= 2"

echo "== case 5: VBUS returns -> cutting stops, heartbeat written =="
setup
stage
echo 0 > "$T/sys/class/power_supply/usb/online"
# process start on Windows costs ~0.5s, so give the daemon time to actually
# reach the armed state before the fake PD comes back
( sleep 3; echo 1 > "$T/sys/class/power_supply/usb/online" ) &
_up=$!
run_for 12
kill "$_up" 2>/dev/null; wait "$_up" 2>/dev/null
grep -q 'cut released' "$T/tpdp/log" 2>/dev/null && pass "released when VBUS returned" || { fail "never released"; sed 's/^/       | /' "$T/tpdp/log" 2>/dev/null; }
[ -f "$T/tpdp/hb.otg" ] && pass "heartbeat present" || fail "no heartbeat file"
echo 0 > "$T/sys/class/power_supply/usb/online"
: > "$T/tpdp/log"
stage
run_for 2
[ "$(otg)" = "0" ] && pass "re-arms after a release cycle" || fail "otg=$(otg) after re-pull"

echo
if [ "$FAIL" = "0" ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAIL FAILURE(S)"
exit 1
