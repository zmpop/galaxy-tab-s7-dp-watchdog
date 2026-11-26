#!/bin/sh
# Sink-gate logic test (v1.8.0).
#
# Extracts the real gate functions from tab-dp-watchdog/screenvid.sh and runs
# them against a fake sysfs tree, with echo() wrapped so every sysfs write is
# recorded. No tablet, no root.
#
#   sh tests/sink_gate_test.sh
#
# Exit 0 = all assertions pass.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SV="$HERE/../tab-dp-watchdog/screenvid.sh"
UN="$HERE/../tab-dp-watchdog/uninstall.sh"
[ -f "$SV" ] || { echo "FATAL: $SV not found"; exit 1; }

TMP="/tmp/sinkgate_$$_$(date +%s)"
mkdir -p "$TMP/sys/typec/port0" "$TMP/state"
TYPEC_PORT="$TMP/sys/typec/port0"
PORTFILE="$TYPEC_PORT/port_type"
LOGDIR="$TMP/state"
GATE_MARKER="$LOGDIR/sink_gate"
GATE_TS="$LOGDIR/sink_gate.ts"
GATE_RELEASE="$LOGDIR/sink_gate.release"
SINK_GATE=1
GATE_GRACE=10
LOG="$LOGDIR/log"
: > "$LOG"

printf '[dual] source sink\n' > "$PORTFILE"

# ---- extract the shipped functions verbatim ------------------------------
extract() {
    awk -v fn="$1" '
        $0 ~ ("^" fn "\\(\\) \\{") { inside = 1 }
        inside { print }
        inside && /^}$/ { exit }
    ' "$SV"
}
for f in pin_sink gate_is_on gate_engage gate_release gate_in_grace; do
    body=$(extract "$f")
    [ -n "$body" ] || { echo "FATAL: could not extract $f"; exit 1; }
    eval "$body"
done

log() { echo "$*" >> "$LOG"; }

# The write target is a shell redirection, so it is invisible to an echo()
# wrapper. Assert on the file content instead: seed a sentinel before each
# case and read it back. "No write" is proved by the sentinel surviving.
SENTINEL="__untouched__"
seed()   { printf '%s\n' "$SENTINEL" > "$PORTFILE"; }
content(){ tr -d '\r\n' < "$PORTFILE"; }

PASS=0; FAIL=0
check() {
    if eval "$2"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; fi
}


echo "=== A. gate engage ==="
check "no marker before engage"        '! gate_is_on'
seed
check "pin_sink returns 0"             'pin_sink'
check "pin_sink wrote 'sink'"          '[ "$(content)" = "sink" ]'
seed
gate_engage
check "engage created the marker"      'gate_is_on'
check "engage wrote 'sink'"            '[ "$(content)" = "sink" ]'
check "engage stamped GATE_TS"         '[ -s "$GATE_TS" ]'

echo "=== B. idempotent engage ==="
seed
gate_engage
check "second engage writes nothing"   '[ "$(content)" = "$SENTINEL" ]'

echo "=== C. release ==="
seed
gate_release "test"
check "release removed the marker"     '! gate_is_on'
check "release wrote 'dual'"           '[ "$(content)" = "dual" ]'
check "release stamped GATE_RELEASE"   '[ -s "$GATE_RELEASE" ]'

echo "=== D. grace window ==="
check "grace is active right now"      'gate_in_grace'
gate_grace_until=0
printf '%s\n' $(( $(date +%s) - GATE_GRACE - 1 )) > "$GATE_RELEASE"
check "grace expired after GATE_GRACE" '! gate_in_grace'

echo "=== E. SINK_GATE=0 disables the gate ==="
SINK_GATE=0
seed
check "pin_sink refuses"               '! pin_sink'
check "nothing written"                '[ "$(content)" = "$SENTINEL" ]'
check "gate_engage refuses"            '! gate_engage'
check "no marker left behind"          '! gate_is_on'
SINK_GATE=1

echo "=== F. release without a gate still forces dual (un-pin a stale port) ==="
seed
gate_grace_until=0
gate_release "no gate"
check "wrote dual anyway"              '[ "$(content)" = "dual" ]'

echo "=== G. drift checks against the shipped scripts ==="
check "screenvid: engages only when VBUS is absent" \
      'awk "/vbus_ok_now.*=.*\"0\"/{f=1} f&&/gate_engage/{found=1} /vbus: external VBUS back/{f=0} END{exit !found}" "$SV"'
check "screenvid: re-asserts with pin_sink" \
      'grep -q "pin_sink" "$SV"'
check "screenvid: releases on VBUS return" \
      'grep -q "gate_release \"external VBUS present\"" "$SV"'
check "screenvid: clears a stale gate at startup" \
      'grep -q "stale marker from a previous run" "$SV"'
check "service: refuses a replug while gated" \
      'grep -q "sink gate engaged" "$(dirname "$SV")/service.sh"'
check "service: releases the gate when VBUS is present" \
      'grep -q "service safety net" "$(dirname "$SV")/service.sh"'
check "uninstall: writes dual unconditionally (read-back lies)" \
      'grep -q "read-back still prints" "$UN"'
check "uninstall: removes the gate markers" \
      'grep -q "rm -f /data/adb/tpdp/sink_gate" "$UN"'

echo
echo "=== result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
