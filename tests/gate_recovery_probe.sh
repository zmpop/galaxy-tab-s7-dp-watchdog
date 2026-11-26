#!/system/bin/sh
# 关键安全性验证：钉成 sink 后，已接的 PD 源能否自行重新供电？
# 若 usb/online 永远回不到 1，闸门就会把端口锁死（不能充电/画面回不来）。
echo "t(s) usb otg role ma dp pclk"
i=0
echo sink > /sys/class/typec/port0/port_type 2>/dev/null
while [ $i -le 30 ]; do
    printf '%2d   %s   %s   %-16s %6s %-13s %s\n' "$i" \
        "$(cat /sys/class/power_supply/usb/online 2>/dev/null)" \
        "$(cat /sys/class/power_supply/otg/online 2>/dev/null)" \
        "$(cat /sys/class/typec/port0/power_role 2>/dev/null | tr -d ' ')" \
        "$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)" \
        "$(cat /sys/class/drm/card0-DP-1/status 2>/dev/null)/$(cat /sys/class/drm/card0-DP-1/enabled 2>/dev/null)" \
        "$(grep -m1 pclock= /sys/kernel/debug/drm_dp/dp_debug 2>/dev/null | sed 's/.*pclock=//;s/KHz.*//')"
    sleep 1
    i=$((i + 1))
done
echo "=== 30s 后强制写 dual 收尾 ==="
echo dual > /sys/class/typec/port0/port_type 2>/dev/null
sleep 4
echo "usb=$(cat /sys/class/power_supply/usb/online) dp=$(cat /sys/class/drm/card0-DP-1/status)/$(cat /sys/class/drm/card0-DP-1/enabled) pclk=$(grep -m1 pclock= /sys/kernel/debug/drm_dp/dp_debug | sed 's/.*pclock=//;s/KHz.*//')"
