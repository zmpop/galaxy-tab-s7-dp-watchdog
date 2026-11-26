#!/system/bin/sh
# 在当前"平板正在给屏供电"的状态下，逐个试验能否安全地停止 5V 输出
M() { printf '  ma=%-7s usb=%s otg=%s role=%s otgctl=%s\n' \
  "$(cat /sys/class/power_supply/battery/current_now)" \
  "$(cat /sys/class/power_supply/usb/online)" \
  "$(cat /sys/class/power_supply/otg/online)" \
  "$(cat /sys/class/typec/port0/power_role | tr -d ' ')" \
  "$(cat /sys/class/power_supply/battery/charge_otg_control 2>/dev/null)"; }

echo "baseline:"; M

echo "T1 otg/online=0"
echo 0 > /sys/class/power_supply/otg/online 2>/dev/null; sleep 3; M

echo "T2 charge_otg_control=0"
echo 0 > /sys/class/power_supply/battery/charge_otg_control 2>/dev/null; sleep 3; M

echo "T3 charge_otg_control=0 + otg/online=0 (both, twice)"
echo 0 > /sys/class/power_supply/battery/charge_otg_control 2>/dev/null
echo 0 > /sys/class/power_supply/otg/online 2>/dev/null; sleep 2
echo 0 > /sys/class/power_supply/otg/online 2>/dev/null; sleep 3; M

echo "T4 battery/mode=sensor? (读回) mode=$(cat /sys/class/power_supply/battery/mode 2>/dev/null)"

echo "T5 只写 power_role=sink（PR_SWAP 请求，不碰 port_type）"
echo sink > /sys/class/typec/port0/power_role 2>/dev/null; sleep 4; M

echo "T6 port_type=dual（不动 sink，让它重新评估）"
echo dual > /sys/class/typec/port0/port_type 2>/dev/null; sleep 4; M

echo "final:"; M
echo "dp=$(cat /sys/class/drm/card0-DP-1/status)/$(cat /sys/class/drm/card0-DP-1/enabled)"
