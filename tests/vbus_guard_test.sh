#!/bin/sh
# DP link guard - offline logic test (v1.7.0 semantics).
#
# Runs the real functions from tab-dp-watchdog/screenvid.sh against a fake sysfs
# tree. No tablet, no root, no debugfs.
#
# v1.7.0 rewrite. The old suite asserted "restore must force HPD high" - that is
# exactly the behaviour that broke the picture on hardware: hpd=1 injected into
# the PD re-negotiation window leaves status=enabled with pclock=0 and a black
# sink. The invariants are inverted here, and every write the daemon performs is
# captured through an echo() wrapper so the *order* of the repair ladder can be
# asserted (FIFOs were tried first but they block on read and need seeding).
#
#   sh tests/vbus_guard_test.sh
#
# Exit 0 = all cases pass.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SV="$HERE/../tab-dp-watchdog/screenvid.sh"
SE="$HERE/../tab-dp-watchdog/service.sh"
[ -f "$SV" ] || { echo "FATAL: $SV not found"; exit 1; }
[ -f "$SE" ] || { echo "FATAL: $SE not found"; exit 1; }

# fixed path: mktemp returns a Windows-style path under Git Bash, which some rm
# wrappers refuse; never rm -rf the tree here either (the wrapper kills the shell)
TMP="/tmp/dpguard_$$_$(date +%s)"
mkdir -p "$TMP/sys/power_supply/usb" "$TMP/sys/power_supply/otg" \
    "$TMP/sys/power_supply/battery" "$TMP/sys/typec/port0" "$TMP/state"

EXT_VBUS="$TMP/sys/power_supply/usb/online"
OTG_ONLINE="$TMP/sys/power_supply/otg/online"
POWER_ROLE="$TMP/sys/typec/port0/power_role"
BAT_CUR="$TMP/sys/power_supply/battery/current_now"
TYPEC_PORT="$TMP/sys/typec/port0"
HPD_NODE="$TMP/state/hpd"
DP_DEBUG="$TMP/state/dp_debug"
STATE_FILE="$TMP/state/video.state"
MARKER="$TMP/state/video_off"
STUB_LOG="$TMP/state/log"
ECHOLOG="$TMP/state/echo.log"
INPUTLOG="$TMP/state/input.log"

printf '[sink] source\n' > "$POWER_ROLE"
printf '0\n'             > "$OTG_ONLINE"
printf '300\n'           > "$BAT_CUR"
: > "$HPD_NODE"

# ---- extract functions verbatim from the shipped script -------------------
extract() {
    awk -v fn="$1" '
        $0 ~ ("^" fn "\\(\\) \\{") { inside = 1 }
        inside { print }
        inside && /^}$/ { exit }
    ' "$SV"
}
for f in ext_vbus_ok vbus_evidence dp_pclk video_real_streaming vbus_lost_mid_restore restore_video; do
    body=$(extract "$f")
    [ -n "$body" ] || { echo "FATAL: could not extract $f - did screenvid.sh change shape?"; exit 1; }
    eval "$body"
done

# ---- harness --------------------------------------------------------------
VBUS_GUARD=1
PD_REPAIR=1
vbus_notice=0
vbus_wait=0
STUB_ON=0

