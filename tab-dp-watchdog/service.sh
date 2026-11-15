#!/system/bin/sh
# Tab S7 DP Link Watchdog v1.3.2 - service entry
# Runs as root (u:r:magisk:s0) at late_start service mode.
#
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
LOCK60=1               # 1 = cap DP pixel clock (forces 60Hz-class modes)
PCLK_CAP_KHZ=300000    # pixel clock cap; 120Hz mode needs 537MHz, 60Hz 268MHz
# --------------------------------------------------------------------

[ -f "$LOGDIR/config" ] && . "$LOGDIR/config"

cfg_mtime=0
[ -f "$LOGDIR/config" ] && cfg_mtime=$(date -r "$LOGDIR/config" +%s 2>/dev/null || echo 0)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 524288 ] && \
        tail -n 400 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# ---------- screen gated video output (v1.3.0) ----------
HPD_NODE=/sys/kernel/debug/drm_dp/hpd

# ---------- 60Hz lock (v1.3.2) ----------
PCLK_NODE=/sys/kernel/debug/drm_dp/max_pclk_khz
DPDEBUG_NODE=/sys/kernel/debug/drm_dp/dp_debug

dp_hz() {
    # current DP timing, e.g. "2560x1600@120Hz" (lines carry leading blanks)
    sed -n 's/^[[:space:]]*resolution=//p' "$DPDEBUG_NODE" 2>/dev/null | head -n 1
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

apply_hz_lock() {
    # $1: 1 = enforce the cap, 0 = restore the original limit
    [ -e "$PCLK_NODE" ] || return 1
    local v
    if [ "$1" = "1" ]; then
        v=$(pclk_org)
        [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && echo "$v" > "$LOGDIR/pclk_org"
        echo "$PCLK_CAP_KHZ" > "$PCLK_NODE" 2>/dev/null || return 1
    else
        v=$(pclk_org)
        [ -n "$v" ] || v=675000
        echo "$v" > "$PCLK_NODE" 2>/dev/null || return 1
    fi
    return 0
}

hz_lock_boot() {
    # Apply the cap early; if the link already enumerated at a high mode
    # (cold boot with cable attached happens before late_start services),
    # re-enumerate once so the framework re-picks a mode within the cap.
    [ "$LOCK60" = "1" ] || { lock_applied=0; return 0; }
    lock_applied=1
    if apply_hz_lock 1; then
        log "hz lock: DP pixel clock capped at ${PCLK_CAP_KHZ}kHz"
        if dp_up; then
            case "$(dp_hz)" in
                *120Hz*)
                    log "hz lock: link came up at $(dp_hz) -> forcing re-enumeration"
                    echo 0 > "$HPD_NODE" 2>/dev/null
                    sleep 2
                    echo 1 > "$HPD_NODE" 2>/dev/null
                    ;;
            esac
        fi
    else
        log "hz lock: $PCLK_NODE not writable, feature unavailable"
        lock_applied=0
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
log "===== service $MODVER started (poll=${POLL_SEC}s, vid:pid=$TP_VID:$TP_PID, lock60=${LOCK60}) ====="
boot_video_failsafe
hz_lock_boot
start_screenvid
sleep "$BOOT_DELAY"

strike=0
episode_done=0
ever_dp_up=0

while true; do
    sleep "$POLL_SEC"

    # heartbeat for the mutual supervision with screenvid
    date +%s > "$LOGDIR/hb.main"
    start_screenvid

    # hot-reload config if it changed (e.g. saved from the web UI)
    if [ -f "$LOGDIR/config" ]; then
        mt=$(date -r "$LOGDIR/config" +%s 2>/dev/null || echo 0)
        if [ "$mt" != "$cfg_mtime" ]; then
            cfg_mtime=$mt
            . "$LOGDIR/config" 2>/dev/null
            log "config reloaded: vid:pid=$TP_VID:$TP_PID poll=${POLL_SEC}s lock60=$LOCK60"
            strike=0
            # reconcile the 60Hz lock with the kernel. The web CGI applies
            # the cap AND the re-enumeration itself before saving the config,
            # so this only needs to mirror manual config edits: the kernel
            # write is idempotent, no mode switch is forced here.
            if [ "$LOCK60" = "1" ] && [ "$lock_applied" != "1" ]; then
                lock_applied=1
                apply_hz_lock 1 && log "hz lock: enabled (cap ${PCLK_CAP_KHZ}kHz)"
            elif [ "$LOCK60" != "1" ] && [ "$lock_applied" = "1" ]; then
                lock_applied=0
                apply_hz_lock 0 && log "hz lock: disabled (pixel clock limit restored)"
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
        [ -e "$HPD_NODE" ] && echo 1 > "$HPD_NODE" 2>/dev/null
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
