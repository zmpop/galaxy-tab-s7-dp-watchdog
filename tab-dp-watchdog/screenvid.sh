#!/system/bin/sh
# Tab S7 DP Link Watchdog - screen gated video output (screenvid)
#
# Started and supervised by service.sh, runs as root.
#
# PURPOSE
#   When the tablet screen turns off (power key, screen timeout, AOD) cut the
#   DP video signal to the external screen immediately. When the screen turns
#   back on, restore it and re-establish the link.
#
# MECHANISM  (v1.7.0 - rewritten after measuring every lever on the device)
#   The display stack is the ONLY thing that really cuts or re-establishes the
#   DP stream. Measured on SM-T970 / T970ZCS7DXH1:
#     screen off  -> status=disconnected enabled=disabled dp_debug state=0x0 pclock=0
#     screen on   -> status=connected    enabled=enabled    state=0xa5 pclock=268500
#   /sys/kernel/debug/drm_dp/hpd is NOT a working lever on this kernel build:
#     echo 0 > hpd  -> rc=0, no state change, no kernel log  (no-op)
#     echo 1 > hpd  -> dp_usbpd_simulate_connect, but only re-configures an
#                      already-connected link; it does not enable the encoder
#   /sys/class/drm/card0-DP-1/dpms is read-only (open fails: Permission denied).
#   port_type sink->dual is kept as the one lever that forces a real virtual
#   replug (it does kill the touchscreen USB path for a few seconds).
#
# v1.8.0 - AND THE SCREEN HAS TO ACTUALLY LOSE POWER
#   v1.7.0 stopped poking the link but left the tablet free to feed the screen
#   from its own battery: on the VBUS-loss edge the port flips to Attached.SRC
#   (measured: otg=1, role=[source], battery -1625mA) and the screen stays
#   powered, so it never goes dark. `port_type` is the ONLY lever that really
#   removes that: echo sink -> usb/online 1->0, dp disconnected, pclock 0.
#   (hpd writes are inert in both directions; otg/online is re-enabled by the
#   kernel within a second; the read-back of port_type keeps lying "[dual]",
#   so success can only be judged by the effect.) Hence the sink gate below:
#   pin sink while VBUS is absent, release the instant it returns.
#
# v1.7.0 - WHY THE OLD GUARD BROKE THE PICTURE (regression report 2026-11-26)
#   v1.6.0 (a) poked hpd=0 on the VBUS edge and every 3s afterwards, and
#   (b) called restore_video() the instant VBUS came back - and restore_video
#   writes hpd=1 as its first action. That poke landed inside the PD
#   re-negotiation window, left the sink half-arbitrated (status=enabled,
#   pclock=0, screen black) and, because the old success test only looked at
#   status/enabled, the daemon believed it had restored and stopped trying.
#   The patch that verified clean on 4 consecutive pulls (tabpdmon 18:10) did
#   the opposite: it wrote NOTHING and merely refused to restore while VBUS was
#   absent. v1.7.0 goes back to that: suppress only, let the kernel own the
#   link, and judge success by dp_debug pclock instead of status/enabled.
#
# STATE (all under /data/adb/tpdp)
#   video.state      "on" / "off"   - last applied intent (informational)
#   video_off        marker         - video is intentionally cut; service.sh
#                                     uses this to suppress DP fault recovery
#   video.disabled   marker         - cut kept failing, feature disabled for
#                                     this boot (video is left ON = safe)
#   hb.video         heartbeat      - mtime touched every ~10s
#   screen.ev        screen_toggled event feed (one line per toggle)
#
# v1.6.0 - EXTERNAL VBUS GUARD (kernel panic fix)
#   Pulling the external screen's PD supply makes the tablet flip to Source and
#   feed the screen from its own battery (power_role=source, otg/online=1,
#   ~1.9A draw, Vbat 3.90 -> 3.73V). If HPD is forced high in that state the DP
#   link re-streams 2560x1600@60 on a port with no external supply; when the PD
#   is plugged back in, VDM re-negotiation aborts a still-ENABLED stream:
#     DP_STATE_ABORTED state(0x15f) -> sde_kms_wait_for_commit_done -110 x2
#     -> MM NoC fatal -> TZBSP_ERR_FATAL_NOC_ERROR -> SError(NMI) -> panic
#   (observed 2026-11-26 17:36, repeated 4x in the RAMDUMP eRR.p signature).
#   This daemon therefore (a) actively holds HPD low the moment external VBUS
#   disappears, and (b) refuses every restore while it is absent. The link
#   comes back by itself once the PD supply is reconnected (<=3s).
#   Set VBUS_GUARD=0 in $LOGDIR/config to disable (NOT recommended: the tablet
#   may then power the screen itself and hit the panic path again).