# capture link writes: the daemon only ever writes 0/1 to hpd and sink/dual to
# port_type, so those four tokens identify every poke it makes, in order
echo() {
    case "${1:-}" in
        0|1|sink|dual) printf '%s\n' "$1" >> "$ECHOLOG" ;;
    esac
    command echo "$@"
}
# silence the daemon's own chatter, keep it assertable
log() { printf '%s\n' "$*" >> "$STUB_LOG"; }
link_present()    { [ "${STUB_LINK:-1}" = "1" ]; }
partner_present() { [ "${STUB_LINK:-1}" = "1" ]; }
cable_present()   { [ "${STUB_LINK:-1}" = "1" ]; }
ensure_hpd()      { [ -e "$HPD_NODE" ]; }
refresh_actual()  { ACT_ST=connected; ACT_EN=enabled; }
# STUB_ON: 1 = already streaming, 0 = never comes up, afterreplug = comes up
# once the daemon has written the sink->dual replug (that is how the real
# kernel behaves: the virtual replug is what re-enumerates this link)
video_actual_on() {
    case "$STUB_ON" in
        1)           return 0 ;;
        afterreplug) grep -qx 'dual' "$ECHOLOG" 2>/dev/null ;;
        *)           return 1 ;;
    esac
}
sleep() { :; }
input() { printf '%s\n' "$*" >> "$INPUTLOG"; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# writes, in order, as a single space-separated string
writes() { cat "$ECHOLOG" 2>/dev/null | tr '\n' ' '; }
hpd_writes() { grep -c '^[01]$' "$ECHOLOG" 2>/dev/null || echo 0; }

setup() {  # setup <usb_online|MISSING> [guard] [STUB_ON]
    rm -f "$EXT_VBUS"
    [ "$1" = "MISSING" ] || printf '%s\n' "$1" > "$EXT_VBUS"
    VBUS_GUARD=${2:-1}
    STUB_ON=${3:-0}
    STUB_LINK=1
    vbus_notice=0; vbus_wait=0
    rm -f "$MARKER" "$STATE_FILE"
    printf 'dual' > "$TYPEC_PORT/port_type"
    : > "$HPD_NODE"
    : > "$ECHOLOG"; : > "$INPUTLOG"; : > "$STUB_LOG"
}

echo "=== DP link guard, v1.7.0 semantics ==="
echo "source: $SV"
echo

# ---- A. real video_real_streaming() / dp_pclk()---------------------------
echo "A  video_real_streaming(): pclock is the truth, status/enabled are not"
printf '\tstate=0xa5\n\tresolution=2560x1600@60Hz\n\tpclock=268500KHz\n' > "$DP_DEBUG"
check "pclk parsed (268500)"                '[ "$(dp_pclk)" = "268500" ]'
check "streaming detected"                  'video_real_streaming'
printf '\tstate=0xa5\n\tresolution=0x0@0Hz\n\tpclock=0KHz\n' > "$DP_DEBUG"
check "pclk=0 -> NOT streaming"             '! video_real_streaming'
check "this is the exact black-screen state (enabled but pclk 0)" '[ "$(cat "$DP_DEBUG" | grep -c pclock=0)" = "1" ]'
rm -f "$DP_DEBUG"
check "node absent -> do not block (trust status)" 'video_real_streaming'
printf 'garbage without the field\n' > "$DP_DEBUG"
check "unparsable -> do not block"          'video_real_streaming'
echo

# ---- B1. already streaming + VBUS ok -> NO writes at all ----------------
echo "B1 VBUS ok + already streaming -> hands off (the v1.6.0 regression)"
setup 1 1 1
restore_video; rc=$?
check "rc=0"                                '[ "$rc" -eq 0 ]'
check "nothing written to hpd"              '[ -z "$(writes)" ]'
check "no input/keyevent"                   '[ ! -s "$INPUTLOG" ]'
echo

# ---- B2. VBUS absent -> suppress, and still write NOTHING ---------------
echo "B2 VBUS absent (PD pulled) -> suppressed, zero link writes"
setup 0 1 0
restore_video; rc=$?
check "rc=0 (handled, not an error)"        '[ "$rc" -eq 0 ]'
check "nothing written to hpd/port_type"    '[ -z "$(writes)" ]'
check "marker set"                          '[ -f "$MARKER" ]'
check "state=off"                           '[ "$(cat "$STATE_FILE")" = "off" ]'
check "vbus_wait=1 (fast retry)"            '[ "$vbus_wait" = "1" ]'
check "log says SUPPRESSED"                 'grep -q "restore SUPPRESSED" "$STUB_LOG"'
restore_video
check "notice logged once only"             '[ "$(grep -c "restore SUPPRESSED" "$STUB_LOG")" = "1" ]'
echo

# ---- B3. VBUS ok, dark: replug is rung 1 and it fixes the link ----------
echo "B3 VBUS ok + sink dark -> port_type replug first, hpd never touched"
setup 1 1 afterreplug
restore_video; rc=$?
check "rc=0"                                '[ "$rc" -eq 0 ]'
check "hpd=1 then replug wrote sink then dual" '[ "$(writes)" = "1 sink dual " ]'
check "marker cleared"                      '[ ! -f "$MARKER" ]'
check "state=on"                            '[ "$(cat "$STATE_FILE")" = "on" ]'
echo

# ---- B4. replug ineffective -> hpd=1 second, screen bounce third --------
echo "B4 replug ineffective -> hpd=1, then screen bounce (both gated)"
setup 1 1 0
restore_video; rc=$?
check "replug attempted before anything else" '[ "$(writes | cut -d" " -f1-3 | sed "s/ *$//")" = "1 sink dual" ]'
check "hpd=1 only after replug"             'grep -qx "1" "$ECHOLOG"'
check "screen bounce as last resort"        'grep -q "keyevent 26" "$INPUTLOG"'
check "rc=1 (reported as failure, will retry)" '[ "$rc" -eq 1 ]'
echo

# ---- B5. escape hatch ---------------------------------------------------
echo "B5 VBUS_GUARD=0 -> guard disabled even with usb/online=0"
setup 0 0 0
restore_video
check "proceeds to the ladder"              'grep -q "sink" "$ECHOLOG"'
echo

# ---- B6. nothing attached ----------------------------------------------
echo "B6 no partner -> skip with rc=2, zero writes"
setup 0 1 0
STUB_LINK=0
restore_video; rc=$?
check "rc=2"                                '[ "$rc" -eq 2 ]'
check "nothing written to hpd/port_type"    '[ -z "$(writes)" ]'
echo

# ---- C. static invariants (the regression class) ------------------------
echo "C  static invariants"
n_hpd=$(grep -c '> *"\$HPD_NODE"' "$SV")
check "hpd writes are the 4 intended sites (cut, replug raise, rung 2, re-pin)" '[ "$n_hpd" = "4" ]'
check "cut_video really writes hpd=0 (v1.7.0 had deleted this - the v1.11.0 bug)" \
    'printf "%s" "$(extract cut_video)" | grep -q "echo 0 > \"\$HPD_NODE\""'
check "cut_video never writes hpd=1 (raising HPD is restore's job, VBUS-gated)" \
    '! printf "%s" "$(extract cut_video)" | grep -q "echo 1 > \"\$HPD_NODE\""'
check "re-pin loop keeps hpd=0 while the cut holds" \
    'grep -q "cut_tick" "$SV" && grep -q "^CUT_REPIN=" "$SV"'
guard_block=$(awk '/external VBUS observation/,/^$/' "$SV")
check "VBUS observation block writes nothing to hpd" \
    '! printf "%s" "$guard_block" | grep -q "HPD_NODE *2"'
check "VBUS observation block writes nothing to port_type" \
    '! printf "%s" "$guard_block" | grep -qF "> \"\$TYPEC_PORT/port_type\""'
check "no eager restore on the VBUS edge (v1.6.0 bug)" \
    '! printf "%s" "$guard_block" | grep -q "restore_video"'
check "service.sh holds recovery for PD_SETTLE after VBUS returns" \
    'grep -q "vbus_ready" "$SE" && grep -q "^PD_SETTLE=" "$SE"'
check "service.sh stale-marker path no longer pokes hpd" \
    '! sed -n "/marker cleared; screenvid owns/,+2p" "$SE" | grep -q "HPD_NODE"'
echo

# ---- D. drift between the two daemons -----------------------------------
echo "D  guard logic identical in screenvid.sh and service.sh"
body_of() {
    awk -v fn="$2" '
        $0 ~ ("^" fn "\\(\\) \\{") { inside = 1; next }
        inside && /^}$/ { exit }
        inside { l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t]*#.*$/, "", l); if (l != "") print l }
    ' "$1"
}
a=$(body_of "$SV" ext_vbus_ok); b=$(body_of "$SE" ext_vbus_ok)
check "ext_vbus_ok match"  '[ -n "$a" ] && [ "$a" = "$b" ]'
a=$(body_of "$SV" vbus_evidence); b=$(body_of "$SE" vbus_evidence)
check "vbus_evidence match" '[ -n "$a" ] && [ "$a" = "$b" ]'
echo

