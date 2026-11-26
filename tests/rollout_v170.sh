#!/system/bin/sh
# Stop the running daemons, deploy the freshly built zip, clear stale state and
# start the new code. No reboot: only scripts changed, and service.sh re-execs
# screenvid/wakegate itself.
set -u
say() { echo "[roll] $*"; }

say "stopping daemons"
for d in service.sh screenvid.sh wakegate.sh; do
    pkill -f "modules/tab_dp_watchdog/$d" 2>/dev/null
done
sleep 2
left=$(ps -A -o ARGS 2>/dev/null | grep 'modules/tab_dp_watchdog/' | grep -v grep)
[ -z "$left" ] && say "all daemons stopped" || say "still running: $left"

say "deploying $1"
sh /data/local/tmp/deploy_direct.sh "$1" || { say "DEPLOY FAILED"; exit 1; }

say "clearing stale runtime state"
rm -f /data/adb/tpdp/video_off /data/adb/tpdp/video.disabled /data/adb/tpdp/web.pid 2>/dev/null

say "starting service.sh"
nohup sh /data/adb/modules/tab_dp_watchdog/service.sh >/dev/null 2>&1 &
sleep 12

say "---- state ----"
printf '  version   : %s\n' "$(grep '^version=' /data/adb/modules/tab_dp_watchdog/module.prop | cut -d= -f2)"
printf '  procs     : %s\n' "$(ps -A -o ARGS 2>/dev/null | grep -c '[m]odules/tab_dp_watchdog')"
printf '  dp        : %s / %s\n' "$(cat /sys/class/drm/card0-DP-1/status)" "$(cat /sys/class/drm/card0-DP-1/enabled)"
printf '  pclk      : %s\n' "$(grep -m1 pclock= /sys/kernel/debug/drm_dp/dp_debug | sed 's/.*pclock=//')"
printf '  vbus      : usb=%s otg=%s role=%s\n' "$(cat /sys/class/power_supply/usb/online)" "$(cat /sys/class/power_supply/otg/online)" "$(cat /sys/class/typec/port0/power_role)"
say "---- log tail ----"
tail -12 /data/adb/tpdp/log 2>/dev/null