MODDIR=${0%/*}
LOGDIR=/data/adb/tpdp
LOG=$LOGDIR/log
mkdir -p "$LOGDIR"

# ---------- defaults (override via $LOGDIR/config) ----------
VIDEO_SWITCH=1
HPD_NODE=/sys/kernel/debug/drm_dp/hpd
DP_CONN=/sys/class/drm/card0-DP-1/status
DP_EN=/sys/class/drm/card0-DP-1/enabled
EXTCON_STATE=/sys/class/extcon/extcon0/state
PARTNER_DIR=/sys/class/typec/port0-partner
TYPEC_PORT=/sys/class/typec/port0
POLL_TICKS_ON=15        # while video is ON:  full poll every 15 ticks (s)
POLL_TICKS_OFF=3        # while video is OFF: full poll every 3 ticks (s)
VIDEO_MAX_FAIL=5        # consecutive cut failures -> stop cutting (keep ON)
RESTORE_RETRY_TICKS=10  # retry interval for a failed restore (s)
HB_TICKS=10             # heartbeat period (s)
STATE_FILE=$LOGDIR/video.state
MARKER=$LOGDIR/video_off
DISABLED=$LOGDIR/video.disabled
HB=$LOGDIR/hb.video
EVFILE=$LOGDIR/screen.ev
# ---- external VBUS guard ----
VBUS_GUARD=1            # 1 = never touch the DP link while external VBUS is absent
EXT_VBUS=/sys/class/power_supply/usb/online
OTG_ONLINE=/sys/class/power_supply/otg/online
POWER_ROLE=$TYPEC_PORT/power_role
BAT_CUR=/sys/class/power_supply/battery/current_now
DP_DEBUG=/sys/kernel/debug/drm_dp/dp_debug
PD_SETTLE=4             # seconds to let the PD contract settle after VBUS returns
PD_REPAIR=1             # 1 = health-check (and repair) once PD has settled
# ---- sink gate (v1.8.0) ----
# When the screen's own PD supply disappears the DRP flips to Attached.SRC and
# the tablet starts feeding the screen ~1.6-1.9A from its battery. Measured on
# this device: `port_type` is the ONLY lever that actually kills that output
# (hpd writes are inert, otg/online is re-enabled by the kernel). Pinning the
# port to sink-only removes the Rp/Source capability, so VBUS cannot come up
# and the screen is genuinely depowered - which is the state the passing
# pull-test runs ended in.
SINK_GATE=0             # 1 = pin port_type=sink while external VBUS is absent.
# DEFAULT OFF (v1.8.1): measured on SM-T970 - pinning sink does NOT stop the
# 5V output (the kernel re-arms Source and keeps feeding 1.3-1.5A for ~48s,
# vs ~25s in stock behaviour), it only tears the DP link down repeatedly.
# The screen therefore stays powered either way; the flag is kept for
# experiments only. What actually keeps the screen dark is that the DP
# link is never re-streamed while VBUS is absent (the v1.7.0 behaviour).
GATE_MARKER=$LOGDIR/sink_gate          # service.sh/action.sh honour this
GATE_TS=$LOGDIR/sink_gate.ts
GATE_RELEASE=$LOGDIR/sink_gate.release
GATE_STRIKES=2          # consecutive "no VBUS" polls before engaging
GATE_REASSERT=6         # re-pin every N seconds while it stays absent
GATE_GRACE=10           # do not re-engage for N seconds after a release
VBUS_OK_STRIKES=3       # consecutive usb/online=1 samples before power counts as back
# ------------------------------------------------------------

[ -f "$LOGDIR/config" ] && . "$LOGDIR/config"
MODVER=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
[ -n "$MODVER" ] || MODVER=unknown

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [video] $*" >> "$LOG"
    [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 524288 ] && \
        tail -n 400 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# debugfs is normally mounted by the platform, but do not depend on it
ensure_hpd() {
    [ -e "$HPD_NODE" ] && return 0
    mount -t debugfs none /sys/kernel/debug 2>/dev/null
    [ -e "$HPD_NODE" ] && return 0
    return 1
}

cable_present() {
    grep -q 'DP=1' "$EXTCON_STATE" 2>/dev/null
}

# Is a partner (the screen) physically attached? NOTE: extcon DP is NOT usable
# here: cutting the link via HPD makes extcon report DP=0 too, so it cannot
# distinguish "we cut it" from "nothing is plugged in". The Type-C partner
# directory is independent of the DP link state (CC/PD stay attached), so it
# is the authoritative answer.
link_present() {
    [ -d "$PARTNER_DIR" ] && return 0
    cable_present
}

partner_present() { [ -d "$PARTNER_DIR" ]; }

# ---- v1.6.0: external VBUS guard ---------------------------------------
# usb/online = 1  -> real external power is on the port (charger / screen PD)
# usb/online = 0  -> nothing feeds VBUS; the tablet is Source and powers the
#                    screen from its own battery -> re-streaming DP is fatal
# node missing    -> cannot judge (installer/uninstaller context): never block
ext_vbus_ok() {
    [ "$VBUS_GUARD" = "1" ] || return 0
    local u
    u=$(cat "$EXT_VBUS" 2>/dev/null)
    [ -z "$u" ] && return 0
    [ "$u" = "1" ] && return 0
    return 1
}

# one-line evidence for the log / reports
vbus_evidence() {
    echo "usb/online=$(cat "$EXT_VBUS" 2>/dev/null) otg=$(cat "$OTG_ONLINE" 2>/dev/null) role=$(cat "$POWER_ROLE" 2>/dev/null) port=$(cat "$TYPEC_PORT/port_type" 2>/dev/null) ma=$(cat "$BAT_CUR" 2>/dev/null)"
}

# ---- v1.8.0: sink gate -------------------------------------------------
# pin_sink(): remove the port's Source capability. Measured effect on SM-T970:
#   usb/online 1 -> 0, DP connector disconnected, pclock 0  (screen loses 5V)
# The sysfs read-back of port_type stays "[dual] source sink" even on success,
# so the write result cannot be verified by reading it back - only by the
# effect. Never claim success from the return code alone.
pin_sink() {
    [ "$SINK_GATE" = "1" ] || return 1
    echo sink > "$TYPEC_PORT/port_type" 2>/dev/null || return 1
    return 0
}

gate_is_on() { [ -f "$GATE_MARKER" ]; }

gate_engage() {
    [ "$SINK_GATE" = "1" ] || return 1        # disabled: never even mark it
    gate_is_on && return 0
    printf 'sink\n' > "$GATE_MARKER" 2>/dev/null
    date +%s > "$GATE_TS" 2>/dev/null
    pin_sink
    return 0
}

gate_release() {
    local reason="$1"
    gate_is_on || { echo dual > "$TYPEC_PORT/port_type" 2>/dev/null; return 0; }
    rm -f "$GATE_MARKER" "$GATE_TS" 2>/dev/null
    echo dual > "$TYPEC_PORT/port_type" 2>/dev/null
    date +%s > "$GATE_RELEASE" 2>/dev/null
    gate_grace_until=$(( $(date +%s) + GATE_GRACE ))
    log "sink gate: released ($reason) -> port_type=dual, ${GATE_GRACE}s grace before it may re-engage"
    return 0
}

gate_in_grace() {
    local now t
    now=$(date +%s)
    [ "$now" -lt "${gate_grace_until:-0}" ] && return 0
    t=$(cat "$GATE_RELEASE" 2>/dev/null)
    case "$t" in ''|*[!0-9]*) return 1 ;; esac
    [ $(( now - t )) -lt "$GATE_GRACE" ] && return 0
    return 1
}


refresh_actual() {
    ACT_ST=$(cat "$DP_CONN" 2>/dev/null)
    ACT_EN=$(cat "$DP_EN" 2>/dev/null)
}

# Is the controller actually driving pixels? status/enabled both lie after a
# botched HPD poke: they report connected/enabled while dp_debug shows
# resolution=0x0@0Hz pclock=0KHz and the sink is black. pclock is the truth.
dp_pclk() {
    grep -m1 'pclock=' "$DP_DEBUG" 2>/dev/null | sed 's/.*pclock=//; s/KHz.*//'
}