# ---- E. cut_video(): the v1.11.0 regression fix -------------------------
# v1.7.0 removed the hpd=0 write after a bad measurement, so from then until
# v1.11.0 cut_video() was pure bookkeeping: the panel kept streaming with the
# tablet asleep. These cases pin the behaviour back down.
echo "E  cut_video(): hpd=0 is the lever, and it must really be written"
CUTMODE=0          # 0 = link streaming, 1 = encoder off (sink dark)
LINK_REACTS=1      # 1 = the fake kernel honours hpd=0
echo() {
    case "${1:-}" in
        0) printf '0\n' >> "$ECHOLOG"; [ "$LINK_REACTS" = "1" ] && CUTMODE=1 ;;
        1) printf '1\n' >> "$ECHOLOG" ;;
        sink|dual) printf '%s\n' "$1" >> "$ECHOLOG" ;;
    esac
    command echo "$@"
}
refresh_actual() {
    if [ "$CUTMODE" = "1" ]; then ACT_ST=disconnected; ACT_EN=disabled
    else ACT_ST=connected; ACT_EN=enabled; fi
}
# the kernel re-asserts hotplug ~5s after hpd=0: status comes back, encoder not
# (printf, not echo: the echo() wrapper above would log our own stub output)
dp_pclk() { if [ "$CUTMODE" = "1" ]; then printf '0\n'; else printf '268500\n'; fi; }
eval "$(extract video_cut_ok)"
eval "$(extract cut_video)"

