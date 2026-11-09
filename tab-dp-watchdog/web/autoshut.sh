#!/system/bin/sh
# Auto-shutdown timer for the web config UI.
# Started by action.sh as: autoshut.sh <seconds>
PIDFILE=/data/adb/tpdp/web.pid
LOGDIR=/data/adb/tpdp
T=${1:-300}

sleep "$T"

if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
fi
rm -f "$PIDFILE" "$LOGDIR/web.start"
echo "$(date '+%Y-%m-%d %H:%M:%S') web: config UI auto-shutdown after ${T}s" >> "$LOGDIR/log"