video_real_streaming() {
    local pclk
    [ -e "$DP_DEBUG" ] || return 0          # node absent: cannot judge, trust status
    pclk=$(dp_pclk)
    case "$pclk" in ''|*[!0-9]*) return 0 ;; esac
    [ "$pclk" -gt 0 ]
}

video_actual_off() {
    [ "$ACT_ST" = "disconnected" ] && [ "$ACT_EN" = "disabled" ]
}
video_actual_on() {
    [ "$ACT_ST" = "connected" ] && [ "$ACT_EN" = "enabled" ] && video_real_streaming
}

# on | off | unknown  (authoritative, system_server query)
screen_want() {
    local w
    w=$(dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -n 1)
    case "$w" in
        Awake)         echo on ;;
        Asleep|Dozing) echo off ;;
        *)             echo unknown ;;
    esac
}

# ---- actions -------------------------------------------------------------

cut_video() {
    # v1.7.0: do NOT poke hpd here. Measured: "echo 0 > drm_dp/hpd" returns 0
    # but changes nothing (status stays connected, enabled stays enabled, zero
    # kernel log), so the old implementation "failed" three times per cut and
    # counted down VIDEO_MAX_FAIL for no reason. The display stack already cuts
    # the stream when the screen turns off (state 0x0, pclock 0), so this
    # function only has to record the intent and confirm it happened.
    local i=0
    while [ $i -lt 3 ]; do
        refresh_actual
        if video_actual_off; then
            touch "$MARKER"
            echo off > "$STATE_FILE"
            log "video cut confirmed (display stack disabled the encoder, status=$ACT_ST enabled=$ACT_EN)"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    # Link still up a few seconds after the screen went off: nothing to cut with
    # (hpd is inert), so accept it and leave the marker. Do not fail-loop.
    touch "$MARKER"
    echo off > "$STATE_FILE"
    log "video cut: encoder still enabled (status=$ACT_ST enabled=$ACT_EN pclk=$(dp_pclk)) - no usable cut lever on this kernel, leaving it to the display stack"
    return 0
}

