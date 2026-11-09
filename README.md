# galaxy-tab-s7-dp-watchdog

**Magisk module — Samsung Galaxy Tab S7 USB-C DP Alt Mode 外接屏断链自动恢复看门狗**

[![Release](https://img.shields.io/badge/release-v1.1.0-blue)](../../releases)
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

平板单独使用（本次开机从未连接过屏幕）永不误触发；连接普通 PD 充电器、U 盘等 USB 配件不误触发。

## 安装

1. Magisk app → 模块 → 从本地安装 → 选择 [Releases](../../releases) 中的 `tab-dp-watchdog-vX.Y.Z.zip`
2. 重启
3. 完成。日志位于 `/data/adb/tpdp/log`

## 原理速览

```
故障签名:  触摸屏 USB (04f3:8512) 在线  &&  /sys/class/extcon/extcon0/state 报 DP=0
           （或 v1.1.0: 开机后 DP 曾=1 → 现=0 且 Type-C partner 在线/震荡）
修复动作:  echo sink > /sys/class/typec/port0/port_type
           echo dual > /sys/class/typec/port0/port_type
           → CC 电气状态切换(虚拟拔插) → Type-C/PD/VDM/DP 全链路重新协商
```

完整的根因分析（PD 协商 / DP Alt Mode 一次性握手 / 三星 max77705 驱动缺陷 / 供电顺序实验数据）见 **[docs/troubleshooting.md](docs/troubleshooting.md)**。

## 配置

模块读取 `/data/adb/tpdp/config`（可选），支持自定义触摸屏 VID/PID、轮询间隔、防抖与重试参数。换屏幕后改 VID/PID 即可复用。详见 [tab-dp-watchdog/README.md](tab-dp-watchdog/README.md)。

## 兼容性

- **设备**: Galaxy Tab S7 / S7+（SM-T870 / SM-T970，SM8250 平台，Type-C 控制器 MAX77705）
- **系统**: One UI 5 / Android 13 实测；同平台其他 One UI 版本理论可用（接口为标准内核 sysfs）
- **Root**: Magisk 25+；KernelSU / APatch 理论兼容（customize.sh 已适配识别）
- **已知边界**: 屏幕完全断电时模块不动作（无从判断目标存在）；屏幕自身电源路径锁死时需"从电源端拔插供电线"恢复（详见 troubleshooting 文档）

## 日志与排错

```bash
# 看模块日志
adb shell su -c 'tail -20 /data/adb/tpdp/log'
# 看链路状态(DP=1 即健康)
adb shell su -c 'cat /sys/class/extcon/extcon0/state'
# 手动触发一次恢复
#   Magisk app → 模块 → 本模块 → "执行" 按钮
```

## 版本历史

见 [CHANGELOG.md](CHANGELOG.md) 与 [Releases](../../releases)。

## 许可

[MIT](LICENSE) — 按原样提供，root 操作请自担风险。

## 免责声明

模块仅写入内核标准 sysfs 接口、仅在 DP 已断链时动作，但任何涉及 root 与电源角色切换的操作都有理论风险。开机异常可在 Recovery 中禁用/移除该模块。
