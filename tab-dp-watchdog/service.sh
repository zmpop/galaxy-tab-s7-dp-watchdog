#!/system/bin/sh
# Tab S7 DP Link Watchdog v1.6.0 - service entry
# Runs as root (u:r:magisk:s0) at late_start service mode.
#
# v1.6.0: external VBUS guard (kernel panic fix).
#   Root cause of the 2026-11-26 17:36 panic: the screen's PD supply was pulled,
#   the tablet flipped to Source and powered the screen from its own battery
#   (~1.9A), and one of this module's "echo 1 > hpd" paths re-streamed DP on
#   that unsupplied port. Plugging the PD back in then aborted a still-ENABLED
#   stream (DP_STATE_ABORTED 0x15f) -> sde_kms_wait_for_commit_done -110 ->
#   MM NoC fatal -> TZBSP_ERR_FATAL_NOC_ERROR -> SError(NMI) -> kernel panic.
#   Fix: every HPD-high path (boot failsafe, hz re-enumerate, stale-marker
#   restore, virtual replug) is gated on usb/online=1, i.e. real external
#   power. With no VBUS the link is deliberately left DOWN and recovers by
#   itself once the PD supply is reconnected. Config: VBUS_GUARD=0 disables.
# v1.4.0: screen wake gate + screen-off timeout enforcer (wakegate.sh).
#   Keeps the tablet from lighting up on non user events and from staying lit
#   when the framework timeout is blocked by Samsung's HDMI wake lock.
#   Controlled by WAKE_GATE / WAKE_GATE_TOUCH / TIMEOUT_ENFORCE (web UI).
# v1.3.3: external display refresh rate selector. The 60Hz on/off lock was
#   upgraded to a three-way choice (60 / 120 / auto) driven by HZ_MODE:
#     60   -> pixel clock capped at PCLK_CAP_KHZ  (default 300000)
#     120  -> pixel clock capped at PCLK_120_KHZ  (default 560000)
#     auto -> kernel default limit restored (no filtering)
#   Legacy LOCK60 configs keep working (LOCK60=1 -> 60, LOCK60=0 -> auto).
# v1.3.2: 60Hz lock. Caps the DP pixel clock (debugfs max_pclk_khz) so the
#   framework cannot pick high-bandwidth modes (e.g. 2560x1600@120Hz needs
#   a 537MHz pixel clock, 60Hz only 268MHz). Halving the link load fixes
#   the marginal-signal glitches (brief blackouts + self screen-on).
#   Controlled by config LOCK60 (web UI switch), applied at boot and on
#   config hot-reload; original limit is saved and restored on disable.
# v1.3.1: suspend-aware stale marker check. hb.video ages in wall-clock time
#   while the tablet is suspended (Doze), which made the old check restore
#   video every suspend cycle while the screen was off (night flood).
#   Now the screen state (mWakefulness) is consulted first: asleep/dozing
#   means "frozen, not dead" -> heartbeat self-healed, cut kept.
# v1.2.0: config hot-reload. When /data/adb/tpdp/config changes
#   (e.g. a device is saved from the web UI), the watchdog reloads
#   TP_VID/TP_PID and poll parameters within one poll cycle.
# v1.1.0: added "wedged port" detection.
#   Fault B: DP was up earlier this session, now down, and the port is
#   wedged (partner present/flickering but no stable attach, touch absent).
#   This happens after an abnormal role transition (e.g. screen-side PD
#   replug). Recovery: same virtual replug (port_type sink->dual).
#   Gated on "ever_dp_up" so standalone tablet use never triggers action.