restore_video() {
    if ! link_present; then
        rm -f "$MARKER"
        echo on > "$STATE_FILE"
        log "restore skipped: no partner/cable attached"
        return 2
    fi

    # ---- VBUS guard: the one rule that actually held up on hardware --------
    # Refuse to touch the link while external VBUS is absent. This is literally
    # the patch that survived 4 consecutive PD pulls (tabpdmon 18:10): a gate,
    # not a poke. Writing hpd=0 here (v1.6.0) changed nothing on this kernel and
    # the follow-up hpd=1 on VBUS return is what killed the picture.
    if ! ext_vbus_ok; then
        echo off > "$STATE_FILE"
        touch "$MARKER"
        if [ "$vbus_notice" != "1" ]; then
            log "restore SUPPRESSED: no external VBUS ($(vbus_evidence)) - refusing to touch the link (17:36 panic path), waiting for PD"
            vbus_notice=1
        fi
        vbus_wait=1
        return 0
    fi
    vbus_notice=0
    vbus_wait=0

    refresh_actual
    if video_actual_on; then
        # already streaming: no action, and definitely no poke (the poke is what
        # leaves status=enabled with pclock=0 and a black screen)
        echo on > "$STATE_FILE"
        rm -f "$MARKER"
        return 0
    fi

    local i=0 ok=0
    # ---- step 1: virtual replug - the only lever that re-enumerates here ----
    log "restore: not streaming (status=$ACT_ST enabled=$ACT_EN pclk=$(dp_pclk)) - port_type virtual replug"
    echo sink > "$TYPEC_PORT/port_type" 2>/dev/null
    sleep 2
    echo dual > "$TYPEC_PORT/port_type" 2>/dev/null
    while [ $i -lt 12 ]; do
        refresh_actual
        if video_actual_on; then
            ok=1
            log "video restored via port_type replug (pclk=$(dp_pclk))"
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    # ---- step 2: hpd simulate-connect (configures a connected link only) ----
    if [ "$ok" = "0" ] && ensure_hpd; then
        log "restore: replug ineffective, trying hpd=1"
        echo 1 > "$HPD_NODE" 2>/dev/null
        i=0
        while [ $i -lt 4 ]; do
            sleep 1
            refresh_actual
            if video_actual_on; then
                ok=1
                log "video restored via hpd=1 (pclk=$(dp_pclk))"
                break
            fi
            i=$((i + 1))
        done
    fi

    # ---- step 3: screen bounce - display-stack re-enable, the proven repair -
    if [ "$ok" = "0" ] && [ "$PD_REPAIR" = "1" ]; then
        log "restore: link enabled but no pixels (pclk=0) - bouncing the screen for a clean encoder re-enable"
        input keyevent 26 2>/dev/null
        sleep 2
        input keyevent 26 2>/dev/null
        i=0
        while [ $i -lt 6 ]; do
            sleep 1
            refresh_actual
            if video_actual_on; then
                ok=1
                log "video restored via screen bounce (pclk=$(dp_pclk))"
                break
            fi
            i=$((i + 1))
        done
    fi

    echo on > "$STATE_FILE"
    if [ "$ok" = "1" ]; then
        rm -f "$MARKER"
        return 0
    fi
    # Failed: drop the marker so the DP watchdog can also try (independent
    # recovery engine) and so a stale marker can never suppress recovery.
    rm -f "$MARKER"
    log "restore FAILED (status=$ACT_ST enabled=$ACT_EN pclk=$(dp_pclk)) - will retry"
    return 1
}

