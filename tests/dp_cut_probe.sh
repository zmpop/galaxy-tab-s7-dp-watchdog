#!/system/bin/sh
H=/sys/kernel/debug/drm_dp
D=/sys/class/drm/card0-DP-1
st() {
  printf '  status=%-12s enabled=%-9s dpms=%s\n' "$(cat $D/status 2>/dev/null)" "$(cat $D/enabled 2>/dev/null)" "$(cat $D/dpms 2>/dev/null)"
}
try() { # try <file> <value>
  f=$1; v=$2
  printf '%s' "$v" > "$f" 2>/tmp/e
  rc=$?
  err=$(cat /tmp/e 2>/dev/null)
  printf '  write %-40s <= [%s]  rc=%s %s\n' "${f#/sys/kernel/debug/drm_dp/}" "$v" "$rc" "$err"
}
clear_e() { dmesg 2>/dev/null | tail -1 | sed 's/.*\] //' > /tmp/mark; }

echo "=== debugfs drm_dp node permissions ==="
ls -la $H | sed 's/^/  /'
echo
echo "=== baseline ==="
st
echo
echo "=== A) hpd write with explicit rc ==="
try $H/hpd 0; sleep 2; st
echo "  (dmesg delta:)"; dmesg 2>/dev/null | tail -6 | sed 's/^/    /'
echo
try $H/hpd 1; sleep 2; st
echo
echo "=== B) connected node write 0 ==="
try $H/connected 0; sleep 2; st
echo "  (dmesg delta:)"; dmesg 2>/dev/null | tail -8 | sed 's/^/    /'
echo
echo "=== C) restore via port_type virtual replug ==="
echo "  before: port_type=$(cat /sys/class/typec/port0/port_type 2>/dev/null)"
printf 'sink' > /sys/class/typec/port0/port_type 2>/tmp/e; echo "  sink write rc=$? $(cat /tmp/e 2>/dev/null)"
sleep 2; st
printf 'dual' > /sys/class/typec/port0/port_type 2>/tmp/e; echo "  dual write rc=$? $(cat /tmp/e 2>/dev/null)"
sleep 4; st
echo
echo "=== D) final dmesg (dp/usbpd, last 25) ==="
dmesg 2>/dev/null | grep -iE "dp_display|usbpd|typec|sde_kms|NoC|SError" | tail -25 | sed 's/^/  /'