MODDIR=${0%/*}
LOGDIR=/data/adb/tpdp
LOG=$LOGDIR/log
mkdir -p "$LOGDIR"

# ---------- default config (override via $LOGDIR/config) ----------
TP_VID=04f3            # touchscreen idVendor  (ELAN)
TP_PID=8512            # touchscreen idProduct
TYPEC_PORT=/sys/class/typec/port0
PARTNER_DIR=/sys/class/typec/port0-partner
EXTCON_STATE=/sys/class/extcon/extcon0/state
POLL_SEC=3             # poll interval
STRIKES=2              # consecutive fault polls before action (debounce)
MAX_RETRY=5            # recovery attempts per fault episode
BOOT_DELAY=20          # seconds to wait after service start
VIDEO_SWITCH=1         # 1 = cut DP video while the screen is off (screenvid)
HZ_MODE=60             # external display refresh cap: 60 | 120 | auto
PCLK_CAP_KHZ=300000    # 60Hz-class pixel clock cap; 60Hz mode needs 268MHz
PCLK_120_KHZ=560000    # 120Hz-class pixel clock cap; 120Hz mode needs 537MHz
WAKE_GATE=1            # 1 = only touchscreen tap / power key may light the screen
WAKE_GATE_TOUCH=1      # 1 = touchscreen tap is allowed to wake (needs WAKE_GATE=1)
TIMEOUT_ENFORCE=1      # 1 = force the system screen-off timeout to take effect
VBUS_GUARD=1           # 1 = never touch the DP link while external VBUS is absent
PD_SETTLE=4            # v1.7.0: seconds to let the PD contract settle before recovering
SINK_GATE=0            # v1.8.1: default OFF (see screenvid.sh - pinning sink does not cut VBUS)
ENABLED=1              # v1.10.0: master switch; 0 = module idle, port handed back to stock
# --------------------------------------------------------------------

[ -f "$LOGDIR/config" ] && . "$LOGDIR/config"
# v1.10.0: the master switch is read before anything acts on the port, so a
# corrupt value must never be able to leave the module half-configured.
case "$ENABLED" in
    0|1) ;;
    *) ENABLED=1 ;;
esac
# validate HZ_MODE; map legacy LOCK60 (v1.3.2) when no HZ_MODE key exists
case "$HZ_MODE" in
    60|120|auto) ;;
    *) HZ_MODE=60 ;;
esac
if [ -f "$LOGDIR/config" ] && ! grep -q '^HZ_MODE=' "$LOGDIR/config"; then
    [ "${LOCK60:-1}" = "0" ] && HZ_MODE=auto
fi

cfg_mtime=0
[ -f "$LOGDIR/config" ] && cfg_mtime=$(date -r "$LOGDIR/config" +%s 2>/dev/null || echo 0)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 524288 ] && \
        tail -n 400 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# ---------- screen gated video output (v1.3.0) ----------
HPD_NODE=/sys/kernel/debug/drm_dp/hpd

# ---------- v1.6.0: external VBUS guard ----------
# Every place that can force HPD high must be gated on real external power:
# usb/online=1 means a charger / the screen's PD supply feeds VBUS. When it is
# 0 the tablet is Source and powers the screen from its own battery; re-streaming
# DP in that state is what produced the 2026-11-26 17:36 NoC panic (DP_STATE_
# ABORTED 0x15f -> sde_kms_wait_for_commit_done -110 -> SError -> panic).
# Keep in sync with screenvid.sh.
EXT_VBUS=/sys/class/power_supply/usb/online
OTG_ONLINE=/sys/class/power_supply/otg/online
POWER_ROLE=$TYPEC_PORT/power_role
BAT_CUR=/sys/class/power_supply/battery/current_now

ext_vbus_ok() {
    [ "$VBUS_GUARD" = "1" ] || return 0
    local u
    u=$(cat "$EXT_VBUS" 2>/dev/null)
    [ -z "$u" ] && return 0          # node absent -> cannot judge, never block
    [ "$u" = "1" ] && return 0
    return 1
}

# ---------- v1.8.0: sink gate (owned by screenvid.sh) ----------
# screenvid pins port_type=sink while external VBUS is absent so the tablet
# cannot feed the screen from its own battery. The marker is the shared state;
# this daemon must not write dual while it exists (that is exactly what
# re-enables the 5V output) and must release it if the power comes back while
# screenvid is down - a sink-only port can never charge.
GATE_MARKER=$LOGDIR/sink_gate
GATE_TS=$LOGDIR/sink_gate.ts
GATE_RELEASE=$LOGDIR/sink_gate.release
gate_is_on() { [ -f "$GATE_MARKER" ]; }

gate_release() {
    rm -f "$GATE_MARKER" "$GATE_TS" 2>/dev/null
    echo dual > "$TYPEC_PORT/port_type" 2>/dev/null
    date +%s > "$GATE_RELEASE" 2>/dev/null
    log "sink gate: released ($1) -> port_type=dual"
}

vbus_evidence() {
    echo "usb/online=$(cat "$EXT_VBUS" 2>/dev/null) otg=$(cat "$OTG_ONLINE" 2>/dev/null) role=$(cat "$POWER_ROLE" 2>/dev/null) port=$(cat "$TYPEC_PORT/port_type" 2>/dev/null) ma=$(cat "$BAT_CUR" 2>/dev/null)"
}

# ---------- refresh rate selector (v1.3.3) ----------
PCLK_NODE=/sys/kernel/debug/drm_dp/max_pclk_khz
DPDEBUG_NODE=/sys/kernel/debug/drm_dp/dp_debug

dp_hz() {
    # current DP timing, e.g. "2560x1600@120Hz" (lines carry leading blanks)
    sed -n 's/^[[:space:]]*resolution=//p' "$DPDEBUG_NODE" 2>/dev/null | head -n 1
}

dp_hz_num() {
    # numeric refresh of the current timing, e.g. "120"; empty if unknown
    dp_hz | sed -n 's/.*@\([0-9]\{1,\}\)Hz.*/\1/p' | head -n 1
}

