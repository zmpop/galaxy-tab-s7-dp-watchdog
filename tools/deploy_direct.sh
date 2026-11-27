#!/system/bin/sh
# Install tab-dp-watchdog without `magisk --install-module`.
#
# Fallback path, kept because it is byte-equivalent and needs no Magisk CLI at
# all (works from TWRP or when the installer refuses). The original reason this
# existed - "the CLI installer is broken on this device" - was wrong: every zip
# failed because build.py wrote each entry under a 'tab-dp-watchdog/' prefix,
# so the installer looked for ./module.prop and found a directory. Fixed in
# v1.9.0 (root module.prop + META-INF/com/google/android/update-binary);
# see docs/troubleshooting.md section 9.
#
# A Magisk module is just a directory under /data/adb/modules with a module.prop;
# this module ships no system overlay, only root-run scripts, so a byte-exact
# placement is functionally identical to what the installer would produce.

set -u
# zip name is derived from module.prop in this checkout, so a version bump does
# not silently deploy yesterday's package
VER=$(grep '^version=' "$(dirname "$0")/../tab-dp-watchdog/module.prop" 2>/dev/null | cut -d= -f2)
[ -n "${VER:-}" ] || VER=unknown
# explicit argument wins: when this script runs from /data/local/tmp the repo
# relative path above does not exist, so VER would be "unknown"
if [ -n "${1:-}" ]; then
    Z=$1
else
    Z=/sdcard/Download/tab-dp-watchdog-$VER.zip
fi
DEST=/data/adb/modules/tab_dp_watchdog
TMP=/data/local/tmp/inst_deploy

say() { echo "[install] $*"; }

say "source: $Z"
say "sha256: $(sha256sum "$Z" 2>/dev/null | cut -d' ' -f1)"

rm -rf "$TMP"
mkdir -p "$TMP"
/data/adb/magisk/busybox unzip -o "$Z" -x 'META-INF/*' -d "$TMP" >/dev/null 2>&1
# v1.9.0+ archives put module.prop at the zip root (that is what Magisk needs);
# the old tab-dp-watchdog/ prefix was the bug that made every install fail.
# Accept both so this fallback path keeps working with old and new packages.
if [ -d "$TMP/tab-dp-watchdog" ]; then
    SRC=$TMP/tab-dp-watchdog
elif [ -f "$TMP/module.prop" ]; then
    SRC=$TMP
else
    say "FATAL: unexpected zip layout (no module.prop at root, no tab-dp-watchdog/)"
    exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$SRC/." "$DEST/"
say "extracted $(find "$DEST" -type f | wc -l) files into $DEST"

# permissions: Magisk's set_perm_recursive equivalent
chown -R 0:0 "$DEST"
find "$DEST" -type d -exec chmod 0755 {} \;
find "$DEST" -type f -exec chmod 0644 {} \;
for f in "$DEST"/*.sh "$DEST"/web/autoshut.sh "$DEST"/web/cgi-bin/*; do
    [ -f "$f" ] && chmod 0755 "$f"
done
say "permissions set (scripts 0755, data 0644, owner root:root)"

# what customize.sh would have done, minus the ui_print noise:
#  - no DP failsafe write here: install-time HPD forcing is pointless in a
#    running system (the link is already up) and risky without VBUS.
#  - drop leftovers of the removed v1.5.1 power governor
rm -f /data/adb/tpdp/hb.power /data/adb/tpdp/video_off /data/adb/tpdp/video.disabled 2>/dev/null
if [ -f /data/adb/tpdp/config ] && grep -q '^POWER_ROLE_MODE=' /data/adb/tpdp/config; then
    sed -i '/^POWER_ROLE_MODE=/d' /data/adb/tpdp/config
    say "dropped obsolete POWER_ROLE_MODE from config"
fi

# no 'disable' / 'remove' / 'update' marker => enabled and clean
rm -f "$DEST/disable" "$DEST/remove" "$DEST/update" "$DEST/skip_mount" 2>/dev/null

say "---- verify ----"
grep -E '^(id|name|version|versionCode)=' "$DEST/module.prop" | sed 's/^/  /'
say "powergate present? $([ -e "$DEST/powergate.sh" ] && echo YES-BAD || echo no)"
say "backup files present? $(ls "$DEST" | grep -c '\.bak-') (expect 0)"
say "uninstall guard present? $(grep -c 'external VBUS' "$DEST/uninstall.sh") (expect >=1)"
say "VBUS guard in screenvid? $(grep -c 'ext_vbus_ok' "$DEST/screenvid.sh") (expect >=1)"
say "file list:"
find "$DEST" -type f | sed 's|/data/adb/modules/tab_dp_watchdog/|  |' | sort
exit 0
