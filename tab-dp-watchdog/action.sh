#!/system/bin/sh
# Manual action (Magisk app "Run" button): force one recovery attempt now.
LOGDIR=/data/adb/tpdp
[ -f "$LOGDIR/config" ] && . "$LOGDIR/config"
: ${TYPEC_PORT:=/sys/class/typec/port0}
: ${EXTCON_STATE:=/sys/class/extcon/extcon0/state}

mkdir -p "$LOGDIR"
echo "$(date '+%Y-%m-%d %H:%M:%S') manual action: forcing virtual replug" >> "$LOGDIR/log"
echo sink > "$TYPEC_PORT/port_type"
sleep 2
echo dual > "$TYPEC_PORT/port_type"
echo "Recovery triggered. Check the external screen in ~10s."
