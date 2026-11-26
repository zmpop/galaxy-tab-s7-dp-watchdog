#!/system/bin/sh
# Uninstall cleanup hook - executed ONCE by Magisk during the reboot in which
# this module is being removed (after the user taps "移除" in the Magisk app
# and reboots). Magisk deletes the module directory itself; this script removes
# everything the module created OUTSIDE its own directory and undoes every
# side effect it has on the kernel interfaces.
#
# Cleanup manifest:
#   /data/adb/modules/tab_dp_watchdog/   -> removed by Magisk (code, web UI)
#   /data/adb/modules_update/...         -> removed by Magisk (staged update)
#   /data/adb/tpdp/                      -> removed here (config, log, hb.*,
#                                           video.state, video_off, web.pid,
#                                           web.start, screen.ev, pclk_org)
#   daemon / httpd processes             -> killed here (normally gone after
#                                           the reboot; defensive)
#   drm_dp/hpd, max_pclk_khz, port_type  -> restored here
#
# What it deliberately does NOT touch:
#   persist.adb.tcp.port  - set before the module existed (not module-owned)
#   /data/adb/service.d/* - the module installs no boot hook of its own
#   anything outside /data/adb/tpdp - the module writes nowhere else
#
# v1.6.0 fixes three holes found while auditing the removal path:
#   1. `echo 1 > drm_dp/hpd` without checking external VBUS. Forcing HPD high
#      while the tablet is Source (screen PD pulled) re-streams DP on an
#      unsupplied port - the exact kernel-panic path this module exists to
#      prevent. The restore is now gated on usb/online=1.
#   2. `kill $(cat web.pid)` could kill an unrelated process: after a reboot
#      that PID is routinely reused (the same trap hits any module storing a
#      PID across boots). The target is now verified through /proc/<pid>/cmdline.
#   3. `echo dual > port_type` was unconditional; it is now written only when
#      the port is actually pinned to sink (the state the removed governor left
#      behind), so a healthy port is not disturbed.

EXT_VBUS=/sys/class/power_supply/usb/online
HPD=/sys/kernel/debug/drm_dp/hpd
PCLK=/sys/kernel/debug/drm_dp/max_pclk_khz
PORT=/sys/class/typec/port0/port_type

ext_vbus_ok() {
    _u=$(cat "$EXT_VBUS" 2>/dev/null)
    [ -z "$_u" ] && return 0          # node absent (recovery context) -> allow
    [ "$_u" = "1" ] && return 0
    return 1
}

note() { echo "- $*"; }

# 1) stop the daemons (defensive: the reboot normally already did this).
#    The patterns are file paths, so they cannot match this script itself.
for d in service.sh screenvid.sh wakegate.sh otgcut.sh powergate.sh web/autoshut.sh; do
    pkill -f "modules/tab_dp_watchdog/$d" 2>/dev/null
done
if [ -f /data/adb/tpdp/web.pid ]; then
    _wpid=$(cat /data/adb/tpdp/web.pid 2>/dev/null)
    case "$_wpid" in ''|*[!0-9]*) _wpid= ;; esac
    if [ -n "$_wpid" ] && grep -qa 'httpd' "/proc/$_wpid/cmdline" 2>/dev/null; then
        kill "$_wpid" 2>/dev/null && note "stopped web UI (pid $_wpid)"
    fi
fi

# 1b) release the sink gate and un-pin the port. CRITICAL: the v1.8.0 gate
#     pins port_type=sink while the screen has no PD supply, and the sysfs
#     read-back still prints "[dual] source sink" in that state (measured), so
#     a conditional restore based on the read-back would silently leave a
#     sink-only port behind - the tablet could then never charge again.
#     Writing dual is the factory state and is idempotent, so do it always.
if [ -e "$PORT" ]; then
    _pt_before=$(cat "$PORT" 2>/dev/null)
    if echo dual > "$PORT" 2>/dev/null; then
        note "port_type=dual (gate released) - was: $_pt_before"
    else
        note "WARNING: could not write $PORT - check the port manually"
    fi
fi
rm -f /data/adb/tpdp/sink_gate /data/adb/tpdp/sink_gate.ts 2>/dev/null

# 1c) restore the DP pixel clock limit if the refresh selector capped it, so
#     high-bandwidth modes (120Hz) become selectable again.
if [ -f /data/adb/tpdp/pclk_org ] && [ -e "$PCLK" ]; then
    echo "$(cat /data/adb/tpdp/pclk_org 2>/dev/null)" > "$PCLK" 2>/dev/null
    note "DP pixel clock limit restored"
fi

# 1d) restore DP video output - but ONLY with real external power.
#     With usb/online=0 the tablet is Source and feeding the screen from its
#     own battery; forcing HPD high here would re-stream DP on an unsupplied
#     port and can panic the kernel (observed 2026-11-26 17:36). Leaving the
#     link down is harmless: it re-enumerates on the next attach.
if [ ! -e "$HPD" ]; then
    mount -t debugfs none /sys/kernel/debug 2>/dev/null
fi
if [ -e "$HPD" ]; then
    if ext_vbus_ok; then
        echo 1 > "$HPD" 2>/dev/null
        note "DP video output restored (HPD=1)"
    else
        note "DP left OFF: no external VBUS (usb/online=0) - safe, re-enumerates on next attach"
    fi
fi

# 2) remove all module data outside the module directory
rm -rf /data/adb/tpdp
note "removed /data/adb/tpdp (config, logs, state)"

# 3) report: nothing else of ours should be left
left=""
for p in /data/adb/tpdp /data/adb/tpdp.*; do
    [ -e "$p" ] && left="$left $p"
done
if [ -z "$left" ]; then
    note "cleanup complete - nothing outside the module dir remains"
else
    note "WARNING: still present:$left"
fi

exit 0
