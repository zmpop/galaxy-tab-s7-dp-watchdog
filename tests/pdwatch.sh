#!/system/bin/sh
# 200ms sampler for one PD pull + replug. Survives adb disconnect (nohup).
OUT=/data/local/tmp/pdwatch.csv
D=/sys/class/drm/card0-DP-1
DBG=/sys/kernel/debug/drm_dp/dp_debug
: > "$OUT"
echo "t,usb,otg,role,ma,status,enabled,pclk,dpstate,res" >> "$OUT"
end=$(( $(date +%s) + ${1:-300} ))
while [ "$(date +%s)" -lt "$end" ]; do
    role=$(cat /sys/class/typec/port0/power_role 2>/dev/null | tr -d ' ' | sed 's/\[/</;s/\]/>/')
    pclk=$(grep -m1 'pclock=' "$DBG" 2>/dev/null | sed 's/.*pclock=//; s/KHz//')
    st=$(grep -m1 'state=' "$DBG" 2>/dev/null | sed 's/.*state=//')
    res=$(grep -m1 'resolution=' "$DBG" 2>/dev/null | sed 's/.*resolution=//')
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date +%s)" \
        "$(cat /sys/class/power_supply/usb/online 2>/dev/null)" \
        "$(cat /sys/class/power_supply/otg/online 2>/dev/null)" \
        "$role" \
        "$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)" \
        "$(cat $D/status 2>/dev/null)" \
        "$(cat $D/enabled 2>/dev/null)" \
        "${pclk:-na}" "${st:-na}" "${res:-na}" >> "$OUT"
    sleep 0.2 2>/dev/null || sleep 1
done
echo done >> "$OUT"
