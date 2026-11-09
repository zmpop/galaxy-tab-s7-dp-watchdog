#!/system/bin/sh
# Uninstall cleanup hook - executed ONCE by Magisk during the reboot in
# which this module is being removed (after user taps "卸载" in Magisk app
# and reboots). Magisk deletes the module directory itself; this script
# removes everything the module created OUTSIDE its own directory.
#
# Cleanup manifest:
#   /data/adb/modules/tab_dp_watchdog/   -> removed by Magisk (code, web UI)
#   /data/adb/modules_update/...         -> removed by Magisk (staged updates)
#   /data/adb/tpdp/                      -> removed here (config, log,
#                                           web.pid, web.start)
#   watchdog daemon / httpd processes    -> killed here (normally already
#                                           gone after reboot; defensive)
#
# The module creates no database, no Android registry entries, no caches
# outside /data/adb/tpdp, and no persistent system properties. The only
# system property ever touched (persist.adb.tcp.port) is a user-level
# wireless ADB convenience set BEFORE the module existed and is NOT
# module-owned - it is intentionally left untouched.

# 1) stop processes (defensive; reboot has normally already done this)
pkill -f "modules/tab_dp_watchdog/service.sh" 2>/dev/null
pkill -f "modules/tab_dp_watchdog/web/autoshut.sh" 2>/dev/null
if [ -f /data/adb/tpdp/web.pid ]; then
    kill "$(cat /data/adb/tpdp/web.pid 2>/dev/null)" 2>/dev/null
fi

# 2) remove all module data outside the module directory
rm -rf /data/adb/tpdp

exit 0
