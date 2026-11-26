#!/bin/sh
# Master switch (v1.10.0) - offline logic test.
#
# Runs the real daemons_stop() / release_handoff() / apply_enabled() from
# tab-dp-watchdog/service.sh against a fake sysfs tree, a fake process table
# and a fake pixel-clock node. No tablet, no root.
#
#   sh tests/enable_switch_test.sh
#
# Exit 0 = all cases pass.
#
# What is actually being asserted:
#   * OFF stops all three engines, and the second kill pass only fires for
#     daemons that ignored TERM (no unconditional pkill -9 spam)
#   * OFF never leaves the port sink-only (a sink-only port cannot charge,
#     and that state survives a reboot)
#   * OFF raises HPD only with real external VBUS - without it, raising HPD
#     re-streams DP off the tablet's own battery (the 17:36 panic path)
#   * OFF restores the pixel clock cap, ON re-applies it
#   * apply_enabled() is idempotent: no log line, no action on a no-op tick

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SE="$HERE/../tab-dp-watchdog/service.sh"
ST="$HERE/../tab-dp-watchdog/web/cgi-bin/status"
EN="$HERE/../tab-dp-watchdog/web/cgi-bin/enable"
IDX="$HERE/../tab-dp-watchdog/web/index.html"
for f in "$SE" "$ST" "$EN" "$IDX"; do
    [ -f "$f" ] || { echo "FATAL: $f not found"; exit 1; }
done

TMP="/tmp/dpen_$$_$(date +%s)"
mkdir -p "$TMP/sys/power_supply/usb" "$TMP/sys/power_supply/otg" \
    "$TMP/sys/power_supply/battery" "$TMP/sys/typec/port0" "$TMP/state" "$TMP/logs"

EXT_VBUS="$TMP/sys/power_supply/usb/online"
OTG_ONLINE="$TMP/sys/power_supply/otg/online"
POWER_ROLE="$TMP/sys/typec/port0/power_role"
BAT_CUR="$TMP/sys/power_supply/battery/current_now"
TYPEC_PORT="$TMP/sys/typec/port0"
HPD_NODE="$TMP/state/hpd"
LOGDIR="$TMP/state"
GATE_MARKER="$LOGDIR/sink_gate"
GATE_TS="$LOGDIR/sink_gate.ts"
TABLE="$TMP/state/proctable"
CAPLOG="$TMP/logs/cap"
LOGLOG="$TMP/logs/log"

# ---- extract the shipped functions verbatim -------------------------------
extract() {
    awk -v fn="$1" '
        $0 ~ ("^" fn "\\(\\) \\{") { inside = 1 }
        inside { print }
        inside && /^}$/ { exit }
    ' "$SE"
}
for f in daemons_stop release_handoff apply_enabled; do
    body=$(extract "$f")
    [ -n "$body" ] || { echo "FATAL: could not extract $f - did service.sh change shape?"; exit 1; }
    eval "$body"
done

