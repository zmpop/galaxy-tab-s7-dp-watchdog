#!/system/bin/sh
# Magisk "执行" button (v1.2.0): launch the USB device selection web UI.
#
# Starts a localhost web server (busybox httpd) serving web/:
#   - auto search of screen-related USB devices
#   - manual listing of all USB devices
#   - save the selected device to /data/adb/tpdp/config
#     (the watchdog daemon hot-reloads it within seconds)
#   - manual link recovery button
# The server auto-shuts-down WEB_TIMEOUT seconds (default 300 = 5 min)
# after it was started, whether or not anything was done.

MODDIR=${0%/*}
LOGDIR=/data/adb/tpdp
WEBROOT="$MODDIR/web"
PORT=8899
PIDFILE="$LOGDIR/web.pid"
BB=/data/adb/magisk/busybox
URL="http://127.0.0.1:$PORT/"

mkdir -p "$LOGDIR"
[ -f "$LOGDIR/config" ] && . "$LOGDIR/config"
: ${WEB_TIMEOUT:=300}

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGDIR/log"; }

# v1.3.0: manual last-resort restore. If the video output is cut while the
# screen is on (e.g. both daemons were killed by hand), pressing the Magisk
# action button restores the picture immediately.
# v1.5.0: refused while external VBUS is absent - forcing HPD high there makes
# the DP link stream over the tablet's own battery, which is the 17:36 panic.
if [ -f "$LOGDIR/video_off" ]; then
    usb_online=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
    if [ "${VBUS_GUARD:-1}" = "1" ] && [ -n "$usb_online" ] && [ "$usb_online" != "1" ]; then
        log "action: force-restore REFUSED - no external VBUS (usb/online=$usb_online)"
        echo "已拒绝强制恢复：未检测到外接屏 PD 供电（usb/online=$usb_online）。"
        echo "此时强拉 HPD 会让 DP 链路在平板自身电池供电下重新上流，是已知会导致内核 panic 的路径。"
        echo "请先接上外接屏的 PD 电源，画面会自动恢复（约 3 秒），或接好后再点一次「执行」。"
    else
        log "action: cut marker present, forcing DP video output on"
        [ -e /sys/kernel/debug/drm_dp/hpd ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
        [ -e /sys/kernel/debug/drm_dp/hpd ] && echo 1 > /sys/kernel/debug/drm_dp/hpd 2>/dev/null
        rm -f "$LOGDIR/video_off"
        echo on > "$LOGDIR/video.state" 2>/dev/null
        sleep 2
        echo "已强制恢复视频输出（若外接屏仍无画面，请重新插拔一线通）。"
    fi
fi

# already running? -> just reopen the page (timer is NOT extended)
if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1
        echo "配置界面已在运行: $URL"
        echo "它将按最初开启时间在 ${WEB_TIMEOUT}s 后自动关闭。"
        exit 0
    fi
    rm -f "$PIDFILE" "$LOGDIR/web.start"
fi

[ -d "$WEBROOT" ] || { echo "错误: $WEBROOT 不存在"; exit 1; }

date +%s > "$LOGDIR/web.start"
nohup "$BB" httpd -f -p 127.0.0.1:$PORT -h "$WEBROOT" >/dev/null 2>&1 &
pid=$!
sleep 1

if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$LOGDIR/web.start"
    echo "错误: Web 服务启动失败（端口 $PORT 可能被占用）"
    log "web: start FAILED on port $PORT"
    exit 1
fi
echo "$pid" > "$PIDFILE"

# hard auto-shutdown timer (server side, authoritative)
nohup sh "$MODDIR/web/autoshut.sh" "$WEB_TIMEOUT" >/dev/null 2>&1 &

am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1
log "web: config UI started on 127.0.0.1:$PORT (pid $pid, timeout ${WEB_TIMEOUT}s)"
echo "USB 设备选择界面已启动"
echo ""
echo "地址: $URL"
echo "自动关闭: ${WEB_TIMEOUT} 秒后（无论是否操作）"
echo "若浏览器未自动打开，请在平板浏览器中访问以上地址。"
