#!/system/bin/sh
# install-time script
SKIPUNZIP=0
ui_print "***********************************"
ui_print " Tab S7 DP 显示链路看门狗"
ui_print "***********************************"
ui_print "- target: SM-T870/T970 (SM8250, max77705-usbc)"
ui_print "- detects: touchscreen USB online && extcon DP=0"
ui_print "- action:  port_type sink->dual virtual replug"
ui_print ""
ui_print "Logs:   /data/adb/tpdp/log"
ui_print "Config: /data/adb/tpdp/config (optional)"
ui_print "设备选择界面: Magisk 模块的「执行」按钮"
ui_print "Delete /data/adb/tpdp on uninstall."
ui_print ""
if [ -n "$KSU" ]; then
  ui_print "- installing on KernelSU"
elif [ -n "$APATCH" ]; then
  ui_print "- installing on APatch"
else
  ui_print "- installing on Magisk"
fi

# ---------------------------------------------------------------------------
# File modes. This block is not cosmetic - it is the difference between a
# module that runs and a module that silently does nothing.
#
# Magisk / KernelSU / APatch unpack the zip with unzip, which does NOT restore
# the unix permission bits stored in the archive: every entry lands as 0644
# (measured on this device: a fresh --install-module left service.sh as
# -rw-r--r--). The module loader only starts service.sh / post-fs-data.sh when
# they are executable, so without these chmods the install "succeeds", the
# dashboard shows the new version, and no daemon ever starts.
# ---------------------------------------------------------------------------
for f in service.sh screenvid.sh wakegate.sh otgcut.sh action.sh uninstall.sh customize.sh boot-completed.sh post-fs-data.sh; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done
[ -f "$MODPATH/module.prop" ] && set_perm "$MODPATH/module.prop" 0 0 0644

# web UI: make CGI scripts executable
if [ -d "$MODPATH/web" ]; then
  set_perm_recursive "$MODPATH/web" 0 0 0755 0644
  for f in status devices save recover hz wake enable autoshut.sh; do
    [ -f "$MODPATH/web/cgi-bin/$f" ] && set_perm "$MODPATH/web/cgi-bin/$f" 0 0 0755
  done
  [ -f "$MODPATH/web/autoshut.sh" ] && set_perm "$MODPATH/web/autoshut.sh" 0 0 0755
fi

# v1.9.0: retire files that only existed in older versions. An upgrade keeps
# whatever the previous install left behind (Magisk replaces the directory, but
# a direct/zip-over-copy upgrade does not), and a stale powergate.sh from
# v1.5.x is actively harmful: it drives the port's power role, which is the
# mechanism that ended up feeding the screen from the tablet's battery.
for f in powergate.sh; do
  if [ -f "$MODPATH/$f" ]; then
    rm -f "$MODPATH/$f"
    ui_print "- removed obsolete $f (v1.5.x power role governor)"
  fi
done
rm -f /data/adb/tpdp/hb.power 2>/dev/null

# safety: never install over a state where a previous version left the DP
# video output cut (the external screen would stay black after the reboot).
# v1.6.0: only with real external power. Forcing HPD high while the tablet is
# Source (screen PD pulled) re-streams DP on an unsupplied port, which is the
# kernel-panic path this module exists to prevent.
_usb=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
if [ -e /sys/kernel/debug/drm_dp/hpd ]; then
  if [ -z "$_usb" ] || [ "$_usb" = "1" ]; then
    echo 1 > /sys/kernel/debug/drm_dp/hpd 2>/dev/null
    ui_print "- DP video output forced ON (install-time failsafe)"
  else
    ui_print "- DP left OFF: no external VBUS (usb/online=$_usb), restores when power is back"
  fi
fi
rm -f /data/adb/tpdp/video_off /data/adb/tpdp/video.disabled 2>/dev/null

# v1.6.0: drop leftovers of the phased-out power-role governor (v1.5.1).
# POWER_ROLE_MODE asked the kernel to pin port_type / preferred_role, which this
# platform rejects ("invalid typec_role"), so the option was removed; its config
# key and heartbeat must not survive an upgrade.
rm -f /data/adb/tpdp/hb.power 2>/dev/null
if [ -f /data/adb/tpdp/config ] && grep -q '^POWER_ROLE_MODE=' /data/adb/tpdp/config; then
  sed -i '/^POWER_ROLE_MODE=/d' /data/adb/tpdp/config
  ui_print "- dropped obsolete POWER_ROLE_MODE from config (v1.5.1 governor removed)"
fi
