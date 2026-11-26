#!/system/bin/sh
D=/sys/class/drm/card0-DP-1
H=/sys/kernel/debug/drm_dp/hpd
st() {
  printf '  status=%-12s enabled=%-8s dpms=%-8s hpd_raw=[%s] usb=%s otg=%s role=%s ma=%s\n' \
    "$(cat $D/status 2>/dev/null)" "$(cat $D/enabled 2>/dev/null)" "$(cat $D/dpms 2>/dev/null)" \
    "$(cat $H 2>/dev/null)" "$(cat /sys/class/power_supply/usb/online 2>/dev/null)" \
    "$(cat /sys/class/power_supply/otg/online 2>/dev/null)" "$(cat /sys/class/typec/port0/power_role 2>/dev/null)" \
    "$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)"
}
echo "=== DP-1 sysfs nodes ==="
ls $D
echo
echo "=== T0 baseline ==="
st
echo
echo "=== T1 write hpd=0 -> does the stream actually drop? ==="
echo 0 > $H 2>&1
sleep 2; st
echo
echo "=== T2 write hpd=1 (restore) ==="
echo 1 > $H 2>&1
sleep 2; st
echo
echo "=== T3 dpms Off (real DPMS path) ==="
echo Off > $D/dpms 2>&1; sleep 2; st
echo "=== T4 dpms On ==="
echo On > $D/dpms 2>&1; sleep 2; st
echo
echo "=== kernel dp messages (last 40) ==="
dmesg 2>/dev/null | grep -iE "dp_display|sde_kms|usbpd|0x15f|SError" | tail -40
