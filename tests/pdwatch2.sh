#!/system/bin/sh
# 0.5s 采样，记录拔插全过程（10 分钟）
N=${1:-1200}
OUT=/data/local/tmp/pdwatch.csv
echo "t_mono,usb,otg,role,ma,dp,dp_en,pclk,mode" > "$OUT"
i=0
while [ $i -lt $N ]; do
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(cat /proc/uptime | cut -d' ' -f1)" \
      "$(cat /sys/class/power_supply/usb/online 2>/dev/null)" \
      "$(cat /sys/class/power_supply/otg/online 2>/dev/null)" \
      "$(cat /sys/class/typec/port0/power_role 2>/dev/null | tr -d ' ')" \
      "$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)" \
      "$(cat /sys/class/drm/card0-DP-1/status 2>/dev/null)" \
      "$(cat /sys/class/drm/card0-DP-1/enabled 2>/dev/null)" \
      "$(grep -m1 pclock= /sys/kernel/debug/drm_dp/dp_debug 2>/dev/null | sed 's/.*pclock=//;s/KHz.*//')" \
      "$(grep -m1 -o 'mode=[^ ]*' /sys/kernel/debug/drm_dp/dp_debug 2>/dev/null)" \
      >> "$OUT"
    sleep 0.5
    i=$((i + 1))
done
