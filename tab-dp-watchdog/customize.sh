#!/system/bin/sh
# install-time script
SKIPUNZIP=0
ui_print "***********************************"
ui_print " Tab S7 DP Link Watchdog"
ui_print "***********************************"
ui_print "- target: SM-T870/T970 (SM8250, max77705-usbc)"
ui_print "- detects: touchscreen USB 04f3:8512 online && extcon DP=0"
ui_print "- action:  port_type sink->dual virtual replug"
ui_print ""
ui_print "Logs:   /data/adb/tpdp/log"
ui_print "Config: /data/adb/tpdp/config (optional)"
ui_print "Delete /data/adb/tpdp on uninstall."
ui_print ""
if [ -n "$KSU" ]; then
  ui_print "- installing on KernelSU"
elif [ -n "$APATCH" ]; then
  ui_print "- installing on APatch"
else
  ui_print "- installing on Magisk"
fi
