# 根因分析:Galaxy Tab S7 一线通(DP Alt Mode)外接触摸屏黑屏问题

> 实验环境:SM-T970(SM8250),One UI 5 / Android 13,Magisk 28.1,
> 一线通 USB-C 全功能线(视频+触摸+反向供电),外接触摸屏 2560×1600@120Hz(ELAN 04f3:8512)。
> 所有结论均经 ADB 实时采集的内核日志与状态时间线验证。

## 一、问题现象

| # | 现象 |
|---|---|
| 1 | 单独插一线通(屏幕无外部供电):平板有连接提示音,屏幕黑屏 |
| 2 | 正确顺序(先屏幕供电、后一线通)才显示;先插线后供电则黑屏,必须重新拔插一线通 |
| 3 | 重启平板后黑屏,必须重新拔插一线通 |
| 4 | 从屏幕端拔插 PD 供电线后黑屏;从电源端拔插同一根线则很快恢复 |

## 二、核心机制:DP Alt Mode 协商是"边沿触发、一次性"的

USB-C 视频链路的建立需要依次完成:

```
① CC 附着检测(听到提示音=仅完成此步)
② PD 供电协商
③ VDM 能力发现(Discover Identity / SVIDs / Modes)
④ Enter Mode + DP Configure(Pin Assignment)
⑤ HPD 置位(屏幕宣告"我在这")
⑥ DP AUX/EDID 链路训练
⑦ 出画面
```

**关键**:这套握手只在 CC attach 边沿触发时执行一次。协商失败/中断后,
规范上不会自动重试;对端后续上电、本端重启,都不会重新发起——
除非再次出现 detach→attach 边沿(物理拔插,或本模块的虚拟拔插)。

## 三、逐现象根因

### 现象 1/2:屏幕供电与协商顺序

- 平板作 source 只能输出 5V/约 0.9A,点不亮屏幕背光 → 屏幕必须外部供电(正常设计)。
- 屏幕未上电时,其 CC 下拉电阻可从平板的 VBUS 5V"寄生供电"维持存活 →
  平板检测到附着并响提示音,但 PD/VDM 无应答 → 协商停在 ③④。
- 屏幕事后上电不会触发平板重试(无新边沿)→ 黑屏。
- 本模块的解法:屏幕上电、触摸 USB 枚举后,由看门狗主动制造边沿。

### 现象 3:重启后黑屏(实测证据)

重启后采集到的状态:

```
Type-C partner: PRESENT(附着从未断开,CC 上的 Rd 一直在线)
extcon0:        DP=0(外接屏按"已断开"处理)
dp_debug:       全零(DP 链路完全未重建)
DisplayManager: 只剩内置屏
```

平板侧状态机随重启清零,但对端(屏幕)持续上电、保持附着——
双方互相"等对方先开口",没有 detach 边沿就永远不重新协商。

### 现象 4:PD 供电线拔插位置差异(实测时间线)

监控采样(1 秒粒度)捕获的完整过程:

**从屏幕端拔插(故障路径)**

```
T+0    拔线:屏幕整机 brown-out 猝死,触摸消失,DP=0
       平板立刻翻转为 [source],用 5V 寄生维持视频口 CC(partner 不掉)
T+3    插回:屏幕快速启动,以 sink 身份挂上(吃平板电池,实测峰值 -2069mA),
       DP 一度恢复
T+15   屏幕策略引擎要拿回 source 角色(正常工作时要反向给平板供电),
       角色翻转触发异常 detach,平板侧内核日志:
         max77705_detach_pd : Detach PD CHARGER
         max77705_port_type_set: invalid typec_role   ← 三星驱动状态机落入非法态
       之后 partner 在 0/1 间震荡、CC 事件持续风暴,端口永久卡死 → 黑屏
```

**从电源端拔插(恢复路径)**

```
拔线:充电头自身状态机复位(旧 PD 合同、VBUS 状态全部归零)
插回:平板获得全新附着流程 → 屏幕以 sink 过渡挂上 → 角色交换干净完成
      → 受电恢复,全程约 7 秒
```

**本质差异**:拔屏幕端时,充电头那边"从未拔出过"——
CC 断开确认需 tCCDebounce(≈100-200ms)、VBUS 下电更慢,
快速插回等于旧合同原样续期、屏幕带电热启动骑上平板残留的附着状态;
拔电源端时整条供电链的协商状态被彻底归零,全链路走一遍全新流程。

## 四、为什么"虚拟拔插"有效

向 `/sys/class/typec/port0/port_type` 依次写入 `sink`、`dual`,
会让 Type-C 控制器(MAX77705)执行一次 CC 电气状态切换——
等效于物理拔插产生的 detach→attach 边沿,
从而重新触发 ②~⑦ 的完整协商链。实测在故障态下执行,
约 5 秒恢复 2560×1600@120Hz + 触摸,与物理拔插效果一致。

## 五、验证过的无效方案(避坑)

| 方案 | 结果 |
|---|---|
| `msm-dp-display` 驱动 unbind/rebind | 内核未暴露 unbind 属性,不可行 |
| `max77705-usbc` 驱动 unbind/rebind | 端口复位后 CC 附着检测不恢复,还导致 ADB 掉线 |
| DRM debugfs `force detect` | HPD 信号路径未建立,无效 |
| 智能插座切断屏幕电源"模拟拔插" | 无效——平板 VBUS 维持 CC 附着,对平板而言线从未拔出 |

## 六、诊断速查

```bash
# DP 链路状态(DP=1 健康)
adb shell su -c 'cat /sys/class/extcon/extcon0/state'
# DP 链路细节(速率/通道/分辨率)
adb shell su -c 'cat /sys/kernel/debug/drm_dp/dp_debug'
# 触摸屏 USB 是否在线(04f3:8512)
adb shell su -c 'ls /sys/bus/usb/devices/'
# Type-C 端口与对端
adb shell su -c 'cat /sys/class/typec/port0/{data_role,power_role}'
# 内核 CC/PD 事件
adb shell su -c 'dmesg | grep -iE "max77705|ccic|uvdm" | tail -30'
```

## 七、原始实验数据

完整 1 秒粒度监控时间线见
[monitor-log-2026-11-09.txt](monitor-log-2026-11-09.txt)
(含屏幕端拔插故障路径与电源端拔插恢复路径的对照)。
