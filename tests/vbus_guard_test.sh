#!/bin/sh
# v1.6.0 external VBUS guard - offline logic test.
#
# Runs the real guard code from tab-dp-watchdog/screenvid.sh against a fake
# sysfs tree, so the four decision paths can be verified on a PC (no tablet,
# no root, no debugfs). The functions are extracted verbatim from the shipped
# script - if they drift, this test fails.
#
#   sh tests/vbus_guard_test.sh
#
# Exit 0 = all cases pass.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../tab-dp-watchdog/screenvid.sh"
[ -f "$SRC" ] || { echo "FATAL: $SRC not found"; exit 1; }

# NOTE: a fixed /tmp path is used on purpose - mktemp returns a Windows-style
# path ("C:\...\Temp/xxx") under Git Bash, which some rm wrappers refuse.
TMP="/tmp/vbus_guard_test.$$"
mkdir -p "$TMP/sys/power_supply/usb" "$TMP/sys/power_supply/otg" \
         "$TMP/sys/power_supply/battery" "$TMP/sys/typec/port0" "$TMP/state"

# fake sysfs nodes used by vbus_evidence()
DATAROLE_FILE="$TMP/sys/typec/port0/data_role"
printf 'dual\n'        > "$TMP/sys/typec/port0/port_type"
printf '[sink] source\n' > "$TMP/sys/typec/port0/power_role"
printf '0\n'           > "$TMP/sys/power_supply/otg/online"
printf '%s\n' 300      > "$TMP/sys/power_supply/battery/current_now"

# ---- extract the guard + restore_video from the shipped script ------------
extract() {  # extract <funcname>
    awk -v fn="$1" '
        $0 ~ ("^" fn "\\(\\) \\{") { inside = 1 }
        inside { print }
        inside && /^}$/ { exit }
    ' "$SRC"
}
HAS_GUARD_EXT=$(extract ext_vbus_ok)
HAS_GUARD_EV=$(extract vbus_evidence)
HAS_RESTORE=$(extract restore_video)
for v in HAS_GUARD_EXT HAS_GUARD_EV HAS_RESTORE; do
    eval "body=\$$v"
    [ -n "$body" ] || { echo "FATAL: could not extract $v - did screenvid.sh change shape?"; exit 1; }
done

# ---- harness --------------------------------------------------------------
EXT_VBUS="$TMP/sys/power_supply/usb/online"
OTG_ONLINE="$TMP/sys/power_supply/otg/online"
POWER_ROLE="$TMP/sys/typec/port0/power_role"
BAT_CUR="$TMP/sys/power_supply/battery/current_now"
TYPEC_PORT="$TMP/sys/typec/port0"
HPD_NODE="$TMP/state/hpd"
STATE_FILE="$TMP/state/video.state"
MARKER="$TMP/state/video_off"
STUB_LOG="$TMP/state/log"
STUB_LINK=1
VBUS_GUARD=1
vbus_notice=0
vbus_wait=0
: > "$HPD_NODE"; : > "$STUB_LOG"

log() { echo "$*" >> "$STUB_LOG"; }
link_present() { [ "$STUB_LINK" = "1" ]; }
ensure_hpd() { [ -e "$HPD_NODE" ]; }
partner_present() { [ "$STUB_LINK" = "1" ]; }
cable_present() { [ "$STUB_LINK" = "1" ]; }
refresh_actual() {
    if [ "$(cat "$HPD_NODE" 2>/dev/null)" = "1" ]; then
        ACT_ST=connected; ACT_EN=enabled
    else
        ACT_ST=disconnected; ACT_EN=disabled
    fi
}
video_actual_on()  { [ "$ACT_ST" = "connected" ] && [ "$ACT_EN" = "enabled" ]; }
video_actual_off() { [ "$ACT_ST" = "disconnected" ] && [ "$ACT_EN" = "disabled" ]; }
# restore_video's HPD loop sleeps 2s per attempt - collapse it for the test
sleep() { :; }

eval "$HAS_GUARD_EXT"
eval "$HAS_GUARD_EV"
eval "$HAS_RESTORE"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

setup() {  # setup <usb_online value|MISSING> [guard]
    rm -f "$EXT_VBUS"
    case "$1" in
        MISSING) : ;;
        *) printf '%s\n' "$1" > "$EXT_VBUS" ;;
    esac
    VBUS_GUARD=${2:-1}
    STUB_LINK=1
    vbus_notice=0
    vbus_wait=0
    echo 0 > "$HPD_NODE"
    rm -f "$MARKER" "$STATE_FILE"
    : > "$STUB_LOG"
}