# ---- fakes ----------------------------------------------------------------
log() { printf '%s\n' "$*" >> "$LOGLOG"; }
sleep() { :; }
add() { printf '%s %s\n' "$2" "$1" >> "$TABLE"; }   # add <cmdline> <pid>
pgrep() {
    _pat=$(printf '%s' "${2:-}" | sed 's/\[\.\]/./g')
    _out=$(awk -v p="$_pat" '$0 ~ p {printf "%s\n", $1}' "$TABLE" 2>/dev/null)
    [ -n "$_out" ] || return 1
    printf '%s\n' "$_out"
}
pkill() {                       # pkill -9 -f <pat>   ($3 is the pattern)
    _pat=$(printf '%s' "${3:-}" | sed 's/\[\.\]/./g')
    grep -v -- "$_pat" "$TABLE" > "$TABLE.n" 2>/dev/null
    mv "$TABLE.n" "$TABLE"
}
kill() {                        # daemons do honour TERM in this stub
    for _p in "$@"; do
        case "$_p" in ''|*[!0-9]*) continue ;; esac
        grep -v "^$_p " "$TABLE" > "$TABLE.n" 2>/dev/null
        mv "$TABLE.n" "$TABLE"
    done
}
start_screenvid() { add "modules/tab_dp_watchdog/screenvid.sh" 4001; log "stub: start screenvid"; }
start_wakegate()  { add "modules/tab_dp_watchdog/wakegate.sh"  4002; log "stub: start wakegate"; }
start_otgcut()    { add "modules/tab_dp_watchdog/otgcut.sh"    4003; log "stub: start otgcut"; }
gate_is_on()      { [ -f "$GATE_MARKER" ]; }
ext_vbus_ok()     { [ "${VBUS:-1}" = "1" ]; }
vbus_evidence()   { echo "usb/online=$VBUS otg=0"; }
apply_hz_mode()   { printf '%s\n' "${1:-?}" >> "$CAPLOG"; return 0; }
hz_cap_for()      { echo 300000; }
pclk_org()        { echo 675000; }
mount()           { :; }

ENGINES="screenvid wakegate otgcut"
HZ_MODE=60
ENABLED=1
enabled_prev=-1

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
running() { wc -l < "$TABLE" | tr -d ' '; }

setup() {  # setup <vbus> <enabled> <prev> <daemons:1|0> <gate:1|0> <video_off:1|0>
    VBUS=$1; ENABLED=$2; enabled_prev=$3
    : > "$TABLE"; : > "$CAPLOG"; : > "$LOGLOG"
    rm -f "$GATE_MARKER" "$GATE_TS" "$LOGDIR/video_off" 2>/dev/null
    : > "$HPD_NODE"
    printf 'dual' > "$TYPEC_PORT/port_type"
    [ "$4" = "1" ] && { add "modules/tab_dp_watchdog/screenvid.sh" 4001
                        add "modules/tab_dp_watchdog/wakegate.sh"  4002
                        add "modules/tab_dp_watchdog/otgcut.sh"    4003; }
    [ "$5" = "1" ] && { : > "$GATE_MARKER"; echo "sink" > "$TYPEC_PORT/port_type"; }
    [ "$6" = "1" ] && : > "$LOGDIR/video_off"
}

echo "=== master switch, v1.10.0 ==="
echo "source: $SE"
echo

# ---- A. OFF: engines stop, port handed back ------------------------------
echo "A  OFF -> all engines stopped, gate released, video restored"
setup 1 0 1 1 1 1
apply_enabled "test"
check "all three engines gone"                '[ "$(running)" = "0" ]'
check "TERM used, no KILL (they honoured it)" '! grep -q "switch: KILL" "$LOGLOG"'
check "sink gate marker removed"              '[ ! -f "$GATE_MARKER" ]'
check "port_type back to dual (can charge)"   '[ "$(cat "$TYPEC_PORT/port_type")" = "dual" ]'
check "video_off marker cleared"              '[ ! -f "$LOGDIR/video_off" ]'
check "hpd raised (VBUS present)"             '[ "$(cat "$HPD_NODE")" = "1" ]'
check "pixel clock cap restored to auto"      '[ "$(cat "$CAPLOG")" = "auto" ]'
check "video.state forced back to on"         '[ "$(cat "$LOGDIR/video.state" 2>/dev/null)" = "on" ]'
echo

# ---- B. OFF without VBUS: never raise HPD --------------------------------
echo "B  OFF with no external VBUS -> no HPD write (panic path)"
setup 0 0 1 1 0 1
apply_enabled "test"
check "engines stopped"                       '[ "$(running)" = "0" ]'
check "hpd untouched"                         '[ ! -s "$HPD_NODE" ]'
check "video_off still cleared"               '[ ! -f "$LOGDIR/video_off" ]'
check "log explains why HPD stayed low"       'grep -q "HPD left LOW" "$LOGLOG"'
echo

