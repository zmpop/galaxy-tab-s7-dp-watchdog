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
# MECHANISM
#   /sys/kernel/debug/drm_dp/hpd is the msm DP HPD simulation node:
#     echo 0 -> connector reports disconnected -> link torn down, no signal
#     echo 1 -> connector reports connected    -> link re-trained, signal back
#   (legacy /sys/class/drm/card0-DP-1/dpms is read-only on this kernel, so it
#    cannot be used; port_type replug is kept as a fallback but it also kills
#    the touchscreen USB path and takes much longer, so HPD is preferred.)
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
# ---- v1.6.0 external VBUS guard ----
VBUS_GUARD=1            # 1 = never force HPD high while external VBUS is absent
EXT_VBUS=/sys/class/power_supply/usb/online
OTG_ONLINE=/sys/class/power_supply/otg/online
POWER_ROLE=$TYPEC_PORT/power_role
BAT_CUR=/sys/class/power_supply/battery/current_now
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


refresh_actual() {
    ACT_ST=$(cat "$DP_CONN" 2>/dev/null)
    ACT_EN=$(cat "$DP_EN" 2>/dev/null)
}

video_actual_off() { [ "$ACT_ST" = "disconnected" ] && [ "$ACT_EN" = "disabled" ]; }
video_actual_on()  { [ "$ACT_ST" = "connected" ] && [ "$ACT_EN" = "enabled" ]; }

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
    if ! ensure_hpd; then
        log "cut: HPD node unavailable, cannot cut"
        return 1
    fi
    local i=0
    while [ $i -lt 3 ]; do
        echo 0 > "$HPD_NODE" 2>/dev/null
        sleep 1
        refresh_actual
        if video_actual_off; then
            touch "$MARKER"
            echo off > "$STATE_FILE"
            log "video cut (HPD=0) ok, latency ~$((i + 1))s"
            return 0
        fi
        i=$((i + 1))
    done
    refresh_actual
    log "cut FAILED (status=$ACT_ST enabled=$ACT_EN)"
    return 1
}

restore_video() {
    if ! link_present; then
        rm -f "$MARKER"
        echo on > "$STATE_FILE"
        log "restore skipped: no partner/cable attached"
        return 2
    fi

    # ---- v1.6.0: never force HPD high without external VBUS --------------
    # THIS is the exact line that produced the 17:36 NoC panic: the screen's PD
    # supply was gone, the tablet was Source, and this function still ran
    # "echo 1 > hpd" -> dp_display_usbpd_configure_cb: +++ -> DP re-streamed on
    # a port with no supply. Keep the link down and the marker in place (the
    # marker also keeps service.sh's replug engine from trying), and let the
    # main loop retry every 3s so the picture returns the moment PD is back.
    if ! ext_vbus_ok; then
        echo off > "$STATE_FILE"
        touch "$MARKER"
        if [ "$vbus_notice" != "1" ]; then
            log "restore SUPPRESSED: no external VBUS ($(vbus_evidence)) - forcing HPD here re-streams DP on the tablet's own 5V and ends in the 17:36 NoC panic; waiting for PD"
            vbus_notice=1
        fi
        vbus_wait=1
        return 0
    fi
    vbus_notice=0
    vbus_wait=0

    local i=0 ok=0
    if ensure_hpd; then
        while [ $i -lt 3 ]; do
            echo 1 > "$HPD_NODE" 2>/dev/null
            sleep 2
            refresh_actual
            if video_actual_on; then
                ok=1
                log "video restored (HPD=1) ok, latency ~$((2 * (i + 1)))s"
                break
            fi
            i=$((i + 1))
        done
    else
        log "restore: HPD node unavailable, going straight to port_type fallback"
    fi

    if [ "$ok" = "0" ]; then
        # fallback: full virtual replug (kills USB touch briefly, ~6-15s)
        log "restore: HPD path failed (status=$ACT_ST), fallback to port_type replug"
        echo sink > "$TYPEC_PORT/port_type" 2>/dev/null
        sleep 2
        echo dual > "$TYPEC_PORT/port_type" 2>/dev/null
        i=0
        while [ $i -lt 15 ]; do
            refresh_actual
            if video_actual_on; then
                ok=1
                log "video restored via port_type replug"
                break
            fi
            sleep 1
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
    log "restore FAILED (status=$ACT_ST enabled=$ACT_EN) - will retry"
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

while true; do
    # ---- v1.6.0: external VBUS guard, active side ------------------------
    # While VBUS is absent, hold the link DOWN ourselves instead of waiting for
    # a restore to be refused: the kernel may re-train on its own, and any
    # stream that exists when the PD comes back aborts the commit path.
    # Written on edge only (debugfs write is cheap but not free).
    vbus_ok_now=0
    ext_vbus_ok && vbus_ok_now=1
    if [ "$vbus_ok_now" = "0" ]; then
        if [ "$vbus_cut" != "1" ]; then
            vbus_cut=1
            ensure_hpd && echo 0 > "$HPD_NODE" 2>/dev/null
            touch "$MARKER"
            echo off > "$STATE_FILE"
            log "vbus guard: external VBUS gone ($(vbus_evidence)) - DP held DOWN, restore blocked until power returns"
        else
            # The kernel or the framework may re-enable the link on its own
            # (that is the "died and came back" half of the panic sequence).
            # Re-assert HPD low every 3 ticks while VBUS is missing.
            vbus_recheck=$(( ${vbus_recheck:-0} + 1 ))
            if [ "$vbus_recheck" -ge 3 ]; then
                vbus_recheck=0
                refresh_actual
                if [ "$ACT_ST" != "disconnected" ]; then
                    ensure_hpd && echo 0 > "$HPD_NODE" 2>/dev/null
                    log "vbus guard: link was re-enabled without external power (status=$ACT_ST enabled=$ACT_EN) - HPD forced down again"
                fi
            fi
        fi
    elif [ "$vbus_cut" = "1" ]; then
        vbus_cut=0
        vbus_wait=0
        log "vbus guard: external VBUS back ($(vbus_evidence)) - restoring"
        # Reconcile immediately instead of waiting for the next 15s poll: the
        # screen was black for as long as the PD was out, so restore it now.
        if [ "$(screen_want)" != "off" ]; then
            restore_video >/dev/null 2>&1
        fi
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
    # v1.6.0: with no external VBUS the guard above owns the link state. Running
    # the normal "screen on but video down -> restore" path here would just log
    # the same failure every 3s, so it is skipped entirely; the marker stays in
    # place and the restore happens on the first tick after power returns.
    if [ "$vbus_ok_now" = "0" ] && [ "$want" = "on" ]; then
        # guard holds the link down; last_want is left alone on purpose so the
        # restore fires the moment external power returns
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
    # (protects against a HPD override masking a real unplug)
    if [ "$src" = "poll" ] || [ -z "$src" ]; then
        refresh_actual
        if ! partner_present && [ "$ACT_ST" = "connected" ]; then
            [ -e "$HPD_NODE" ] && echo 0 > "$HPD_NODE" 2>/dev/null
            log "sanity: no partner attached but connector reported connected -> HPD low"
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