cut_setup() {
    CUTMODE=${1:-0}; LINK_REACTS=${2:-1}; CUT_LEVER=${3:-1}
    : > "$ECHOLOG"; : > "$STUB_LOG"
    rm -f "$MARKER" "$STATE_FILE"
    [ -e "$HPD_NODE" ] || : > "$HPD_NODE"
}

cut_setup 0 1 1
cut_video; rc=$?
check "streaming -> cut succeeds"            '[ "$rc" -eq 0 ]'
check "hpd=0 was really written"             'grep -qx "0" "$ECHOLOG"'
check "marker set"                           '[ -f "$MARKER" ]'
check "state=off"                            '[ "$(cat "$STATE_FILE")" = "off" ]'
check "log says confirmed via hpd=0"         'grep -q "confirmed via hpd=0" "$STUB_LOG"'

cut_setup 1 1 1
cut_video; rc=$?
check "already dark -> rc=0, no write"       '[ "$rc" -eq 0 ] && [ ! -s "$ECHOLOG" ]'
check "already dark -> log says already off" 'grep -q "already off" "$STUB_LOG"'

cut_setup 0 0 1                                  # kernel ignores hpd=0
cut_video; rc=$?
check "inert lever -> rc=1, never claim a cut" '[ "$rc" -eq 1 ]'
check "3 attempts made"                      '[ "$(grep -cx "0" "$ECHOLOG")" = "3" ]'
check "failed cut leaves NO marker (link still live)" '[ ! -f "$MARKER" ]'

cut_setup 0 1 0
cut_video; rc=$?
check "CUT_LEVER=0 -> observe only, no write" '[ "$rc" -eq 0 ] && [ ! -s "$ECHOLOG" ]'
check "CUT_LEVER=0 -> still marks the intent" '[ -f "$MARKER" ]'

cut_setup 0 1 1; rm -f "$HPD_NODE"
cut_video; rc=$?
check "debugfs node missing -> rc=1"         '[ "$rc" -eq 1 ]'
: > "$HPD_NODE"
echo

echo "=== result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
