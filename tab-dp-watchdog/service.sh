#!/system/bin/sh
# Tab S7 DP Link Watchdog v1.5.0 - service entry
# Runs as root (u:r:magisk:s0) at late_start service mode.
#
# v1.5.0: external VBUS guard (kernel panic fix).
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
VBUS_GUARD=1           # v1.5.0: 1 = never force HPD high without external VBUS
# --------------------------------------------------------------------

[ -f "$LOGDIR/config" ] && . "$LOGDIR/config"
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

# ---------- v1.5.0: external VBUS guard ----------
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
    # v1.5.0: the "echo 1" half re-streams DP; never do it without external
    # power (booting on battery with the screen attached used to hit the panic).
    if ! ext_vbus_ok; then
        log "hz: re-enumeration skipped - no external VBUS ($(vbus_evidence))"
        return 1
    fi
    echo 0 > "$HPD_NODE" 2>/dev/null
    sleep 2
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
            # v1.5.0: booting while the screen has no PD supply. Forcing HPD
            # here would stream over the tablet's own battery - leave it down
            # and let screenvid restore once power appears.
            log "boot: link down with a partner attached but NO external VBUS ($(vbus_evidence)) - HPD left LOW (v1.5.0 guard)"
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
    # v1.5.0: the replug re-negotiates CC/PD/VDM/DP, i.e. it re-streams DP.
    # Without external VBUS that is the panic path - refuse instead of looping.
    if ! ext_vbus_ok; then
        log "action refused: no external VBUS ($(vbus_evidence)) - a replug would re-stream DP on the tablet's own 5V"
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
log "===== service $MODVER started (poll=${POLL_SEC}s, vid:pid=$TP_VID:$TP_PID, hz=${HZ_MODE}, wake_gate=${WAKE_GATE}/${WAKE_GATE_TOUCH}, timeout_enforce=${TIMEOUT_ENFORCE}) ====="
boot_video_failsafe
hz_boot
start_screenvid
start_wakegate
sleep "$BOOT_DELAY"

strike=0
episode_done=0
ever_dp_up=0
vbus_blocked=0

while true; do
    sleep "$POLL_SEC"

    # heartbeat for the mutual supervision with screenvid
    date +%s > "$LOGDIR/hb.main"
    start_screenvid
    start_wakegate

    # hot-reload config if it changed (e.g. saved from the web UI)
    if [ -f "$LOGDIR/config" ]; then
        mt=$(date -r "$LOGDIR/config" +%s 2>/dev/null || echo 0)
        if [ "$mt" != "$cfg_mtime" ]; then
            cfg_mtime=$mt
            . "$LOGDIR/config" 2>/dev/null
            case "$HZ_MODE" in
                60|120|auto) ;;
                *) HZ_MODE=60 ;;
            esac
            log "config reloaded: vid:pid=$TP_VID:$TP_PID poll=${POLL_SEC}s hz=$HZ_MODE wake_gate=${WAKE_GATE}/${WAKE_GATE_TOUCH} timeout_enforce=${TIMEOUT_ENFORCE}"
            strike=0
            # reconcile the refresh cap with the kernel. The web CGI applies
            # the cap AND the re-enumeration itself before saving the config,
            # so this only needs to mirror manual config edits: the kernel
            # write is idempotent, no mode switch is forced here.
            if [ "$HZ_MODE" != "$hz_applied" ]; then
                hz_applied=$HZ_MODE
                apply_hz_mode "$HZ_MODE" && \
                    log "hz mode: $HZ_MODE (cap $(hz_cap_for "$HZ_MODE")kHz)"
            fi
        fi
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
            [ -e "$HPD_NODE" ] && echo 1 > "$HPD_NODE" 2>/dev/null
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

    # ---- v1.5.0: hold the recovery engine while external power is missing ---
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
        log "external VBUS back - recovery re-armed"
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
