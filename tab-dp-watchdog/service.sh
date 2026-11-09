#!/system/bin/sh
# Tab S7 DP Link Watchdog v1.1.0 - service entry
# Runs as root (u:r:magisk:s0) at late_start service mode.
#
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
# --------------------------------------------------------------------

[ -f "$LOGDIR/config" ] && . "$LOGDIR/config"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 524288 ] && \
        tail -n 400 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

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

log "===== service v1.1.0 started (poll=${POLL_SEC}s, vid:pid=$TP_VID:$TP_PID) ====="
sleep "$BOOT_DELAY"

strike=0
episode_done=0
ever_dp_up=0

while true; do
    sleep "$POLL_SEC"

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
