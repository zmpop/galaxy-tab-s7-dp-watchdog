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

## 八、2026-11-26 新增定案:拔掉屏幕 PD 供电导致内核 panic

### 现象

一线通正常工作,从**屏幕端**拔掉 PD 供电线(USB-C 数据线仍连着)后,平板在数秒到
十几秒内直接重启。不是软重启:三星 `power_off_reset_reason.txt` 没有记录,真正的
死因在 `ro.boot.bootreason`(`kernel_panic,asynchroomus_serror_ilterrupt`)与
RAMDUMP 的 `eRR.p` 里(同一签名 4 次:`RWC 80/83/86/89`)。

### 完整链条(kmsg + power_supply 逐帧对齐)

```
t+0.0s  屏幕 PD 供电被拔:usb/online 1 -> 0
t+0.5s  MUIC 判 OTG:port0 power_role sink -> source,otg/online=1
        电池放电 ~1.9A,Vbat 3.90V -> 3.73V(平板在给屏供电)
t+1~3s  DP 链路掉一次(屏幕侧掉电)-> 模块判"亮屏但视频没了"-> restore_video
        [sh: 1837] dp_display_usbpd_configure_cb: +++     <- echo 1 > drm_dp/hpd
        dp_display_enable: add DP_STATE_ENABLED  2560x1600@60(pclk 268.5/300MHz)
t+X    用户把 PD 插回 -> USB PD VDM 重协商
        dp_display_disconnect_sync: DP_STATE_ABORTED state(0x15f)
        sde_kms_wait_for_commit_done -110   x2
        TZBSP_ERR_FATAL_NOC_ERROR -> MM NoC fatal -> SError(NMI) -> panic
```

### 关键反证(为什么不是"欠压"或"断电"本身)

- 同一个 boot 里 `0x15f` 出现 **2 次**都没有 panic;
- 拔掉 PD 后把链路**彻底拆干净**(不再拉高 HPD),连续 4 次拔插全部正常,
  `R22/R24/R27` 计数为 0,boot_id 不变;
- 复测间隔 18.2s / 38.0s / 10.3s / 10.0s 均通过。

结论:致死的不是断电,而是**断电后视频流又被软件拉活,然后二次拆链**——
`HPD` 拉低时 DRM 侧的视频流仍为 ENABLED,commit 路径等不到完成,MM NoC 报致命错误,
TrustZone 收到 SError 后触发安全看门狗复位。

### 为什么不能从源头阻止(无效杠杆)

| 尝试 | 结果 |
|---|---|
| `port0/preferred_role = sink` | `invalid typec_role`,内核拒绝写入 |
| `port0/port_type = sink`(partner 挂着时) | `max77705_port_type_set: invalid typec_role`,3 次尝试 100% 失败 |
| 压 `otg/online = 0` | 内核会自行重开 boost,软件开关无效 |

角色翻转无法从软件阻止,所以唯一有效的阻断点是**不让 DP 在无外部供电时重新上流**。

### v1.6.0 修复点

所有会把 HPD 拉高(或等效重新上流)的路径前校验 `usb/online == 1`:

| 文件 | 位置 |
|---|---|
| `screenvid.sh` | `restore_video()` 拉高 HPD 前;主循环 VBUS 边沿守卫(主动 `hpd=0` + 每 3s 复核) |
| `service.sh` | `boot_video_failsafe()`、`hz_reevaluate()`、陈旧 `video_off` 标记清理、`virtual_replug()` 及故障恢复主循环 |
| `action.sh` | 「执行」按钮的强制恢复 |
| `web/cgi-bin/hz` | 刷新率切换后的链路重枚举 |
| `web/cgi-bin/recover` | Web 界面的手动恢复 |

供电判定:外部供电在位 `usb/online=1` / `power_role=sink` / `otg/online=0` / 电池充电;
缺失时 `usb/online=0` / `power_role=source` / `otg/online=1` / 放电约 1.9A。
节点不存在(安装/卸载环境)不拦截。

行为:PD 断电期间外接屏不显示(预期),PD 接回约 3 秒画面自动恢复;息屏/亮屏切换
在供电正常时行为完全不变。逃生口 `VBUS_GUARD=0`(不推荐)。
