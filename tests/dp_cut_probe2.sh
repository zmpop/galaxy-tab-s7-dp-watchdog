#!/system/bin/sh
H=/sys/kernel/debug/drm_dp
D=/sys/class/drm/card0-DP-1
T=/data/local/tmp
st() {
  printf '  status=%-12s enabled=%-9s dpms=%-4s\n' "$(cat $D/status 2>/dev/null)" "$(cat $D/enabled 2>/dev/null)" "$(cat $D/dpms 2>/dev/null)"
}
try() {
  f=$1; v=$2; rm -f $T/e
  printf '%s' "$v" > "$f" 2>$T/e
  printf '  write %-18s <= [%s] rc=%s err=[%s]\n' "$(basename $f)" "$v" "$?" "$(head -1 $T/e 2>/dev/null)"
}
snap_dmesg() { dmesg 2>/dev/null | wc -l > $T/mark; }
delta() { dmesg 2>/dev/null | tail -n +$(( $(cat $T/mark) + 1 )) | grep -iE "dp_display|usbpd|typec|sde_kms|link_train|video" | sed 's/^/    /'; }

echo "=== link truth: dp_debug (video stream / link training) ==="
cat $H/dp_debug 2>/dev/null | grep -iE "video|link|rate|lane|bpp|mode|pixel|hpd|state" | head -25 | sed 's/^/  /'
echo
echo "=== sink modes (first 3) ==="
head -3 $D/modes 2>/dev/null | sed 's/^/  /'
echo
echo "=== A) hpd=0 : does it REALLY cut? ==="
snap_dmesg; try $H/hpd 0; sleep 3; st; delta
echo
echo "=== B) hpd=1 : restore ==="
snap_dmesg; try $H/hpd 1; sleep 3; st; delta
echo
echo "=== C) after-restore dp_debug video lines ==="
cat $H/dp_debug 2>/dev/null | grep -iE "video|link|rate|lane" | head -12 | sed 's/^/  /'
