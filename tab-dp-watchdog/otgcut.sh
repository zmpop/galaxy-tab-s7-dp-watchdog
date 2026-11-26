#!/system/bin/sh
# Tab S7 DP Link Watchdog - otgcut: really remove the tablet's 5V output
#
# WHY THIS FILE EXISTS
#   When the external screen's PD supply is pulled, the DRP flips to
#   Attached.SRC and the tablet feeds the screen from its own battery. Measured
#   on SM-T970: `otg/online=1`, `power_role=source`, `battery/current_now=-1.9A`.
#   The screen therefore stays powered and never goes dark.
#
#   Every "obvious" lever was measured and rejected on this kernel:
#     echo sink > port_type        -> "max77705_port_type_set: invalid typec_role"
#                                     (kernel refuses while a partner is attached)
#     echo sink > preferred_role   -> same rejection
#     echo 0 > otg/online (once)   -> kernel re-arms the boost within ~1s
#
#   The one thing that does work is holding `otg/online` at 0 repeatedly. A
#   single write is undone by the charger driver; a write every 200ms keeps the
#   boost down. That is exactly what tabpdmon's sinkguard.sh did during the
#   verified pull tests (2026-11-26 18:10 and 20:40), and it is the reason those
#   tests ended with the screen depowered. That logic never made it into the
#   module - this daemon is the port of it.
#
#   Evidence from the 20:40 replay (series.csv, 1s sampling):
#     t+0.0  role=source otg=1 ma=-1609 dp=disconnected
#     t+1.2  role=source otg=0 ma= -639     <- cut applied
#     t+9.9  role=sink               ...    <- PD back, cut released
#   Compare 18:10: otg=1 ma=-1929 -> otg=0 ma=-1811 -> ... -> role=sink.
#
# SAFETY GATE
#   `otg/online=0` is also the normal state of a plain OTG session (USB stick),
#   so the cut must never fire there. It only arms when the attached partner
#   advertises USB Power Delivery, or when DP has been up at least once during
#   this boot - i.e. when the thing on the other end is the external screen.
#   Set OTG_CUT_GUARD=0 in $LOGDIR/config to drop that check.
#
# STATE
#   hb.otg      heartbeat (touched every ~5s)
#   dp_ever     boot_id of the last boot in which DP was seen connected
#
# CONFIG ($LOGDIR/config)
#   OTG_CUT=0          disable this daemon entirely
#   OTG_CUT_GUARD=0    cut without requiring a PD-capable partner
#   CUT_POLL / CUT_STRIKES / CUT_RELEASE   tuning (seconds, polls)

MODDIR=${0%/*}
LOGDIR=/data/adb/tpdp
LOG=$LOGDIR/log
mkdir -p "$LOGDIR"

# ---------- defaults ----------
OTG_CUT=1
OTG_CUT_GUARD=1
CUT_POLL=0.2            # seconds between writes (5 Hz)
CUT_STRIKES=3           # consecutive "no VBUS" polls before the cut arms
CUT_RELEASE=20          # consecutive "VBUS present" polls before it releases
# ------------------------------

[ -f "$LOGDIR/config" ] && . "$LOGDIR/config"

EXT_VBUS=/sys/class/power_supply/usb/online
OTG=/sys/class/power_supply/otg/online
BAT_CUR=/sys/class/power_supply/battery/current_now
DP_STATUS=/sys/class/drm/card0-DP-1/status
PARTNER_PD=/sys/class/typec/port0-partner/supports_usb_power_delivery
BOOTID=/proc/sys/kernel/random/boot_id
EVER=$LOGDIR/dp_ever
HB=$LOGDIR/hb.otg

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [otgcut] $*" >> "$LOG"
    [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 524288 ] && \
        tail -n 400 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

[ "$OTG_CUT" = "1" ] || { log "otgcut: disabled by config (OTG_CUT=$OTG_CUT), exiting"; exit 0; }
[ -e "$OTG" ] || { log "otgcut: $OTG absent - nothing to cut, exiting"; exit 0; }

BID=$(cat "$BOOTID" 2>/dev/null)

# Is the thing on the other end the external screen (rather than a USB stick)?
screen_partner() {
    [ "$OTG_CUT_GUARD" = "1" ] || return 0
    [ -n "$BID" ] && [ "$(cat "$EVER" 2>/dev/null)" = "$BID" ] && return 0
    [ "$(cat "$PARTNER_PD" 2>/dev/null)" = "yes" ] && return 0
    return 1
}

log "otgcut: started (poll=${CUT_POLL}s strikes=$CUT_STRIKES release=$CUT_RELEASE guard=$OTG_CUT_GUARD) vbus=$(cat "$EXT_VBUS" 2>/dev/null) otg=$(cat "$OTG" 2>/dev/null)"

zeros=0
armed=0
up=0
tick=0
hb=0
cut_n=0
skipped=0

while :; do
    tick=$((tick + 1))

    # remember that DP has been up during this boot (checked every ~5s: the
    # marker lives on /data, so it must not be rewritten at 5 Hz)
    if [ $((tick % 25)) -eq 0 ]; then
        [ "$(cat "$DP_STATUS" 2>/dev/null)" = "connected" ] && \
            [ -n "$BID" ] && printf '%s\n' "$BID" > "$EVER" 2>/dev/null
    fi

    u=$(cat "$EXT_VBUS" 2>/dev/null)
    case "$u" in
        0)
            zeros=$((zeros + 1))
            up=0
            if [ "$armed" = "0" ] && [ "$zeros" -ge "$CUT_STRIKES" ]; then
                if screen_partner; then
                    armed=1
                    cut_n=0
                    log "external VBUS gone - cutting the tablet 5V boost (otg=$(cat "$OTG" 2>/dev/null) role=$(cat /sys/class/typec/port0/power_role 2>/dev/null) ma=$(cat "$BAT_CUR" 2>/dev/null))"
                else
                    armed=0
                    if [ "$skipped" = "0" ]; then
                        log "external VBUS gone but partner is not a PD sink or a DP display - not cutting (plain OTG session)"
                        skipped=1
                    fi
                fi
            fi
            if [ "$armed" = "1" ]; then
                o=$(cat "$OTG" 2>/dev/null)
                if [ "$o" = "1" ]; then
                    echo 0 > "$OTG" 2>/dev/null
                    o2=$(cat "$OTG" 2>/dev/null)
                    cut_n=$((cut_n + 1))
                    if [ "$o2" = "0" ]; then
                        [ "$cut_n" -le 3 ] && log "otg boost cut #$cut_n (was=1 -> 0) ma=$(cat "$BAT_CUR" 2>/dev/null)"
                    else
                        [ "$cut_n" -le 3 ] && log "otg cut #$cut_n FAILED (still $o2) - kernel re-arms the boost, software lever ineffective"
                    fi
                fi
            fi
            ;;
        1)
            zeros=0
            skipped=0
            if [ "$armed" = "1" ]; then
                up=$((up + 1))
                if [ "$up" -ge "$CUT_RELEASE" ]; then
                    armed=0
                    up=0
                    log "external VBUS back - cut released (cuts=$cut_n, otg=$(cat "$OTG" 2>/dev/null))"
                fi
            else
                up=0
            fi
            ;;
        *)
            # node unreadable: do nothing rather than guess
            zeros=0
            up=0
            ;;
    esac

    hb=$((hb + 1))
    if [ "$hb" -ge 25 ]; then
        hb=0
        touch "$HB" 2>/dev/null
    fi

    sleep "$CUT_POLL" 2>/dev/null || sleep 1
done