# ---- C. ON: engines start, cap re-applied --------------------------------
echo "C  ON -> engines started, refresh cap applied"
setup 1 1 0 0 0 0
HZ_MODE=60
hz_applied=none
apply_enabled "test"
check "three engines started"                 '[ "$(running)" = "3" ]'
check "screenvid started"                     'grep -q "stub: start screenvid" "$LOGLOG"'
check "wakegate started"                      'grep -q "stub: start wakegate" "$LOGLOG"'
check "otgcut started"                        'grep -q "stub: start otgcut" "$LOGLOG"'
check "cap re-applied (60)"                   '[ "$(cat "$CAPLOG")" = "60" ]'
check "hz_applied tracked"                    '[ "$hz_applied" = "60" ]'
echo

# ---- D. idempotence ------------------------------------------------------
echo "D  repeated tick with an unchanged switch does nothing"
setup 1 1 1 1 0 0
apply_enabled "test"
check "no log line on a no-op tick"           '[ ! -s "$LOGLOG" ]'
check "no cap write on a no-op tick"          '[ ! -s "$CAPLOG" ]'
check "engines untouched"                     '[ "$(running)" = "3" ]'
setup 0 0 0 0 0 0
apply_enabled "test"
check "OFF repeated: no log line"             '[ ! -s "$LOGLOG" ]'
echo

# ---- D2. OFF then ON re-applies the cap (the hz_applied drift) ----------
echo "D2 OFF restores the cap and ON really puts it back"
setup 1 0 1 1 0 0
HZ_MODE=60; hz_applied=60
apply_enabled "test"
check "OFF wrote the org cap (auto)"           '[ "$(cat "$CAPLOG")" = "auto" ]'
check "hz_applied follows the restore"         '[ "$hz_applied" = "auto" ]'
ENABLED=1
apply_enabled "test"
check "ON re-applied the 60Hz cap"             '[ "$(tail -n 1 "$CAPLOG")" = "60" ]'
check "hz_applied back to 60"                  '[ "$hz_applied" = "60" ]'
echo

# ---- E. KILL fallback only for engines that ignore TERM ------------------
echo "E  an engine that survives TERM gets KILL, the others do not"
setup 0 0 1 1 0 0
kill() { :; }                      # simulate a daemon ignoring TERM
apply_enabled "test"
check "KILL path taken"                        'grep -q "switch: KILL" "$LOGLOG"'
check "at least one survivor reported"         'grep -q "did not honour TERM" "$LOGLOG"'
kill() { for _p in "$@"; do case "$_p" in ""|*[!0-9]*) continue ;; esac
         grep -v "^$_p " "$TABLE" > "$TABLE.n" 2>/dev/null; mv "$TABLE.n" "$TABLE"; done; }
echo

# ---- F. shipped defaults / wiring ---------------------------------------
echo "F  shipped files carry the switch, defaulting to enabled"
check "ENABLED=1 default in service.sh"        'grep -q "^ENABLED=1" "$SE"'
check "ENABLED validated in service.sh"        'grep -q "case \"\$ENABLED\" in" "$SE"'
check "ENABLED=1 default in status CGI"        'grep -q "ENABLED=1" "$ST"'
check "status reports the field"               'grep -q "\"enabled\":%d" "$ST"'
check "status reports engine count"            'grep -q "\"engines\":%d" "$ST"'
check "enable CGI persists ENABLED"            'grep -q "printf .ENABLED=%s" "$EN"'
check "enable CGI defaults to 1"               'grep -q "^ENABLED=1" "$EN"'
check "UI has the switch"                      'grep -q "id=\"swEnable\"" "$IDX"'
check "UI posts to cgi-bin/enable"             'grep -q "cgi-bin/enable" "$IDX"'
check "UI greys the dependent cards"           'grep -q "body.modoff .dep" "$IDX"'
check "service.sh does not start engines while OFF" \
    'sed -n "/if \[ \"\$ENABLED\" != \"1\" \]; then/,+6p" "$SE" | grep -q "continue"'
echo

echo "=== result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
