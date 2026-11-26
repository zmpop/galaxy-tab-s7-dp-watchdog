#!/system/bin/sh
# 目标：找出"能让平板不往外供 5V"的可写杠杆
# 安全前提：外屏 PD 在位（usb/online=1），此时任何角色实验都不会重演 panic
R() { echo "  usb=$(cat /sys/class/power_supply/usb/online 2>/dev/null)" \
          "otg=$(cat /sys/class/power_supply/otg/online 2>/dev/null)" \
          "role=$(cat /sys/class/typec/port0/power_role 2>/dev/null)" \
          "ptype=$(cat /sys/class/typec/port0/port_type 2>/dev/null | tr -d ' ')" \
          "dp=$(cat /sys/class/drm/card0-DP-1/status 2>/dev/null)/$(cat /sys/class/drm/card0-DP-1/enabled 2>/dev/null)" \
          "pclk=$(grep -m1 pclock= /sys/kernel/debug/drm_dp/dp_debug 2>/dev/null | sed 's/.*pclock=//;s/KHz.*//')" \
          "ma=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)"; }

DM() { dmesg | wc -l; }
DELTA() { local n=$1; dmesg | tail -n +$((n+1)) | grep -aiE "typec|max77705_port|usbpd|dp_display_usbpd|otg|dp_display_disconnect|dp_display_enable" | head -8; }

echo "=== T0 baseline ==="; R
N=$(DM)

echo
echo "=== T1  echo sink > port0/port_type ==="
echo sink > /sys/class/typec/port0/port_type 2>&1
echo "  write rc=$?"
sleep 3; R; echo "  -- kernel delta --"; DELTA $N

echo
echo "=== T2  restore dual ==="
N=$(DM)
echo dual > /sys/class/typec/port0/port_type 2>&1
echo "  write rc=$?"
sleep 4; R; echo "  -- kernel delta --"; DELTA $N

echo
echo "=== T3  battery/charge_otg_control = 0 ==="
N=$(DM)
echo 0 > /sys/class/power_supply/battery/charge_otg_control 2>&1
echo "  write rc=$? (readback=$(cat /sys/class/power_supply/battery/charge_otg_control))"
sleep 3; R; echo "  -- kernel delta --"; DELTA $N

echo
echo "=== T4  otg/online = 0 ==="
N=$(DM)
echo 0 > /sys/class/power_supply/otg/online 2>&1
echo "  write rc=$? (readback=$(cat /sys/class/power_supply/otg/online))"
sleep 3; R; echo "  -- kernel delta --"; DELTA $N

echo
echo "=== 最终状态（必须回到健康）==="; R
