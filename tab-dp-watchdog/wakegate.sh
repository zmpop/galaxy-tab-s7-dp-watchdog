#!/system/bin/sh
# Tab S7 DP Link Watchdog - screen wake gate + screen-off timeout enforcer
#
# Started and supervised by service.sh, runs as root.
#
# WHY THIS EXISTS
#   With an external DP/HDMI display attached, Samsung's system_server keeps
#   'DisplayDeviceRepository.mHDMIWakeLock' (a SCREEN_DIM_WAKE_LOCK with
#   ACQUIRE_CAUSES_WAKEUP) held for as long as the external display is ON.
#   Two consequences, both observed on this tablet:
#     1) anything that calls wakeUp() (charger state changes, network/alarm
#        wakeups, the HDMI wake lock itself) lights the screen up, unasked;
#     2) a held SCREEN_DIM_WAKE_LOCK forbids the screen from turning off, so
#        the user's "30s screen timeout" never fires - the panel dims and
#        stays lit for hours.
#   Neither can be fixed from user space by touching PowerManager, so this
#   daemon implements the two policies on top of the framework:
#     - wake gate:  after the screen comes ON, decide whether the wake was
#                   user initiated (power key / touchscreen) or not, and put
#                   it straight back to sleep when it was not;
#     - timeout:    when the framework's own screen-off timer is blocked by a
#                   wake lock, force sleep once the configured timeout has
#                   really elapsed.
#
# CONFIG (all under /data/adb/tpdp, hot-reloaded, 0/1 flags)
#   WAKE_GATE=1         # only touchscreen tap / power key may light the screen
#   WAKE_GATE_TOUCH=1   # allow touchscreen tap to wake (only when WAKE_GATE=1)
#   TIMEOUT_ENFORCE=1   # force the configured screen-off timeout to apply
#
# EVIDENCE USED (verified on SM-T970 / Android 12)
#   power key    : logcat -b main  "interceptKeyTq keycode=26"  (epoch stamp)
#                  NOTE: /sys/class/sec/sec_key/key_pressed_count only counts
#                  KVUP/KVDN, KPWR never increments -> unusable.
#   touch / keys : dumpsys power  mLastUserActivityTime vs mLastWakeTime
#                  (PMS only refreshes user activity for dispatched input)
#                  plus dumpsys input "RecentQueue" MotionEvent ages as a
#                  secondary signal for a fresh tap.
#   getevent     : NOT usable here - hardware events are consumed by
#                  sec_key_notifier and do not reach an evdev reader.
#
# STATE (all under /data/adb/tpdp)
#   wake.ev     screen_toggled event feed (instant screen on/off notification)
#   hb.wake     heartbeat (supervised by nothing, informational)
#
# FAILSAFE
#   The gate is deliberately conservative: if it suppresses more than 8 wakes
#   within 5 minutes it assumes its evidence reading is wrong and pauses for
#   10 minutes instead of fighting the framework (which could lock the user
#   out of the device). Every decision is logged with its evidence snapshot.

MODDIR=${0%/*}
LOGDIR=/data/adb/tpdp
LOG=$LOGDIR/log
mkdir -p "$LOGDIR"

# ---------- defaults (override via $LOGDIR/config) ----------
WAKE_GATE=1
WAKE_GATE_TOUCH=1
TIMEOUT_ENFORCE=1
CFG=$LOGDIR/config
# ------------------------------------------------------------

[ -f "$CFG" ] && . "$CFG" 2>/dev/null
for v in WAKE_GATE WAKE_GATE_TOUCH TIMEOUT_ENFORCE; do
    eval "val=\$$v"
    case "$val" in 0|1) ;; *) eval "$v=1" ;; esac
done

MODVER=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
[ -n "$MODVER" ] || MODVER=unknown

EV=$LOGDIR/wake.ev
HB=$LOGDIR/hb.wake
INPUT_BIN=/system/bin/input

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [wake] $*" >> "$LOG"
    [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 524288 ] && \
        tail -n 400 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

cfg_mtime=0
[ -f "$CFG" ] && cfg_mtime=$(date -r "$CFG" +%s 2>/dev/null || echo 0)

# ---- evidence helpers ----------------------------------------------------

# epoch timestamp of the most recent power key event, empty if unknown
last_power_epoch() {
    logcat -d -b main -v epoch -t 2000 2>/dev/null | \
        grep 'interceptKeyTq keycode=26' | tail -n 1 | awk '{print $1}'
}

# smallest "age" (ms) of a recent MotionEvent in InputDispatcher's queue
motion_age() {
    dumpsys input 2>/dev/null | sed -n '/RecentQueue/,/PendingEvent/p' | \
        sed -n 's/.*MotionEvent.*age=\([0-9]\{1,\}\)ms.*/\1/p' | sort -n | head -n 1
}