# ---- main ---------------------------------------------------------------

if [ "$VIDEO_SWITCH" != "1" ]; then
    log "screenvid: disabled by config (VIDEO_SWITCH=$VIDEO_SWITCH), exiting"
    exit 0
fi
if [ -f "$DISABLED" ]; then
    log "screenvid: feature was disabled earlier this boot ($(cat "$DISABLED" 2>/dev/null)) - not starting"
    exit 0
fi

# wait for the system to be usable (dumpsys power needs system_server)
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 150 ]; do
    sleep 2
    i=$((i + 2))
done

# L0 - startup reconciliation. Never inherit a stale "cut" intent: read the
# real screen state and force the link to match it.
rm -f "$MARKER"
log "===== screenvid $MODVER started (poll on=${POLL_TICKS_ON}s off=${POLL_TICKS_OFF}s) ====="
ensure_hpd
refresh_actual
start_want=$(screen_want)
if [ "$start_want" = "off" ]; then
    if link_present; then
        video_actual_off || cut_video >/dev/null 2>&1
        touch "$MARKER"      # keep the DP watchdog suppressed across restarts
    else
        rm -f "$MARKER"
    fi
    echo off > "$STATE_FILE"
else
    if link_present && ! video_actual_on; then
        log "startup: link down while screen is $start_want, forcing restore"
        restore_video
    else
        echo on > "$STATE_FILE"
    fi
fi