echo "=== v1.6.0 VBUS guard: offline logic test ==="
echo "source: $SRC"
echo

# ---- T1: external power present -> normal restore -------------------------
echo "T1  usb/online=1 (screen PD connected) -> restore allowed"
setup 1
restore_video; rc=$?
check "restore_video succeeds (rc=0)"    '[ "$rc" -eq 0 ]'
check "HPD was forced high"              '[ "$(cat "$HPD_NODE")" = "1" ]'
check "marker cleared"                   '[ ! -f "$MARKER" ]'
check "state=on"                         '[ "$(cat "$STATE_FILE")" = "on" ]'
check "vbus_wait cleared"                '[ "$vbus_wait" = "0" ]'
echo

# ---- T2: no external power -> restore MUST be suppressed ------------------
echo "T2  usb/online=0 (screen PD pulled, tablet sourcing) -> restore blocked"
setup 0
restore_video; rc=$?
check "restore_video returns 0 (handled)" '[ "$rc" -eq 0 ]'
check "HPD stayed LOW (never 1)"          '[ "$(cat "$HPD_NODE")" != "1" ]'
check "marker set (suppresses service.sh)" '[ -f "$MARKER" ]'
check "state=off"                          '[ "$(cat "$STATE_FILE")" = "off" ]'
check "vbus_wait=1 (3s fast retry)"        '[ "$vbus_wait" = "1" ]'
check "log mentions SUPPRESSED"            'grep -q "restore SUPPRESSED" "$STUB_LOG"'
# second call must not spam the log (edge-triggered notice)
restore_video
check "notice logged only once"            '[ "$(grep -c "restore SUPPRESSED" "$STUB_LOG")" = "1" ]'
echo

# ---- T3: node missing (installer context) -> never block ------------------
echo "T3  usb/online node missing (installer/uninstaller) -> do not block"
setup MISSING
restore_video; rc=$?
check "restore proceeds (HPD high)"        '[ "$(cat "$HPD_NODE")" = "1" ]'
check "marker cleared"                     '[ ! -f "$MARKER" ]'
echo

# ---- T4: escape hatch VBUS_GUARD=0 ---------------------------------------
echo "T4  VBUS_GUARD=0 with usb/online=0 -> guard disabled (documented risk)"
setup 0 0
restore_video; rc=$?
check "guard disabled: HPD forced high"    '[ "$(cat "$HPD_NODE")" = "1" ]'
check "marker cleared"                     '[ ! -f "$MARKER" ]'
echo

# ---- T5: no partner -> skip before the guard even runs --------------------
echo "T5  no partner/cable attached -> skip (rc=2), guard untouched"
setup 0
STUB_LINK=0
restore_video; rc=$?
check "returns 2 (skipped)"                '[ "$rc" -eq 2 ]'
check "HPD untouched"                      '[ "$(cat "$HPD_NODE")" != "1" ]'
echo

# ---- T6: screenvid.sh and service.sh must keep identical guard logic ------
echo "T6  guard logic identical in screenvid.sh and service.sh (drift check)"
SV="$HERE/../tab-dp-watchdog/screenvid.sh"
SE="$HERE/../tab-dp-watchdog/service.sh"
body_of() {  # body_of <file> <fn> -> code lines only
    awk -v fn="$2" '
        $0 ~ ("^" fn "\\(\\) \\{") { inside = 1; next }
        inside && /^}$/ { exit }
        inside { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]*#.*$/, "", line); if (line != "") print line }
    ' "$1"
}
a=$(body_of "$SV" ext_vbus_ok)
b=$(body_of "$SE" ext_vbus_ok)
if [ -n "$a" ] && [ "$a" = "$b" ]; then
    ok "ext_vbus_ok implementations match"
else
    bad "ext_vbus_ok drifted between screenvid.sh and service.sh"
    echo "--- screenvid ---"; echo "$a"; echo "--- service ---"; echo "$b"
fi
a=$(body_of "$SV" vbus_evidence)
b=$(body_of "$SE" vbus_evidence)
if [ -n "$a" ] && [ "$a" = "$b" ]; then
    ok "vbus_evidence implementations match"
else
    bad "vbus_evidence drifted between screenvid.sh and service.sh"
fi
echo

echo "=== result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1