sleep_now() {
    "$INPUT_BIN" keyevent 223 >/dev/null 2>&1 \
        || log "error: cannot send KEYCODE_SLEEP (input missing?)"
}

# ---- wake gate -----------------------------------------------------------

suppress_wake() {
    local now
    now=$(date +%s)
    sleep_now
    suppress_until=$((now + 3))
    log "wake SUPPRESSED ($1, motion=${2:-na}ms delta=${3:-na}ms) -> sleep forced"
    if [ "$supp_window_start" -eq 0 ] || [ "$((now - supp_window_start))" -gt 300 ]; then
        supp_window_start=$now
        supp_count=0
    fi
    supp_count=$((supp_count + 1))
    if [ "$supp_count" -gt 8 ]; then
        gate_paused_until=$((now + 600))
        supp_count=0
        supp_window_start=$now
        log "!! more than 8 suppressions in 5min - evidence unreliable, gate PAUSED for 600s"
    fi
}

# Decide whether the wake was input driven.
#   ev_motion : age (ms) of the newest MotionEvent in InputDispatcher's queue
#   ev_delta  : mLastUserActivityTime - mLastWakeTime (both uptimeMillis)
# PMS updates mLastUserActivityTime for every dispatched input event, but NOT
# for programmatic wakeups (charger state change, alarm/network, the HDMI
# wake lock). An input driven wake therefore has |delta| close to 0, while a
# programmatic one leaves the last activity way back in the past - or, when
# the user pressed the power key before, way in the future (that old activity
# stays the newest one). Both outliers mean "no input at this wake".
user_activity_evidence() {
    local info wk ua
    ev_motion=$(motion_age)
    info=$(dumpsys power 2>/dev/null | grep -E 'mLastWakeTime=|mLastUserActivityTime')
    wk=$(echo "$info" | sed -n 's/.*mLastWakeTime=\([0-9]\{1,\}\).*/\1/p' | head -n 1)
    ua=$(echo "$info" | sed -n 's/.*mLastUserActivityTime[^=]*=\([0-9]\{1,\}\).*/\1/p' | head -n 1)
    ev_delta=""
    [ -n "$wk" ] && [ -n "$ua" ] && ev_delta=$((ua - wk))
}

is_input_wake() {
    [ -n "$ev_motion" ] && [ "$ev_motion" -lt 2500 ] && return 0
    if [ -n "$ev_delta" ] && [ "$ev_delta" -ge -1500 ] && [ "$ev_delta" -le 1500 ]; then
        return 0
    fi
    return 1
}

