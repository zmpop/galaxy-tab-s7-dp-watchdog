# galaxy-tab-s7-dp-watchdog

**Magisk module — Samsung Galaxy Tab S7 USB-C DP Alt Mode 外接屏断链自动恢复看门狗**

[![Release](https://img.shields.io/badge/release-v1.11.0-blue)](../../releases)
[![Platform](https://img.shields.io/badge/device-SM--T870%2FT970%20(SM8250)-green)](#兼容性)
[![Root](https://img.shields.io/badge/requires-Magisk%20root-orange)](#安装)

## 这是什么

Galaxy Tab S7（Snapdragon 865+ / SM8250）通过 USB-C 一线通（DP Alt Mode）外接触摸屏时，存在一类"黑屏后必须物理重新拔插线缆才能恢复"的顽固问题。本模块以 root 守护进程方式监视 DP 链路状态，在断链发生时自动执行**软件级虚拟拔插**（Type-C `port_type` 切换），强制 CC/PD/VDM/DP 全链路重新协商，无需任何物理操作即可恢复画面与触摸。

实测闭环验证：重启后黑屏场景，开机 25 秒检出故障、6 秒完成恢复（2560×1600@120Hz + 触摸完整恢复）。

## 覆盖的故障场景

| # | 场景 | 触发条件 | 检测版本 |
|---|---|---|---|
| 1 | 重启平板后黑屏 | 触摸屏 USB 在线 && `extcon DP=0` | v1.0.0 |
| 2 | 先插一线通、后给屏幕供电，黑屏 | 同上（触摸屏上电枚举后接管） | v1.0.0 |
| 3 | 运行中 DP 链路偶发掉线 | 同上 | v1.0.0 |
| 4 | 从屏幕端拔插 PD 供电线后端口卡死 | 本次开机 DP 曾=1 && 现=0 && partner 在线/震荡 | v1.1.0 |
| 5 | 拔掉屏幕 PD 供电后平板**异常重启**（内核 panic） | `usb/online=0` 且 `power_role=source`（平板在给屏供电） | v1.6.0 |
| 6 | 拔掉屏幕 PD 后屏幕**仍有电**（平板以 ~1.9A 反供） | 同上，且对端支持 PD 或本次开机 DP 亮过 | v1.9.1 |
| 7 | 恢复阶梯跑到一半被拔掉 PD，仍会强拉 HPD（panic 窗口） | 阶梯执行中 `usb/online` 变 0 | v1.9.2 |
| 8 | 息屏后外接屏**继续显示**（视频没被切断） | 屏幕 off 而 `pclk>0`，`cut_video()` 只写标记不动链路 | v1.11.0 |

平板单独使用（本次开机从未连接过屏幕）永不误触发；连接普通 PD 充电器、U 盘等 USB 配件不误触发。

> 场景 5/6/7 是同一根因的三个面：拔 PD 后平板翻 Source，用电池给屏供电（约 1.9A）。
> v1.6.0 只做到「不再因此崩溃」，v1.9.1 才做到「真的断电」，v1.9.2 补上了「恢复中途被拔」的窗口。

## 拔屏幕 PD 电源不再异常重启（v1.6.0）

拔掉屏幕端的 PD 供电线会让平板翻成 Source、用自身电池给屏供电（实测放电约 1.9A）。
此时若模块仍按"亮屏但视频没了"去 `echo 1 > drm_dp/hpd`，DP 会在**没有外部供电的端口上
重新上流**；PD 插回触发 VDM 重协商时，HPD 拉低而流仍 ENABLED，commit 路径死锁：

```
DP_STATE_ABORTED state(0x15f) -> sde_kms_wait_for_commit_done -110 x2
-> TZBSP_ERR_FATAL_NOC_ERROR -> SError(NMI) -> panic (安全看门狗复位)
```

v1.6.0 在所有"HPD 拉高 / 重新上流"路径前校验 `usb/online=1`（真实外部供电）：
无供电时主动把链路按下去并保持关闭，**PD 接回后约 3 秒画面自动恢复**，不再重启。
断电期间外接屏不显示是预期行为（宁可黑屏，不要重启）。详见
[tab-dp-watchdog/README.md](tab-dp-watchdog/README.md#外部供电守卫拔掉屏幕-pd-电源不再重启v150)。

## 拔掉屏幕 PD 后真正切断对外 5V（v1.9.1）

v1.6.0 解决了「不崩溃」，但拔掉 PD 后屏幕**仍然有电**——平板翻成 Source，用自身电池
给屏供电（实测约 1.9A）。要让屏幕真的断电，得把平板的 5V boost 关掉，而这台机器上
几乎所有直觉做法都无效：

| 杠杆 | 实测结果 |
|---|---|
| `hpd=1`（拉高） | DP 恢复（`pclk` 0→268500）；无供电时这就是 panic 路径，不能用 |
| `hpd=0`（拉低） | 切 DP 有效（1 秒内 `pclk=0`），但**只切视频、不切 5V**——屏依旧被平板供电 |
| `port_type=sink` | 立刻断链，但内核约 48 秒后重新装回 Source，期间仍供 1.3–1.5A；partner 挂着时更直接报 `invalid typec_role` 拒绝写入 |
| `power_role=sink`（PR_SWAP） | 无效，回读仍 `[source]` |
| `otg/online=0` 单次写 | 无效，充电驱动 1 秒内重新打开 |
| **`otg/online=0` 持续压制（每 200ms）** | **有效，真正切断** |
| 熄屏 | 有效，但会连带拆掉整条链路，不能用来「保画面只断电」 |

> `hpd` 是**边沿**杠杆：只在 1→0 / 0→1 时动作，写同一个值毫无反应。v1.7.0 曾因此
> 把 `hpd=0` 记成「空操作」并删掉它，导致息屏不再切视频（v1.11.0 已修复，见文末）。

所以 v1.9.1 新增 `otgcut.sh`：外部 VBUS 连续 3 次采样缺失后接管，每 200ms 把
`otg/online` 按回 0；PD 回来连续 20 次采样才释放。带安全闸——只有**对端声明支持 PD
或本次开机 DP 亮过**才压制，避免把普通 USB-OTG 会话（U 盘）也断电。

```
20:56:49 [otgcut] external VBUS gone - cutting the tablet 5V boost
20:56:49 [otgcut] otg boost cut #1 (was=1 -> 0) ma=-984
```

判断「到底断没断电」看放电电流，别靠摸屏：

```bash
adb shell su -c 'watch -n1 "cat /sys/class/power_supply/battery/current_now; cat /sys/class/power_supply/otg/online"'
# -1900 左右 = 仍在给屏供电；-700 以上 = 已停供，只剩平板自身功耗
```

## 恢复阶梯中途被拔 PD 立即中止（v1.9.2）

`restore_video()` 的恢复阶梯（虚拟拔插 2s + 12 次轮询 + 4 次轮询 + 熄屏亮屏 6 次）要跑
20 多秒。v1.9.1 之前只在**入口**检查一次外部供电，阶梯跑到一半拔线仍会一路走到
`hpd=1`——正是 17:36 panic 的那条路径。现在每一级执行前、以及每个轮询里都复查，供电
一消失立即中止并保持链路关闭：

```
restore ABORTED at step1/poll: external VBUS disappeared mid-repair (...) - holding the link down instead of forcing HPD
```

## 息屏自动切断视频输出（v1.3.0）

反方向的省电能力：**按电源键息屏 → 立即停掉对外接屏的 DP 视频信号；亮屏 → 自动恢复**。
实测切断约 1.1s、恢复约 1.1s，息屏期间触摸与供电不受影响。

> 这段能力在 v1.7.0 被误删过：当时把 `hpd=0` 判成「空操作」，`cut_video()` 从此只写
> 标记、不动链路，息屏后外接屏一直显示（2026-11-27 真机复现，`pclock` 全程 268500）。
> 根因是 `hpd` 只在**边沿**上动作——v1.7.0 是在 HPD 已经是 1 的链路上写的 1，当然毫无
> 反应。v1.11.0 恢复真切，并补上「切断期间每 15 秒重压一次」（内核约 5 秒会自己把
> `status` 抬回 `connected`）与新的判活标准 `enabled=disabled && pclk=0`。

```
息屏切换:  echo 0 > /sys/kernel/debug/drm_dp/hpd   # 连接器断开、链路拆除
亮屏恢复:  echo 1 > /sys/kernel/debug/drm_dp/hpd   # 重新训练链路、画面回来
检测:      logcat -b events -s screen_toggled  (事件驱动)
           dumpsys power mWakefulness          (3~15s 轮询兜底)
```

为杜绝"永久黑屏"，设计了多层恢复：切换失败重试→自动停用并保持视频开启；双守护心跳互检与
自动拉起；崩溃重启后按实际屏幕状态自对齐；恢复失败降级 `port_type` 重放；开机/卸载/安装
均强制恢复视频；Magisk「执行」按钮可一键强制恢复。完整状态机与异常矩阵见
[tab-dp-watchdog/README.md](tab-dp-watchdog/README.md#息屏切断视频输出v130)。

## 安装

1. Magisk app → 模块 → 从本地安装 → 选择 [Releases](../../releases) 中的 `tab-dp-watchdog-vX.Y.Z.zip`
2. 重启
3. 完成。日志位于 `/data/adb/tpdp/log`

## 卸载

Magisk app → 模块 → 本模块 → 「移除」→ 重启。重启时 Magisk 删除模块目录并执行
`uninstall.sh`：杀掉全部守护（`service` / `screenvid` / `wakegate` / `otgcut`，kill 前校验
`/proc/<pid>/cmdline`，不误杀复用 PID 的进程，`otgcut` 退出即把 `otg/online` 交还内核）、
还原内核改动（像素时钟上限、被钉住的 `port_type`、DP 视频输出）、删除 `/data/adb/tpdp`，
最后在安装日志打印 `cleanup complete`。

模块不写 `service.d` / `post-fs-data.d`、不改系统属性、不建数据库，因此移除后
`/data/adb` 下不留任何本模块文件。自检：

```bash
adb shell su -c 'ls /data/adb/tpdp 2>&1; ls /data/adb/modules | grep tab_dp; pgrep -f tab_dp_watchdog'
```

（三条都应无输出。DP 视频输出的恢复只在 `usb/online=1` 即确有外部供电时执行——
无供电时强拉 HPD 会重演本文前述的 panic 路径，此时保持关闭更安全，下次接线自动重新枚举。）

## 原理速览

```
故障签名:  触摸屏 USB (04f3:8512) 在线  &&  内核报 DP 未出流
           （v1.1.0 起另含: 本次开机 DP 曾=1 → 现=0 且 Type-C partner 在线/震荡）
判活依据:  /sys/kernel/debug/drm_dp/dp_debug 的 pclock > 0     ← v1.7.0
           不能用 card0-DP-1 的 status/enabled:黑屏时它仍报 connected + enabled
修复动作:  echo sink > /sys/class/typec/port0/port_type
           echo dual > /sys/class/typec/port0/port_type
           → CC 电气状态切换(虚拟拔插) → Type-C/PD/VDM/DP 全链路重新协商
```

完整的根因分析（PD 协商 / DP Alt Mode 一次性握手 / 三星 max77705 驱动缺陷 / 供电顺序实验数据）见 **[docs/troubleshooting.md](docs/troubleshooting.md)**。

## 配置与本地界面

模块读取 `/data/adb/tpdp/config`（可选），支持自定义触摸屏 VID/PID、轮询间隔、防抖与重试参数。

**v1.2.0 起无需手改配置文件**：点击 Magisk 模块的「执行」按钮，平板自动弹出本地配置界面（仅监听 127.0.0.1，开启 5 分钟后自动关闭）。v1.10.0 时界面共四块：

- **模块总开关** — 见下节，一键让模块完全停手/恢复；
- **屏幕唤醒控制** — 仅触摸/电源键可亮屏（含子开关）、强制息屏超时（v1.4.0）；
- **外接屏刷新率** — `60` / `120` / `自动` 三档，通过限制 DP 像素时钟过滤高带宽模式（v1.3.3）；
- **USB 设备选择** — 自动搜索屏幕相关设备（触摸/显示/坞站/集线器，按名称与 USB 类别打分推荐）、手动列出全部外接设备、保存后守护进程约 3 秒内热加载，无需重启。

**v1.10.0 起界面顶部有「启用模块」总开关（默认启用）**：关掉即让模块完全停手——
三个守护退出、故障恢复停止、sink 闸门与视频切断自动释放、像素时钟上限恢复原值，
端口与 HPD 交回系统默认行为；所有其它设置保留，重新开启 3 秒内恢复，无需重启。
配置键为 `ENABLED`（`1`/`0`，默认 `1`）：

```bash
# 等效于界面开关（守护 3 秒内响应）
adb shell su -c 'sed -i "/^ENABLED=/d" /data/adb/tpdp/config; echo ENABLED=0 >> /data/adb/tpdp/config'
```

详见 [tab-dp-watchdog/README.md](tab-dp-watchdog/README.md)。

## 兼容性

- **设备**: Galaxy Tab S7 / S7+（SM-T870 / SM-T970，SM8250 平台，Type-C 控制器 MAX77705）
- **系统**: One UI 5 / Android 13 实测；同平台其他 One UI 版本理论可用（接口为标准内核 sysfs）
- **Root**: Magisk 25+；KernelSU / APatch 理论兼容（customize.sh 已适配识别）
- **已知边界**: 屏幕完全断电时模块不动作（无从判断目标存在）；屏幕自身电源路径锁死时需"从电源端拔插供电线"恢复（详见 troubleshooting 文档）；拔 PD 后的 5V 切断需要**对端声明支持 PD 或本次开机 DP 亮过**——普通 USB-OTG（U 盘）会话不会被动断电；`port_type` 写入在 partner 挂着时会被内核拒绝（`invalid typec_role`），此时只能靠 `otgcut` 压 `otg/online`

## 日志与排错

```bash
# 看模块日志
adb shell su -c 'tail -20 /data/adb/tpdp/log'
# 一屏看完关键状态(usb/otg/role/电流/DP/pclk)
adb shell su -c 'echo usb=$(cat /sys/class/power_supply/usb/online) otg=$(cat /sys/class/power_supply/otg/online) role=$(cat /sys/class/typec/port0/power_role) ma=$(cat /sys/class/power_supply/battery/current_now); echo dp=$(cat /sys/class/drm/card0-DP-1/status); grep -m1 pclock= /sys/kernel/debug/drm_dp/dp_debug'
# 判活只看 pclock > 0;status=enabled 在黑屏时同样成立,不能当依据
# 打开 USB 设备选择界面 / 手动恢复
#   Magisk app → 模块 → 本模块 → "执行" 按钮
```

## 版本历史

见 [CHANGELOG.md](CHANGELOG.md) 与 [Releases](../../releases)。

## 许可

[MIT](LICENSE) — 按原样提供，root 操作请自担风险。

## 免责声明

模块仅写入内核标准 sysfs 接口、仅在 DP 已断链时动作，但任何涉及 root 与电源角色切换的操作都有理论风险。开机异常可在 Recovery 中禁用/移除该模块。