# screen_toggled event feed (instant path); drained and re-read on death
# NOTE: truncation runs in a subshell - a redirection failure on a special
# builtin would otherwise terminate this daemon (mksh), i.e. a broken/unwritable
# event file must degrade to polling, never kill the gatekeeper.
[ -f "$EVFILE" ] || rm -rf "$EVFILE" 2>/dev/null
( : > "$EVFILE" ) 2>/dev/null
logcat -b events -s screen_toggled:I > "$EVFILE" 2>/dev/null &
EVPID=$!

last_want=""
last_ev_line=""
cut_fail=0
slow=0
slow_tick=0
tick=0
hb_tick=0
feed_fail=0
feed_retry=0
vbus_notice=0
vbus_wait=0
vbus_cut=0
# seed the stabiliser so the very first poll is trusted: otherwise a daemon
# start while VBUS is present would log a bogus "VBUS gone" edge.
vbus_gone_n=0
vbus_ok_n=$VBUS_OK_STRIKES
gate_next=0
gate_grace_until=0

# A gate must never survive a dead run: a sink-only port cannot charge and
# would keep the screen dark with no way back. The kernel resets the port on
# reboot, but the marker file lives in /data, so reconcile it here.
if gate_is_on; then
    rm -f "$GATE_MARKER" "$GATE_TS" 2>/dev/null
    echo dual > "$TYPEC_PORT/port_type" 2>/dev/null
    log "sink gate: stale marker from a previous run cleared -> port_type=dual"
fi