handle_wake() {
    local now ts pk reason
    now=$(date +%s)

    if [ "$now" -lt "$suppress_until" ]; then
        log "wake: ignored (own suppression echo, <3s)"
        return
    fi
    if [ "$now" -lt "$gate_paused_until" ]; then
        log "wake: allowed (gate paused by failsafe, +$((gate_paused_until - now))s)"
        return
    fi
    if [ "$WAKE_GATE" != "1" ]; then
        log "wake: allowed (gate disabled in config)"
        ua_ts=$now
        prev_ua=""
        return
    fi

    # 1) power key? (keycode 26 within the last 5s)
    pk=0
    ts=$(last_power_epoch)
    if [ -n "$ts" ]; then
        pk=$(awk -v n="$now" -v t="$ts" 'BEGIN { print (n - t <= 5) ? 1 : 0 }')
    fi

    # 2) input driven?
    user_activity_evidence

    if [ "$pk" = "1" ]; then
        log "wake allowed (power_button, motion=${ev_motion:-na}ms delta=${ev_delta:-na}ms)"
        ua_ts=$now
        return
    fi

    if is_input_wake; then
        if [ "$WAKE_GATE_TOUCH" = "1" ]; then
            log "wake allowed (input, motion=${ev_motion:-na}ms delta=${ev_delta:-na}ms)"
            ua_ts=$now
            return
        fi
        suppress_wake "touch_blocked" "${ev_motion:-na}" "${ev_delta:-na}"
        return
    fi

    # 3) nothing attributable. Give the input path one more second: a genuine
    #    tap that woke the panel can be dispatched just after screen_toggled.
    sleep 1
    user_activity_evidence
    if is_input_wake; then
        if [ "$WAKE_GATE_TOUCH" = "1" ]; then
            log "wake allowed (late input, motion=${ev_motion:-na}ms delta=${ev_delta:-na}ms)"
            ua_ts=$(date +%s)
            return
        fi
        suppress_wake "touch_blocked" "${ev_motion:-na}" "${ev_delta:-na}"
        return
    fi
    suppress_wake "no_input" "${ev_motion:-na}" "${ev_delta:-na}"
}

# ---- screen-off timeout enforcer ----------------------------------------
# The framework's own timer is blocked by a held SCREEN_DIM_WAKE_LOCK. Detect
# real idleness from mLastUserActivityTime: while the user touches the screen
# it changes on every event, so "value unchanged for > timeout" is idle.
enforce_timeout() {
    local info w stay ua to_ms now idle need ua2
    [ "$TIMEOUT_ENFORCE" = "1" ] || return 0

    # one dumpsys call, filtered down to the few lines we need: the full dump
    # is far too large to be passed around as a shell argument (ARG_MAX).
    # NOTE: dumpsys power also prints a *history* section listing wake locks
    # that were released days ago, so the bright-lock check must be limited
    # to the live "Wake Locks: size=" block - otherwise every app that ever
    # played a video would disable the timeout forever.
    info=$(dumpsys power 2>/dev/null | awk '
        /^[ \t]*Wake Locks: size/ {lk=1; next}
        lk && /^[ \t]*$/ {lk=0}
        lk && /SCREEN_BRIGHT_WAKE_LOCK|FULL_WAKE_LOCK/ {print "HOLDBRIGHT"}
        /mWakefulness=/ {print}
        /mStayOn=/ {print}
        /mLastUserActivityTime/ {print}
        /mScreenOffTimeoutSetting=/ {print}
    ')
    [ -n "$info" ] || return 0

    w=$(echo "$info" | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -n 1)
    if [ "$w" != "Awake" ]; then
        prev_ua=""
        ua_ts=0
        return 0
    fi

    stay=$(echo "$info" | sed -n 's/.*mStayOn=\([a-z]*\).*/\1/p' | head -n 1)
    [ "$stay" = "true" ] && return 0

    # an app that asked to keep the screen bright must win over the timeout
    echo "$info" | grep -q 'HOLDBRIGHT' && return 0

    ua=$(echo "$info" | sed -n 's/.*mLastUserActivityTime[^=]*=\([0-9]\{1,\}\).*/\1/p' | head -n 1)
    [ -n "$ua" ] || return 0

    to_ms=$(echo "$info" | sed -n 's/.*mScreenOffTimeoutSetting=\([0-9]\{1,\}\).*/\1/p' | head -n 1)
    case "$to_ms" in ''|*[!0-9]*) to_ms=30000 ;; esac

    now=$(date +%s)
    if [ "$ua" != "$prev_ua" ]; then
        prev_ua=$ua
        ua_ts=$now
        return 0
    fi
    [ "$ua_ts" -gt 0 ] || { ua_ts=$now; return 0; }

    idle=$((now - ua_ts))
    need=$((to_ms / 1000 + 2))
    [ "$idle" -ge "$need" ] || return 0

    # confirm immediately before acting (never sleep a screen being touched)
    ua2=$(dumpsys power 2>/dev/null | \
        sed -n 's/.*mLastUserActivityTime[^=]*=\([0-9]\{1,\}\).*/\1/p' | head -n 1)
    if [ -n "$ua2" ] && [ "$ua2" != "$ua" ]; then
        prev_ua=$ua2
        ua_ts=$(date +%s)
        return 0
    fi

    sleep_now
    suppress_until=$((now + 3))
    prev_ua=""
    ua_ts=0
    log "timeout ENFORCED (idle ${idle}s >= ${need}s, screen_off_timeout=${to_ms}ms) - framework timer was blocked by a wake lock"
}

