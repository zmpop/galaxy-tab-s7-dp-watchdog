#!/system/bin/sh
# root-only sampler: 0.3s cadence, fresh file per run, no dependency on cwd
# usage: sh pdw_record.sh [samples] [outfile]
N=${1:-3000}
OUT=${2:-/data/local/tmp/pdw-$(date +%H%M%S).csv}
S=/sys/class

echo "t,usb,otg,role,ma,dp,dp_en,pclk,port" > "$OUT"

i=0
while [ $i -lt "$N" ]; do
    t=$(cat /proc/uptime | cut -d' ' -f1)
    usb=$(cat $S/power_supply/usb/online 2>/dev/null)
    otg=$(cat $S/power_supply/otg/online 2>/dev/null)
    role=$(cat $S/typec/port0/power_role 2>/dev/null | tr -d ' ')
    ma=$(cat $S/power_supply/battery/current_now 2>/dev/null)
    dp=$(cat $S/drm/card0-DP-1/status 2>/dev/null)
    en=$(cat $S/drm/card0-DP-1/enabled 2>/dev/null)
    pclk=$(grep -m1 pclock= /sys/kernel/debug/drm_dp/dp_debug 2>/dev/null | sed 's/.*pclock=//;s/KHz.*//')
    port=$(cat $S/typec/port0/port_type 2>/dev/null | tr -d ' ')
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$t" "$usb" "$otg" "$role" "$ma" "$dp" "$en" "$pclk" "$port" >> "$OUT"
    sleep 0.3
    i=$((i + 1))
done
echo "done $OUT"