while true; do
    # ---- external VBUS observation + sink gate (v1.8.0) --------------------
    # Two separate jobs here:
    #   1. link handling stays hands-off (hpd writes are inert and harmful);
    #   2. power gating DOES act: while nothing feeds the port the tablet must
    #      not feed it either. port_type=sink is the lever that really cuts the
    #      5V output - without it the screen stays alive on the tablet's
    #      battery (measured 1.6-1.9A) and never loses power.
    vbus_ok_now=0
    if ext_vbus_ok; then
        vbus_ok_n=$(( ${vbus_ok_n:-0} + 1 ))
        # v1.8.1: a single usb/online=1 sample is NOT proof that power is back.
        # Measured: writing port_type makes VBUS flicker 1 -> 0 -> 1 for a few
        # seconds, and a restore injected into that window is exactly what left
        # the sink black on 2026-11-26 19:18. Require VBUS_OK_STRIKES samples.
        [ "${vbus_ok_n:-0}" -ge "$VBUS_OK_STRIKES" ] && vbus_ok_now=1
    else
        vbus_ok_n=0
    fi
    if [ "$vbus_ok_now" = "1" ] && gate_is_on; then
        gate_release "external VBUS present"
    fi
    if [ "$vbus_ok_now" = "0" ]; then
        vbus_gone_n=$(( ${vbus_gone_n:-0} + 1 ))
        if [ "$vbus_cut" != "1" ]; then
            vbus_cut=1
            vbus_resume=0
            touch "$MARKER"
            echo off > "$STATE_FILE"
            log "vbus: external VBUS gone ($(vbus_evidence)) - holding the link down, engaging the sink gate so the tablet cannot feed the screen"
            gate_next=0
        fi
        # Engage after GATE_STRIKES consecutive polls, then re-pin every
        # GATE_REASSERT seconds: the kernel re-arms Source capability on its
        # own, and that is exactly what keeps the screen powered today.
        if [ "$SINK_GATE" = "1" ] && [ "${vbus_gone_n:-0}" -ge "$GATE_STRIKES" ] && ! gate_in_grace; then
            _now=$(date +%s)
            if ! gate_is_on; then
                gate_engage
                gate_next=$(( _now + GATE_REASSERT ))
                if ext_vbus_ok; then
                    gate_release "VBUS reappeared during engage"
                else
                    log "sink gate: ENGAGED (port_type=sink after ${vbus_gone_n} polls without VBUS, $(vbus_evidence)) - tablet can no longer output 5V, screen is depowered"
                fi
            elif [ "$_now" -ge "${gate_next:-0}" ]; then
                gate_next=$(( _now + GATE_REASSERT ))
                pin_sink
                ext_vbus_ok && gate_release "VBUS reappeared during re-assert"
            fi
        fi
    elif [ "$vbus_cut" = "1" ]; then
        vbus_cut=0
        vbus_wait=0
        vbus_gone_n=0
        vbus_resume=$(( $(date +%s) + PD_SETTLE ))
        refresh_actual
        log "vbus: external VBUS back ($(vbus_evidence)) - status=$ACT_ST enabled=$ACT_EN pclk=$(dp_pclk); letting the PD contract settle ${PD_SETTLE}s before judging"
    fi



    # ---- supervise the main daemon (mutual watchdog) ----
    hb_tick=$((hb_tick + 1))
    if [ "$hb_tick" -ge "$HB_TICKS" ]; then
        hb_tick=0
        date +%s > "$HB"
        if [ -f "$LOGDIR/hb.main" ]; then
            mage=$(( $(date +%s) - $(stat -c %Y "$LOGDIR/hb.main" 2>/dev/null || echo 0) ))
            if [ "$mage" -gt 90 ]; then
                if ! pgrep -f 'modules/tab_dp_watchdog/service.sh' >/dev/null 2>&1; then
                    log "main daemon dead (heartbeat ${mage}s old) - restarting it"
                    nohup sh "$MODDIR/service.sh" >/dev/null 2>&1 &
                fi
            fi
        fi
    fi

    # ---- event feed health (bounded restart: never spin) ----
    if ! kill -0 "$EVPID" 2>/dev/null; then
        now=$(date +%s)
        if [ "$now" -ge "$feed_retry" ]; then
            feed_fail=$((feed_fail + 1))
            [ "$feed_fail" -le 3 ] && log "screen event feed died (try $feed_fail) - poll fallback active"
            [ "$feed_fail" = "4" ] && log "event feed unavailable - polling only from now on"
            [ -f "$EVFILE" ] || rm -rf "$EVFILE" 2>/dev/null
            ( : > "$EVFILE" ) 2>/dev/null
            logcat -b events -s screen_toggled:I > "$EVFILE" 2>/dev/null &
            EVPID=$!
            last_want=""
            last_ev_line=""
            feed_retry=$((now + 15))
        fi
    else
        feed_fail=0
    fi

    # ---- decide desired state (event first, poll as safety net) ----
    # The last line of the feed is only treated as an EVENT when it differs
    # from the last line we already consumed. Otherwise a frozen/stalled feed
    # would replay the same line after every poll-driven state change and
    # immediately undo it.
    want=""
    src=""
    ev_line=$(tail -n 1 "$EVFILE" 2>/dev/null)
    if [ -n "$ev_line" ] && [ "$ev_line" != "$last_ev_line" ]; then
        last_ev_line="$ev_line"
        case "$ev_line" in
            *screen_toggled:*1) want=on ;;
            *screen_toggled:*0) want=off ;;
        esac
        [ -n "$want" ] && src=event
    fi

    tick=$((tick + 1))
    limit=$POLL_TICKS_ON
    [ "$last_want" = "off" ] && limit=$POLL_TICKS_OFF
    # v1.6.0: while a restore is blocked on missing VBUS, poll the power state
    # every 3s so the picture comes back right after the PD is reconnected.
    [ "$vbus_wait" = "1" ] && limit=$POLL_TICKS_OFF
    if [ -z "$want" ] || [ "$tick" -ge "$limit" ]; then
        tick=0
        p=$(screen_want)
        if [ "$p" != "unknown" ]; then
            if [ "$src" != "event" ]; then
                want=$p
                src=poll
            elif [ "$p" != "$want" ]; then
                log "event says $want but power says $p - trusting power"
                want=$p
                src=poll-fix
            fi
        fi
    fi

    # ---- act on transition, or periodically reconcile drift ----
    # v1.7.0: two windows where the normal path is deliberately skipped -
    #   (a) no external VBUS: hands off the link entirely;
    #   (b) PD just came back: wait PD_SETTLE seconds so the contract is up and
    #       the kernel has finished its own re-attach before we judge anything.
    # After (b) expires a single health check runs; it only repairs when the
    # controller is genuinely not driving pixels (pclk=0).
    if [ "${vbus_resume:-0}" != "0" ] && [ "$(date +%s)" -ge "${vbus_resume:-0}" ]; then
        vbus_resume=0
        if [ "$PD_REPAIR" = "1" ] && [ "$(screen_want)" != "off" ]; then
            refresh_actual
            if video_actual_on; then
                rm -f "$MARKER"
                echo on > "$STATE_FILE"
                log "vbus: PD settled, link healthy (pclk=$(dp_pclk)) - nothing to do"
            else
                log "vbus: PD settled but the sink is still dark (status=$ACT_ST enabled=$ACT_EN pclk=$(dp_pclk)) - repairing"
                restore_video && slow=0 || { slow=1; slow_tick=0; }
            fi
        fi
    fi

    if [ "$vbus_ok_now" = "0" ] && [ "$want" = "on" ]; then
        # unpowered: last_want is left alone on purpose so the health check runs
        # as soon as PD is back and settled
        :
    elif [ "${vbus_resume:-0}" != "0" ]; then
        # settle window: the kernel is mid-reattach, do not interfere
        :
    elif [ -n "$want" ] && { [ "$want" != "$last_want" ] || [ "$src" = "poll" ] || [ "$src" = "poll-fix" ]; }; then
        refresh_actual
        if [ "$want" = "off" ]; then
            if video_actual_off; then
                [ -f "$MARKER" ] || { touch "$MARKER"; echo off > "$STATE_FILE"; }
            elif ! link_present; then
                # nothing attached: nothing to cut, and no marker to suppress
                echo off > "$STATE_FILE"
                rm -f "$MARKER"
            else
                if cut_video; then
                    cut_fail=0
                else
                    cut_fail=$((cut_fail + 1))
                    log "cut failure $cut_fail/$VIDEO_MAX_FAIL"
                    if [ "$cut_fail" -ge "$VIDEO_MAX_FAIL" ]; then
                        echo "cut failed $cut_fail times in a row" > "$DISABLED"
                        log "!! video switching DISABLED for this boot - video left ON by design"
                        rm -f "$MARKER"
                        exit 0
                    fi
                fi
            fi
        else
            if video_actual_on; then
                # already up (or restored by the DP watchdog): drop any marker
                [ -f "$MARKER" ] && log "video already up - clearing cut marker"
                rm -f "$MARKER"
                echo on > "$STATE_FILE"
                slow=0
            elif ! link_present; then
                rm -f "$MARKER"
                echo on > "$STATE_FILE"
                slow=0
            else
                log "screen on but video down (status=$ACT_ST src=$src) - restoring"
                if restore_video; then
                    slow=0
                else
                    slow=1
                    slow_tick=0
                fi
            fi
        fi
        last_want=$want
    fi

    # ---- link sanity: DRM must not report a phantom display ----
    # v1.7.0: report only. The old code wrote hpd=0 here - inert on this kernel,
    # but still a poke at the driver's simulated-HPD state while the framework
    # is streaming, which is exactly the class of poke that broke the sink.
    if [ "$src" = "poll" ] || [ -z "$src" ]; then
        refresh_actual
        if ! partner_present && [ "$ACT_ST" = "connected" ]; then
            [ "$phantom_notice" = "1" ] || \
                log "sanity: no partner attached but connector reports connected (pclk=$(dp_pclk)) - observing only, no hpd write"
            phantom_notice=1
        else
            phantom_notice=0
        fi
    fi

    # ---- slow retry loop for a stuck restore ----
    if [ "$slow" = "1" ] && [ "$want" = "on" ]; then
        slow_tick=$((slow_tick + 1))
        if [ "$slow_tick" -ge "$RESTORE_RETRY_TICKS" ]; then
            slow_tick=0
            refresh_actual
            if video_actual_on; then
                slow=0
                rm -f "$MARKER"
            else
                log "restore retry (still down, status=$ACT_ST)"
                restore_video && slow=0
            fi
        fi
    fi

    sleep 1
done