# ---- main ---------------------------------------------------------------

if [ "$(getprop sys.boot_completed)" != "1" ]; then
    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 150 ]; do
        sleep 2
        i=$((i + 2))
    done
fi

log "===== wakegate $MODVER started (gate=$WAKE_GATE touch=$WAKE_GATE_TOUCH timeout_enforce=$TIMEOUT_ENFORCE) ====="

# screen event feed (instant path); re-created when it dies, like screenvid
start_feed() {
    [ -f "$EV" ] || rm -rf "$EV" 2>/dev/null
    ( : > "$EV" ) 2>/dev/null
    logcat -b events -s screen_toggled:I > "$EV" 2>/dev/null &
    EVPID=$!
}
start_feed

# seed from the current state: never act on a wake that happened before start
sleep 1
last_line=$(tail -n 1 "$EV" 2>/dev/null)

suppress_until=0
gate_paused_until=0
supp_window_start=0
supp_count=0
prev_ua=""
ua_ts=0
feed_fail=0
feed_retry=0
tick=0
ENFORCE_TICK=5
hb_tick=0

while true; do
    # ---- config hot-reload ----
    if [ -f "$CFG" ]; then
        mt=$(date -r "$CFG" +%s 2>/dev/null || echo 0)
        if [ "$mt" != "$cfg_mtime" ]; then
            cfg_mtime=$mt
            . "$CFG" 2>/dev/null
            for v in WAKE_GATE WAKE_GATE_TOUCH TIMEOUT_ENFORCE; do
                eval "val=\$$v"
                case "$val" in 0|1) ;; *) eval "$v=1" ;; esac
            done
            log "config reloaded: gate=$WAKE_GATE touch=$WAKE_GATE_TOUCH timeout_enforce=$TIMEOUT_ENFORCE"
        fi
    fi

    # ---- feed health (bounded restart, never spin) ----
    if ! kill -0 "$EVPID" 2>/dev/null; then
        now=$(date +%s)
        if [ "$now" -ge "$feed_retry" ]; then
            feed_fail=$((feed_fail + 1))
            [ "$feed_fail" -le 3 ] && log "screen event feed died (try $feed_fail) - restarting"
            [ "$feed_fail" = "4" ] && log "event feed keeps dying - wake gate degraded (no screen events)"
            start_feed
            last_line=$(tail -n 1 "$EV" 2>/dev/null)
            feed_retry=$((now + 15))
        fi
    else
        feed_fail=0
    fi

    # ---- screen state events ----
    line=$(tail -n 1 "$EV" 2>/dev/null)
    if [ -n "$line" ] && [ "$line" != "$last_line" ]; then
        last_line="$line"
        case "$line" in
            *"screen_toggled: 1") handle_wake ;;
            *"screen_toggled: 0") prev_ua=""; ua_ts=0 ;;
        esac
    fi

    # ---- periodic timeout enforcement ----
    tick=$((tick + 1))
    if [ "$tick" -ge "$ENFORCE_TICK" ]; then
        tick=0
        enforce_timeout
        hb_tick=$((hb_tick + 1))
        [ "$hb_tick" -ge 3 ] && { hb_tick=0; date +%s > "$HB"; }
    fi

    sleep 1
done
