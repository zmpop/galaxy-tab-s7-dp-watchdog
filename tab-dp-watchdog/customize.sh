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

# web UI: make CGI scripts executable
if [ -d "$MODPATH/web" ]; then
  set_perm_recursive "$MODPATH/web" 0 0 0755 0644
  for f in status devices save recover autoshut.sh; do
    [ -f "$MODPATH/web/cgi-bin/$f" ] && set_perm "$MODPATH/web/cgi-bin/$f" 0 0 0755
  done
  [ -f "$MODPATH/web/autoshut.sh" ] && set_perm "$MODPATH/web/autoshut.sh" 0 0 0755
fi

# safety: never install over a state where a previous version left the DP
# video output cut (the external screen would stay black after the reboot)
if [ -e /sys/kernel/debug/drm_dp/hpd ]; then
  echo 1 > /sys/kernel/debug/drm_dp/hpd 2>/dev/null
  ui_print "- DP video output forced ON (install-time failsafe)"
fi
rm -f /data/adb/tpdp/video_off /data/adb/tpdp/video.disabled 2>/dev/null
