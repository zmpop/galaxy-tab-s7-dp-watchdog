# Tab S7 DP Link Watchdog (Magisk 模块)

## 解决什么问题

Galaxy Tab S7 + 一线通(DP Alt Mode)外接触摸屏的三类"黑屏"问题:

| 场景 | 原本需要 | 装模块后 |
|---|---|---|
| 重启平板后黑屏 | 重新拔插一线通 | 开机后约 30s 内自动恢复 |
| 先插一线通、后给屏幕供电 | 重新拔插一线通 | 供电上电后约 10s 内自动恢复 |
| 运行中 DP 链路偶发掉线 | 重新拔插一线通 | 3~10s 内自动恢复 |
| **从屏幕端拔插 PD 供电线后卡死**(v1.1.0) | 从电源端重新拔插供电线 | 检测端口震荡卡死,自动虚拟拔插自救 |

**检测逻辑**:
- 故障 A = 触摸屏 USB(04f3:8512)在线 && extcon DP=0
- 故障 B(v1.1.0) = 本次开机 DP 曾经=1 && 现在=0 && Type-C partner 在线/闪烁
  (端口震荡卡死签名:对应屏幕端拔插供电线触发的"invalid typec_role"驱动卡死)
- 平板单独使用(从未连屏)永不误触发。

**原理**(本次实测验证):
- 故障特征 = 触摸屏 USB 设备(04f3:8512, ELAN)在线,但内核 extcon 报 `DP=0`。
  屏幕断电或拔线时触摸 USB 消失,不会误触发;插 PD 充电器也不会误触发。
- 修复动作 = 写 `/sys/class/typec/port0/port_type`:先 `sink` 再 `dual`,
  制造一次 CC 电气状态切换(等效拔插),强制 Type-C/PD/VDM/DP 全链路重新协商。
  实测在"重启后黑屏"场景下 100% 恢复 2560x1600@120Hz + 触摸。

## 安装

Magisk app → 模块 → 从本地安装 → 选择 tab-dp-watchdog-v1.0.0.zip → 重启。

## 配置(可选)

复制并编辑 `/data/adb/tpdp/config`:

```sh
TP_VID=04f3            # 触摸屏 idVendor
TP_PID=8512            # 触摸屏 idProduct
POLL_SEC=3             # 轮询间隔(秒)
STRIKES=2              # 连续多少次检测到故障才动作(防抖)
MAX_RETRY=5            # 每次故障最多尝试恢复次数
BOOT_DELAY=20          # 开机后延迟(秒),等待系统稳定
```

## 日志与排错

- 日志: `/data/adb/tpdp/log`(自动截断至 512KB)
- 手动触发: Magisk 模块页的"执行"按钮(action.sh)
- 查看链路状态: `adb shell su -c 'cat /sys/class/extcon/extcon0/state'`(DP=1 即正常)

## 已知边界

- 屏幕完全不上电时模块不会动作(触摸 USB 不在线,无从判断目标存在);
  先给屏幕供电,模块会在触摸 USB 枚举后自动接管。
- `port_type` 写入仅在 root(u:r:magisk:s0)上下文可用,普通 shell 无效。
- 模块动作只会在 DP 已断链时发生,正常使用中不会打扰工作中的画面。

## 卸载

Magisk 卸载模块后,如需清理: `rm -rf /data/adb/tpdp`
