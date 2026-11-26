#!/system/bin/sh
H=/sys/kernel/debug/drm_dp
D=/sys/class/drm/card0-DP-1
T=/data/local/tmp
st() { printf '  status=%-12s enabled=%-9s | %s\n' "$(cat $D/status 2>/dev/null)" "$(cat $D/enabled 2>/dev/null)" "$(cat $H/dp_debug 2>/dev/null | tr '\n' ' ' | sed 's/\t/ /g' | cut -c1-140)"; }

echo "=== before ==="; st
dmesg 2>/dev/null | wc -l > $T/mark

echo "=== screen OFF (forces DP encoder disable) ==="
input keyevent 26
sleep 3; st

echo "=== screen ON (forces full DP re-enable) ==="
input keyevent 26
sleep 5; st

echo "=== kernel delta ==="
dmesg 2>/dev/null | tail -n +$(( $(cat $T/mark) + 1 )) | grep -iE "dp_display|sde_kms|usbpd|0x15f|SError|NoC" | tail -30 | sed 's/^/  /'