pclk_org() {
    # node prints: "max_pclk_khz = 675000, org: 675000" - the org value is
    # the kernel default limit; remember it so disable can restore it.
    if [ -s "$LOGDIR/pclk_org" ]; then
        cat "$LOGDIR/pclk_org"
    else
        sed -n 's/.*org: \([0-9]\{1,\}\).*/\1/p' "$PCLK_NODE" 2>/dev/null
    fi
}

hz_cap_for() {
    # pixel clock cap (kHz) for a refresh mode: 60 | 120 | auto
    case "$1" in
        60)  echo "$PCLK_CAP_KHZ" ;;
        120) echo "$PCLK_120_KHZ" ;;
        *)   pclk_org ;;
    esac
}

apply_hz_mode() {
    # $1: 60|120|auto. Writes the corresponding pixel clock cap.
    # Idempotent; does NOT force a mode switch by itself.
    [ -e "$PCLK_NODE" ] || return 1
    local cap v
    cap=$(hz_cap_for "$1")
    [ -n "$cap" ] && [ "$cap" -gt 0 ] 2>/dev/null || cap=675000
    if [ ! -s "$LOGDIR/pclk_org" ]; then
        v=$(sed -n 's/.*org: \([0-9]\{1,\}\).*/\1/p' "$PCLK_NODE" 2>/dev/null)
        [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && echo "$v" > "$LOGDIR/pclk_org"
    fi
    echo "$cap" > "$PCLK_NODE" 2>/dev/null || return 1
    return 0
}

hz_reevaluate() {
    # Re-enumerate the DP link once so the framework re-picks a mode within
    # the current cap. Only called when the live timing exceeds the target.
    # v1.6.0: the "echo 1" half re-streams DP; never do it without external
    # power (booting on battery with the screen attached used to hit the panic).
    if ! ext_vbus_ok; then
        log "hz: re-enumeration skipped - no external VBUS ($(vbus_evidence))"
        return 1
    fi
    echo 0 > "$HPD_NODE" 2>/dev/null
    sleep 2
    # v1.11.0: this 0 -> 1 edge IS the re-enumeration lever (measured
    # 2026-11-27: hpd 1->0 tears the stream down in 1s, 0->1 brings it back in
    # 1s). Do NOT replace this with a port_type replug - that costs a USB drop
    # for no gain. The pairing only works as an edge: writing 1 at a link whose
    # HPD is already 1 does nothing (which is why v1.7.0 called it inert).
    echo 1 > "$HPD_NODE" 2>/dev/null
}

hz_boot() {
    # Apply the refresh cap early. If the link already enumerated above the
    # target (cold boot with cable attached happens before late_start
    # services), re-enumerate once so a compliant mode gets picked.
    hz_applied=$HZ_MODE
    [ "$HZ_MODE" = "auto" ] && return 0
    if apply_hz_mode "$HZ_MODE"; then
        log "hz mode: $HZ_MODE -> DP pixel clock capped at $(hz_cap_for "$HZ_MODE")kHz"
        if dp_up; then
            cur=$(dp_hz_num)
            limit=$HZ_MODE
            if [ -n "$cur" ] && [ "$cur" -gt "$limit" ] 2>/dev/null; then
                log "hz mode: link came up at $(dp_hz) (> ${limit}Hz) -> forcing re-enumeration"
                hz_reevaluate
            fi
        fi
    else
        log "hz mode: $PCLK_NODE not writable, feature unavailable"
        hz_applied=none
    fi
}
# -------------------------------------------------------

# Start screenvid if it is not running. Called once at startup and then on
# every loop iteration, so a crashed gatekeeper is restarted within seconds.
start_screenvid() {
    [ "$VIDEO_SWITCH" = "1" ] || return 0
    [ -f "$MODDIR/screenvid.sh" ] || return 0
    [ -f "$LOGDIR/video.disabled" ] && return 0
    pgrep -f 'modules/tab_dp_watchdog/screenvid.sh' >/dev/null 2>&1 && return 0
    log "screenvid not running -> starting it"
    nohup sh "$MODDIR/screenvid.sh" >/dev/null 2>&1 &
}

# Start wakegate (v1.4.0) if it is not running: screen wake gate + screen-off
# timeout enforcer. Independent of VIDEO_SWITCH - it only needs PowerManager.
start_wakegate() {
    [ -f "$MODDIR/wakegate.sh" ] || return 0
    pgrep -f 'modules/tab_dp_watchdog/wakegate[.]sh' >/dev/null 2>&1 && return 0
    log "wakegate not running -> starting it"
    nohup sh "$MODDIR/wakegate.sh" >/dev/null 2>&1 &
}

# Start otgcut (v1.9.1) if it is not running.
# This is the daemon that actually depowers the external screen when its PD
# supply disappears: it holds /sys/class/power_supply/otg/online at 0 every
# 200ms while external VBUS is absent. A single write is undone by the charger
# driver within a second, which is why the module's earlier attempts (all of
# them based on port_type) never stopped the 5V output. See otgcut.sh.
start_otgcut() {
    [ -f "$MODDIR/otgcut.sh" ] || return 0
    pgrep -f 'modules/tab_dp_watchdog/otgcut[.]sh' >/dev/null 2>&1 && return 0
    log "otgcut not running -> starting it"
    nohup sh "$MODDIR/otgcut.sh" >/dev/null 2>&1 &
}

# ---------- v1.10.0: master switch (web UI 「启用模块」) ----------
# ENABLED=0 means "hands off": the three engine daemons are stopped, every
# transient marker this module created is released and the fault engine stops
# touching the port, so stock framework behaviour takes over. Everything else
# (selected device, refresh mode, wake options) is kept in the config, so
# flipping it back on restores the previous behaviour without a reboot - and
# without the user having to redo any setting.
ENGINES="screenvid wakegate otgcut"

daemons_stop() {
    local name pat pids
    for name in $ENGINES; do
        pat="modules/tab_dp_watchdog/${name}[.]sh"
        pids=$(pgrep -f "$pat" 2>/dev/null)
        [ -z "$pids" ] && continue
        kill $pids 2>/dev/null
        log "switch: TERM -> $name ($pids)"
    done
    sleep 1
    for name in $ENGINES; do
        pat="modules/tab_dp_watchdog/${name}[.]sh"
        pgrep -f "$pat" >/dev/null 2>&1 || continue
        pkill -9 -f "$pat" 2>/dev/null
        log "switch: KILL -> $name (did not honour TERM)"
    done
}

# Undo what this module did to the port. Order matters: release the sink gate
# first (a sink-only port cannot charge, and that persists across reboots),
# then the video cut - and only raise HPD when real external power is present,
# otherwise raising it re-streams DP off the tablet's own battery (the 17:36
# panic path).
release_handoff() {
    if gate_is_on; then
        rm -f "$GATE_MARKER" "$GATE_TS" 2>/dev/null
        echo dual > "$TYPEC_PORT/port_type" 2>/dev/null
        log "switch: sink gate released -> port_type=dual (charging restored)"
    fi
    if [ -f "$LOGDIR/video_off" ]; then
        rm -f "$LOGDIR/video_off"
        echo on > "$LOGDIR/video.state" 2>/dev/null
        [ -e "$HPD_NODE" ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
        if ext_vbus_ok; then
            echo 1 > "$HPD_NODE" 2>/dev/null
            # v1.11.0: the cut left HPD at 0, so this write IS the 0->1 edge
            # that re-enables the encoder (~1s). No port_type replug here: that
            # would drop USB for nothing. Same-value writes never move a lever.
            log "switch: video_off cleared, hpd 0->1 (external VBUS present)"
        else
            log "switch: video_off cleared, HPD left LOW - no external VBUS ($(vbus_evidence))"
        fi
    fi
}

# Idempotent: logs only on a real transition, so the poll loop may call it
# every tick without spamming the log. $1 = why the state is being applied.
apply_enabled() {
    if [ "$ENABLED" = "1" ]; then
        if [ "$enabled_prev" != "1" ]; then
            log "switch: master switch ON ($1) - starting daemons"
            start_screenvid
            start_wakegate
            start_otgcut
            if [ "$HZ_MODE" != "auto" ] && [ "$hz_applied" != "$HZ_MODE" ]; then
                if apply_hz_mode "$HZ_MODE"; then
                    hz_applied=$HZ_MODE
                    log "switch: refresh cap re-applied ($HZ_MODE -> $(hz_cap_for "$HZ_MODE")kHz)"
                fi
            fi
        fi
    else
        if [ "$enabled_prev" != "0" ]; then
            log "switch: master switch OFF ($1) - stopping daemons, handing the port back to stock"
            daemons_stop
            release_handoff
            if [ "$HZ_MODE" != "auto" ]; then
                if apply_hz_mode auto; then
                    # must track it: leaving hz_applied=$HZ_MODE here made both
                    # the reload path and the ON path believe the cap was still
                    # in force, so re-enabling silently skipped the re-apply
                    hz_applied=auto
                    log "switch: pixel clock cap restored to $(pclk_org)kHz (no filtering)"
                fi
            fi
        fi
    fi
    enabled_prev=$ENABLED
}
# -------------------------------------------------------

# At boot, never leave the external screen black because a previous session
# died while the video output was cut: clear the marker and, if a partner is
# attached while the connector is off, force HPD high.
boot_video_failsafe() {
    rm -f "$LOGDIR/video_off"
    [ -e "$HPD_NODE" ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
    [ -e "$HPD_NODE" ] || return 0
    # partner dir survives even when the DP link was cut, extcon DP may read 0
    if [ ! -d /sys/class/typec/port0-partner ]; then
        grep -q 'DP=1' "$EXTCON_STATE" 2>/dev/null || return 0
    fi
    if grep -q disconnected /sys/class/drm/card0-DP-1/status 2>/dev/null; then
        if ! ext_vbus_ok; then
            # v1.6.0: booting while the screen has no PD supply. Forcing HPD
            # here would stream over the tablet's own battery - leave it down
            # and let screenvid restore once power appears.
            log "boot: link down with a partner attached but NO external VBUS ($(vbus_evidence)) - hands off: no hpd/port_type writes, kernel owns the teardown (v1.7.0)"
            return 0
        fi
        echo 1 > "$HPD_NODE" 2>/dev/null
        log "boot: DP link was down with a partner attached -> HPD forced high"
    fi
}
# -------------------------------------------------------

tp_online() {
    local d
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        if [ "$(cat "$d/idVendor" 2>/dev/null)" = "$TP_VID" ] && \
           [ "$(cat "$d/idProduct" 2>/dev/null)" = "$TP_PID" ]; then
            return 0
        fi
    done
    return 1
}

dp_up() {
    grep -q 'DP=1' "$EXTCON_STATE" 2>/dev/null
}

partner_present() {
    [ -d "$PARTNER_DIR" ]
}

virtual_replug() {
    # v1.6.0: the replug re-negotiates CC/PD/VDM/DP, i.e. it re-streams DP.
    # Without external VBUS that is the panic path - refuse instead of looping.
    if ! ext_vbus_ok; then
        log "action refused: no external VBUS ($(vbus_evidence)) - a replug would re-stream DP on the tablet's own 5V"
        return 1
    fi
    # v1.8.0: while the sink gate is up the port is deliberately sink-only. A
    # replug would write dual, hand the Source capability back and let the
    # tablet feed the screen again - the whole point of the gate.
    if gate_is_on; then
        log "action refused: sink gate engaged (screen has no PD supply) - releasing the gate first"
        return 1
    fi
    log "action: virtual replug (port_type sink -> dual)"
    if ! echo sink > "$TYPEC_PORT/port_type" 2>/dev/null; then
        log "error: cannot write sink to $TYPEC_PORT/port_type"
        return 1
    fi
    sleep 2
    if ! echo dual > "$TYPEC_PORT/port_type" 2>/dev/null; then
        log "error: cannot write dual to $TYPEC_PORT/port_type (port left in sink mode!)"
        return 1
    fi
    local i=0
    while [ $i -lt 15 ]; do
        dp_up && { log "success: DP=1, link restored"; return 0; }
        sleep 1
        i=$((i + 1))
    done
    log "fail: DP still down after replug attempt"
    return 1
}

MODVER=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
[ -n "$MODVER" ] || MODVER=unknown
log "===== service $MODVER started (poll=${POLL_SEC}s, vid:pid=$TP_VID:$TP_PID, hz=${HZ_MODE}, wake_gate=${WAKE_GATE}/${WAKE_GATE_TOUCH}, timeout_enforce=${TIMEOUT_ENFORCE}, enabled=${ENABLED}) ====="
enabled_prev=-1
if [ "$ENABLED" = "1" ]; then
    boot_video_failsafe
    hz_boot
else
    log "switch: master switch is OFF in config - boot failsafe and refresh cap skipped, daemons not started"
fi
apply_enabled "startup"
sleep "$BOOT_DELAY"

strike=0
episode_done=0
ever_dp_up=0
vbus_blocked=0

while true; do
    sleep "$POLL_SEC"

    # heartbeat for the mutual supervision with screenvid
    date +%s > "$LOGDIR/hb.main"

    # hot-reload config FIRST: a switch flipped in the web UI has to take
    # effect in this tick, because daemon supervision below depends on it.
    if [ -f "$LOGDIR/config" ]; then
        mt=$(date -r "$LOGDIR/config" +%s 2>/dev/null || echo 0)
        if [ "$mt" != "$cfg_mtime" ]; then
            cfg_mtime=$mt
            . "$LOGDIR/config" 2>/dev/null
            case "$HZ_MODE" in
                60|120|auto) ;;
                *) HZ_MODE=60 ;;
            esac
            # v1.10.0: re-validate the master switch on every reload - a typo
            # must fall back to "on", never to a state no daemon understands.
            case "$ENABLED" in
                0|1) ;;
                *) ENABLED=1 ;;
            esac
            log "config reloaded: vid:pid=$TP_VID:$TP_PID poll=${POLL_SEC}s hz=$HZ_MODE wake_gate=${WAKE_GATE}/${WAKE_GATE_TOUCH} timeout_enforce=${TIMEOUT_ENFORCE} enabled=$ENABLED"
            strike=0
            # reconcile the refresh cap with the kernel. The web CGI applies
            # the cap AND the re-enumeration itself before saving the config,
            # so this only needs to mirror manual config edits: the kernel
            # write is idempotent, no mode switch is forced here.
            if [ "$ENABLED" = "1" ] && [ "$HZ_MODE" != "$hz_applied" ]; then
                if apply_hz_mode "$HZ_MODE"; then
                    hz_applied=$HZ_MODE
                    log "hz mode: $HZ_MODE (cap $(hz_cap_for "$HZ_MODE")kHz)"
                fi
            fi
        fi
    fi

    apply_enabled "config"

    # Master switch off: the module must be a pure observer. No port writes, no
    # fault recovery, no daemon supervision - just keep the heartbeat and keep
    # watching the config, so flipping the switch back on resumes everything.
    if [ "$ENABLED" != "1" ]; then
        continue
    fi

    start_screenvid
    start_wakegate
    start_otgcut

    # ---- v1.8.0: sink-gate safety net ----
    # A sink-only port cannot charge. If VBUS is present while the gate marker
    # is still up (screenvid died mid-episode, or the PD came back between two
    # of its polls) release it here: charging and DP matter more than the gate.
    if gate_is_on; then
        if ext_vbus_ok; then
            gate_back=$(( ${gate_back:-0} + 1 ))
            if [ "$gate_back" -ge 2 ]; then
                gate_back=0
                gate_release "external VBUS is present (service safety net)"
            fi
        else
            gate_back=0
        fi
    else
        gate_back=0
    fi

    # Video output intentionally cut (screen off, handled by screenvid):
    # DP=0 is expected here, so do NOT run fault recovery. If the marker is
    # stale (gatekeeper gone), clear it and restore the link ourselves.
    if [ -f "$LOGDIR/video_off" ]; then
        vage=999
        [ -f "$LOGDIR/hb.video" ] && \
            vage=$(( $(date +%s) - $(stat -c %Y "$LOGDIR/hb.video" 2>/dev/null || echo 0) ))
        if [ "$vage" -lt 120 ]; then
            continue
        fi
        # v1.3.1: an old heartbeat is NOT proof the gatekeeper died. While the
        # tablet is suspended the watchdog daemons are frozen too (shell sleep
        # runs on monotonic time), so hb.video ages in wall-clock time on every
        # Doze suspend/resume cycle. Only treat the marker as stale when the
        # screen is actually awake; while asleep, self-heal the heartbeat and
        # keep the video cut (that is the desired state with the screen off).
        wakefulness=$(dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -n 1)
        case "$wakefulness" in
            Asleep|Dozing)
                date +%s > "$LOGDIR/hb.video"
                log "video_off marker kept: hb aged ${vage}s but screen ${wakefulness} (suspend freeze) - hb self-healed"
                continue
                ;;
        esac
        log "video_off marker stale (${vage}s, screen ${wakefulness:-unknown}) -> clearing, restoring video"
        rm -f "$LOGDIR/video_off"
        if ext_vbus_ok; then
            # v1.7.0: hpd=1 only re-configures an already-connected link; it does
            # not re-enable the encoder (measured). Recovery belongs to
            # screenvid's ladder (port_type replug -> hpd -> screen bounce), so
            # do not poke hpd here - a stray poke is what broke the picture.
            log "  (marker cleared; screenvid owns the re-enable - no hpd poke)"
        else
            log "  (HPD left LOW: no external VBUS - $(vbus_evidence))"
        fi
        continue
    fi

    if dp_up; then
        ever_dp_up=1
        if [ "$strike" -gt 0 ]; then
            log "state: link healthy again before action"
        fi
        strike=0
        episode_done=0
        continue
    fi

    # DP is down. Classify:
    #   Fault A (v1.0.0): touchscreen online but DP down  -> recoverable
    #   Fault B (v1.1.0): DP was up this session, port wedged:
    #                      partner present/flickering, no stable attach
    #   No target: touch absent AND partner absent (and never had DP)
    #              -> nothing to fix, stay quiet
    if tp_online; then
        fault=A
    elif [ "$ever_dp_up" = "1" ] && partner_present; then
        fault=B
    else
        strike=0
        episode_done=0
        continue
    fi

    if [ "$episode_done" = "1" ]; then
        continue
    fi

    # ---- v1.6.0: hold the recovery engine while external power is missing ---
    # Fault A/B with no VBUS means the tablet is Source and feeding the screen
    # from its battery. Retrying here would burn the 100s retry ladder on a
    # hopeless (and dangerous) replug, so wait for the PD supply instead.
    if ! ext_vbus_ok; then
        if [ "$vbus_blocked" != "1" ]; then
            vbus_blocked=1
            log "fault $fault held: no external VBUS ($(vbus_evidence)) - recovery disarmed until the screen's PD supply is back"
        fi
        strike=0
        continue
    fi
    if [ "$vbus_blocked" = "1" ]; then
        vbus_blocked=0
        vbus_ready=$(( $(date +%s) + PD_SETTLE ))
        log "external VBUS back - recovery re-armed in ${PD_SETTLE}s (PD contract settling)"
    fi
    # v1.7.0: never strike while the PD contract is still being re-negotiated.
    # A replug injected into that window is exactly what left the sink black
    # (status=enabled, pclock=0) on 2026-11-26 19:18 with v1.6.0.
    if [ "${vbus_ready:-0}" != "0" ]; then
        if [ "$(date +%s)" -lt "${vbus_ready:-0}" ]; then
            strike=0
            continue
        fi
        vbus_ready=0
    fi

    strike=$((strike + 1))
    [ "$strike" -lt "$STRIKES" ] && continue

    log "fault $fault: DP=0 (strike $strike, ever_dp_up=$ever_dp_up)"
    attempt=0
    while [ $attempt -lt "$MAX_RETRY" ]; do
        virtual_replug && break
        attempt=$((attempt + 1))
        log "retry $attempt/$MAX_RETRY in $((attempt * 10))s"
        sleep $((attempt * 10))
    done

    if dp_up; then
        log "episode resolved after $((attempt + 1)) attempt(s)"
    else
        log "episode unresolved after $MAX_RETRY attempts, waiting for state change"
    fi
    episode_done=1
    strike=0
done
