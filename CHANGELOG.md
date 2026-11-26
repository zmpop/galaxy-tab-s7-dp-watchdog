# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)（MAJOR.MINOR.PATCH）。
每个版本的完整发布说明见 [GitHub Releases](../../releases)。

## v1.8.0

### 修复（v1.7.0 的遗漏：屏幕不断电）

**现象**：拔掉外屏 PD 供电后，外接触摸屏**仍然有电**（不算黑屏待机，是被平板反过来供电）。
在并入模块之前的手工补丁版本上，同样的操作会让屏幕彻底断电。

**原因**（在 SM-T970 上实测得到）：

| 事实 | 证据 |
|---|---|
| 拔掉 PD 后 DRP 翻到 Attached.SRC，平板用电池给屏供电 | `vbus gone` 边沿日志：`otg=1 role=[source] ma=-1625` |
| `hpd` 两个方向都是空操作 | 写入 `rc=0`，`status/enabled/pclk` 与内核日志零变化 |
| `otg/online=0` 被内核自己重新打开 | 写入后 1s 内回到 1 |
| **`port_type` 是唯一真能掐断 5V 的杠杆** | `echo sink > port_type` → `usb/online 1→0`、`dp=disconnected`、`pclk=0`；`echo dual` → 全部恢复 |

v1.7.0 沿用了 v1.5.1 的结论「`port_type` 写不进去（`invalid typec_role`）」，
所以只剩「不碰链路」这一半修复，**没有切断平板自己的 5V 输出**——
屏幕继续靠平板电池活着，自然不会断电。而当年的 v1.5.1 `powergate.sh`
用 `port_type=sink` 做的正是这件事，去掉它之后这个效果就消失了。

### 新增：sink 闸门（SINK_GATE，默认开启）

外接 VBUS 连续 2 次采样缺失后，把 `port_type` 钉为 `sink`（移除端口的
Source 能力 → 不可能输出 5V）→ 屏幕失去供电自然断电、DP 随之断开。
每 6 秒复核一次（内核会自己把 Source 能力装回去），外接供电回来立即释放。

| 文件 | 改动 |
|---|---|
| `screenvid.sh` | 新增 `pin_sink/gate_engage/gate_release/gate_in_grace`；主循环 VBUS 缺失时engage + 定期复核，返回时释放；启动时清除上一次运行残留的闸门 |
| `service.sh` | `virtual_replug()` 在闸门期间拒绝执行（它会写 `dual`，把 Source 能力还回去）；主循环加了「VBUS 已恢复但闸门还在」的安全网（连 2 次即释放，sink-only 端口无法充电） |
| `action.sh` / `web/cgi-bin/recover` | 手动恢复前先释放闸门 |
| `uninstall.sh` | **无条件**写 `port_type=dual`。原先是「回读到 `[sink]` 才还原」，但闸门生效时回读仍显示 `[dual] source sink`，条件永远不成立 → 卸载后会留下无法充电的端口 |
| `tests/sink_gate_test.sh` | 23 条断言：engage 幂等、release 写 dual、10s 宽限期、`SINK_GATE=0` 关闭、以及 8 条与出货脚本的漂移检查 |

安全网：闸门标记 `/data/adb/tpdp/sink_gate` 绝不跨重启继承；`service.sh`
与 `screenvid.sh` 任一方发现「供电已回来但闸门还在」都会立刻释放；
`SINK_GATE=0` 可完全关闭。

## v1.7.0

### 修复（回归，v1.6.0 引入）

- **装成模块后拔插 PD：画面不恢复；且拔掉 PD 后屏幕不再断电。**

  v1.6.0 的守卫做了两件多余的事，把内核自己的断链/重连流程打坏了：

  1. **PD 一回来就立刻调 `restore_video()`**，而该函数第一件事就是
     `echo 1 > /sys/kernel/debug/drm_dp/hpd`。这一写正好落在 USB PD
     VDM 重新协商的窗口里（实测 19:18:15 供电回来，19:18:17 就写了），
     把 sink 的链路状态打成半协商态：
     `status=connected enabled=enabled` 但 `dp_debug pclock=0`
     ——软件看"正常"，屏幕是黑的。
  2. **守卫每 3 秒 `echo 0 > hpd`**。实测该节点在本内核是**空操作**：
     写入 `rc=0`、状态零变化、内核零日志（`hpd=1` 才会触发
     `dp_usbpd_simulate_connect`，且只重配已连接的链路，不 enable 编码器）。
     纯属多余，却持续扰动驱动的模拟 HPD 状态。

  而当初在设备上验证通过 4 连拔插的那份补丁（tabpdmon 18:10）**只做了一件事**：
  在 `restore_video()` 开头加一道 `usb/online != 1` 的抑制闸门，**一个 hpd 都不写**。
  断链、重连、恢复全部交给内核，所以断电时屏幕会真的掉电、插回后画面自动回来。

  v1.7.0 回到那条路线上，并把"恢复成功"的判据换成真相：

  | 判据 | v1.6.0 | v1.7.0 |
  |---|---|---|
  | 画面是否真的在输出 | `status=connected && enabled`（会骗人） | `dp_debug pclock > 0` |
  | PD 缺失时对链路 | 每 3 秒写 `hpd=0` | 什么都不写 |
  | PD 回来时 | 立刻 `restore_video()`（→ `hpd=1`） | 先等 `PD_SETTLE=4s` 让 PD 合约落地，再判定；只在真的没画面时才修 |

### 恢复阶梯（仅在确认没画面时使用）

1. `port_type` 虚拟拔插 `sink -> dual` —— 本内核唯一能强制重新枚举的杠杆
2. `hpd=1`（simulate connect，只重配已连接链路）
3. 熄屏→亮屏一次 —— 走显示栈的完整 disable/enable，实测把
   `state 0x0 pclock 0` 干净地拉回 `state 0xa5 pclock 268500`

### 配套

- `service.sh`：恢复引擎在 PD 回来后同样等待 `PD_SETTLE` 再计数打击，
  不再把虚拟拔插打进 PD 协商窗口；陈旧 `video_off` 清理不再 pokes hpd。
- `screenvid.sh`：`cut_video()` 不再写 `hpd=0`（空操作），改为确认显示栈
  已经切断（实测熄屏即 `disconnected/disabled/state 0x0`），不再空转计失败。
- 测试：`tests/vbus_guard_test.sh` 重写为 35 条断言（含"已在上流时**零写入**"
  "PD 缺失时**零写入**""恢复阶梯顺序"以及源码静态不变量），
  与 `tests/uninstall_test.sh` 合计 50 条全过。

## v1.6.0

### 修复（重要）

- **拔掉外接屏 PD 供电导致平板异常重启（内核 panic）**。
  现象：一线通接外接触摸屏工作正常，一旦拔掉屏幕端的 PD 供电，平板在数秒到
  十几秒内直接 panic 重启（三星安全看门狗复位，`ro.boot.bootreason=kernel_panic`）。
  本次定案证据：RAMDUMP `eRR.p` 中同一签名的 `RWC 80/83/86/89` 4 次；崩溃前
  kmsg 完整链条为

  ```
  MUIC 判 OTG -> port0 power_role=source, otg/online=1, 放电 ~1.9A, Vbat 3.90->3.73V
  [sh: 1837] dp_display_usbpd_configure_cb: +++        <- 模块的 echo 1 > drm_dp/hpd
  dp_display_enable: add DP_STATE_ENABLED  2560x1600@60 (pclk 268.5/300MHz)
  dp_display_disconnect_sync: DP_STATE_ABORTED state(0x15f)
  sde_kms_wait_for_commit_done -110  x2
  TZBSP_ERR_FATAL_NOC_ERROR / asynchroomus_serror_ilterrupt -> panic
  ```

  根因：屏幕 PD 供电消失后平板翻成 Source，用自身电池给屏供电；此时模块任一
  "`echo 1 > hpd`" 路径（息屏亮屏恢复 / 开机补救 / 刷新率重枚举 / 虚拟拔插 /
  手动恢复）都会让 DP 在**没有外部供电的端口上重新上流**。随后 PD 插回触发 VDM
  重协商，而 HPD 拉低时视频流仍为 ENABLED，commit 路径死锁，NoC/TrustZone 致命。
  4 次复测证明：断电把链路拆干净不会出问题，致死的是"拆完又被软件拉活 -> 二次拆链"。

- 新增**外部供电守卫**（`VBUS_GUARD`，默认 `1` 开启），覆盖全部会把 HPD 拉高的路径：
  - `screenvid.sh`
    - 主动侧：`usb/online != 1` 的边沿立刻 `echo 0 > hpd` + 置 `video_off` 标记，
      并在无供电期间每 3 秒复核一次链路，一旦被内核/框架重新拉活立即再次按下去；
    - 被动侧：`restore_video()` 在拉高 HPD 前校验外部供电，缺失则整段跳过并保持
      标记（同时抑制 `service.sh` 的虚拟拔插恢复引擎），PD 接回后 3 秒内自动恢复画面；
  - `service.sh`：开机补救（`boot_video_failsafe`）、刷新率重枚举（`hz_reevaluate`）、
    陈旧标记清理、故障恢复引擎（`virtual_replug`）四处全部加守卫，无外部供电时
    恢复引擎"解除武装"并每分钟只记一条日志，不再空转 100 秒重试阶梯；
  - `action.sh`（Magisk「执行」按钮）：无供电时拒绝强制恢复并说明原因；
  - `web/cgi-bin/hz`：无供电时只写像素时钟上限，跳过链路重枚举；
  - `web/cgi-bin/recover`：无供电时拒绝虚拟拔插。

- 判定依据（实测取值，见 `docs/`）：外部供电在位 `usb/online=1`、`power_role=sink`、
  `otg/online=0`、电池充电；拔掉屏 PD 后 `usb/online=0`、`power_role=source`、
  `otg/online=1`、放电约 1.9A。`usb/online` 节点不存在（安装/卸载环境）时不拦截。

### 已知取舍

- 屏幕 PD 断电期间外接屏不显示（这是预期行为：宁可黑屏，不要重启）。接回 PD 后
  画面自动恢复，无需重新插拔一线通。
- 若确实需要"平板给屏供电"（不接屏侧 PD），必须显式设置 `VBUS_GUARD=0`，
  此时 v1.6.0 的保护失效，崩溃风险自负。

### 卸载与升级彻底化

- **卸载脚本修掉三个洞**（审计"在面具里点移除能不能卸干净"时发现）：
  1. `echo 1 > drm_dp/hpd` 原先无条件执行 —— 若卸载时外屏 PD 不在位，这一步会
     重演本文上半部分的 panic 路径。现改为仅在 `usb/online=1` 时恢复，否则保持
     链路关闭（下次接线自然重新枚举，无害）；
  2. `kill $(cat web.pid)` 可能杀掉无关进程 —— 重启后该 PID 常被系统复用。
     现改为先校验 `/proc/<pid>/cmdline` 含 `httpd` 才 kill；
  3. `echo dual > port_type` 原先无条件写入 —— 现仅在端口确实被钉成 `[sink]`
     （旧供电角色守护留下的状态）时才改回 `dual`，不打扰健康端口。
- 卸载时 Magisk 删除模块目录（含旧 `powergate.sh`、`screenvid.sh.bak-*`），
  本脚本删除 `/data/adb/tpdp` 并复核残留，结果打印到 Magisk 安装日志。
  模块不写 `service.d` / `post-fs-data.d`，不改任何系统属性，因此移除后
  `/data/adb` 下不留任何本模块文件。
- **升级即清理**：`customize.sh` 会删除 `hb.power` 并移除已废弃的
  `POWER_ROLE_MODE` 配置项，避免从 v1.5.1 升级后留下孤儿状态。

### 与 v1.5.1 的关系

v1.5.1（仅存在于设备上，未发布）走的是另一条路线：新增 `powergate.sh`，想通过
`preferred_role` / `port_type=sink` 从源头禁止平板对外供 5V。实测本机内核在 partner
仍然注册时**拒绝一切**相关写入（`max77705_port_type_set: invalid typec_role`），
且 `otg/online` 会被内核自行重开，该方案已证伪并整体移除。

v1.6.0 不再试图阻止角色翻转（做不到），而是阻断唯一致死的动作——
在没有外部供电时让 DP 重新上流。这是 4 次复测验证有效的方案。

## v1.4.0

### 新增功能

- **亮屏来源控制（唤醒闸门，默认开启）**：只有触摸屏点击或电源键能点亮屏幕。
  充电状态跳变、网络/定时唤醒、系统 HDMI 唤醒锁等非用户事件引发的亮屏，
  会在 1 秒内被自动按灭（`KEYCODE_SLEEP`）。
  - Web 界面新增**主开关**「仅触摸 / 电源键亮屏」与**子开关**「允许点击触摸屏唤醒」；
  - 联动：主开关关闭时子开关置灰不生效；子开关关闭时只有电源键能点亮；
  - 保存：子开关取值始终写入配置（主开关关闭时也保存），重新打开主开关即恢复上次选择；
    三个开关一次性 POST 到 `cgi-bin/wake`，配置原子替换，守护进程 1 秒内热加载。
- **息屏超时强制执行（默认开启）**：接外接屏时三星
  `DisplayDeviceRepository.mHDMIWakeLock`（`SCREEN_DIM_WAKE_LOCK`）长期持有，
  会屏蔽系统「30 秒自动息屏」，导致到点不黑屏（实测连续亮 5 小时）。
  模块改为按 `mLastUserActivityTime` 计算真实空闲时长，超过系统设定值（+2 秒容差）
  后兜底强制休眠；检测到前台应用持有 `SCREEN_BRIGHT_WAKE_LOCK`（如全屏播放）
  时不干预。
- 新增独立守护进程 `wakegate.sh`，由 `service.sh` 启停与监督；配置项
  `WAKE_GATE` / `WAKE_GATE_TOUCH` / `TIMEOUT_ENFORCE`。

### 设计要点

- 唤醒判定依据：电源键走 `logcat` 的 `interceptKeyTq keycode=26`；触摸/输入走
  `mLastUserActivityTime` 与 `mLastWakeTime` 的差值（±1.5 秒内判定为输入触发），
  辅以 `dumpsys input` 的 `MotionEvent age`。实测
  `/sys/class/sec/sec_key/key_pressed_count` 的 `KPWR` 恒为 0、
  `getevent` 读不到事件（被 `sec_key_notifier` 提前消费），均不可用。
- 失效保护：5 分钟内抑制超过 8 次即判定依据不可靠，闸门暂停 10 分钟；每次判定
  都会把证据快照写入日志（`/data/adb/tpdp/log`，`[wake]` 前缀）。

### 修复

- `cgi-bin/status`：整份 `dumpsys power` 输出无法作为 shell 参数传递（ARG_MAX），
  改为管道预过滤，屏幕状态与息屏超时数值恢复正确上报。

## v1.3.3

### 新增功能

- **外接屏刷新率选择（60Hz / 120Hz / 自动）**：
  - v1.3.2 的"锁定 60Hz"开关升级为三档选择，配置项 `HZ_MODE`
    （默认 `60`）：`60` → 像素时钟上限 300MHz（推荐，链路带宽减半）；
    `120` → 上限 560MHz（放行 537MHz 的 120Hz 模式）；`auto` → 恢复
    内核默认上限（不限速）。
  - Web 配置界面的开关卡片改为三选一按钮组，实时显示当前 DP 模式，
    点击即时生效（外接屏短暂黑屏约 3 秒属正常）。
  - 开机应用所选档位；若链路已按超出档位的模式枚举（如冷启动先于
    服务），自动触发一次 HPD 重枚举；配置热加载自动对账。
  - 兼容 v1.3.2 旧配置：`LOCK60=1` → 60Hz，`LOCK60=0` → 自动；
    Web 保存新档位时自动清理旧键。
  - 各档位上限可调：`PCLK_CAP_KHZ`（60 档，默认 300000）、
    `PCLK_120_KHZ`（120 档，默认 560000）。
  - 模块描述同步更新，与实际功能保持一致。

## v1.3.2

### 新增功能

- **外接屏"锁定 60Hz"**：
  - 背景：外接屏以 2560×1600@120Hz（HBR2 满带宽）运行时信号裕量临界
    （链路训练电压摆幅达 2 级，屏幕持续上报链路状态错误），导致
    "黑屏一下又恢复"（链路重训）与"息屏自亮"（链路错误中断唤醒系统 →
    框架获取 mHDMIWakeLock 强制亮屏）。
  - 实现：通过内核 DP 驱动调试节点 `/sys/kernel/debug/drm_dp/max_pclk_khz`
    限制像素时钟上限（默认 300MHz），537MHz 的 120Hz 模式超出上限被过滤，
    系统自动落到 268MHz 的 60Hz 模式——链路带宽需求减半，`test_req`
    链路错误标志实测清除。
  - 配置项 `LOCK60`（默认开启，Web 界面可开关），开机自动应用；若开机时
    链路已按 120Hz 枚举，自动触发一次 HPD 重枚举降回 60Hz。
  - Web 配置界面新增「外接屏刷新率」开关卡片：实时显示当前模式
    （如 `2560x1600@60Hz`），切换即时生效（外接屏短暂黑屏约 3 秒）。
  - 卸载时自动恢复内核像素时钟上限，120Hz 等高带宽模式重新可选。

## v1.3.1

### 问题修复

- **修复息屏期间视频被反复错误恢复（夜间 flood）**：
  - 现象：息屏挂起（Doze 周期性休眠）后，`service.sh` 误判 `screenvid`
    心跳超时为"看门狗已死"，每隔几分钟就清除切断标记并恢复 DP 视频输出，
    `screenvid` 又立即切断，循环往复（实测一夜可触发 200+ 次，外接屏
    夜间反复闪亮）。
  - 根因：`sleep` 基于 monotonic 时钟，系统挂起期间守护进程被冻结，而心跳
    文件的时间戳按墙上时钟流逝——休眠唤醒后心跳"年龄"必然超阈值，纯属假象。
  - 修复：判定标记过期前先查询实际屏幕状态（`dumpsys power` 的
    `mWakefulness`）：`Asleep`/`Dozing` 说明系统在休眠（冻结而非死亡），
    自愈心跳并保持视频切断；仅在屏幕确实处于唤醒态时才按"看门狗死亡"
    处理（清标记 + 恢复视频）。

## v1.3.0

### 新增功能

- **息屏切断视频输出（screenvid）**：按电源键/屏幕超时息屏后立即停止对外接屏的
  DP 视频信号输出，亮屏后自动恢复。实测切断约 1.1s、恢复约 1.1s。
  - 机制：写 msm DP HPD 仿真节点 `/sys/kernel/debug/drm_dp/hpd`（0=断开、1=恢复），
    息屏期间不动 USB 触摸与 PD 供电。
  - 检测：`screen_toggled` 事件驱动为主（即时），`dumpsys power` 轮询兜底
    （息屏 3s / 亮屏 15s）；事件与轮询冲突以轮询为准，同一事件行只消费一次。
- **多层异常恢复**（目标：永不留下永久黑屏）：
  - 切换失败重试 3 次，连续 5 次失败自动停用功能并保持视频开启；
  - `service.sh` ↔ `screenvid` 双向心跳互检与自动拉起重启；
  - 启动即按实际屏幕状态对齐（崩溃重启自愈）；恢复失败时先保留标记再由主守护
    `port_type` 重放兜底（双引擎），仍失败每 10s 重试；
  - 开机 `boot_video_failsafe` 清标记 + 强制 HPD 高，HPD 失败自动降级 port_type 重放；
  - `uninstall.sh` / `customize.sh` 均先恢复 HPD=1，避免卸载/安装后黑屏；
  - Magisk「执行」按钮在检测到切断标记时一键强制恢复视频。
- Web 状态面板新增：屏幕状态、视频输出状态、息屏切断开关、screenvid 守护进程状态。

### 优化改进

- 事件流进程死亡时按退避重启（不空转），事件文件损坏/不可写时自动重建并降级为轮询。
- 修正“旧事件行被重复消费”导致的刚切断即被恢复的问题（事件行去重）。

### 不兼容变更

- 无。`VIDEO_SWITCH=0` 可完全关闭新功能，行为回到 v1.2.1。

## v1.2.1

### 新增功能

- **完整卸载支持**：新增 `uninstall.sh`，点击 Magisk「卸载」并重启后自动执行：
  - 终止看门狗守护进程、Web 配置服务（httpd）与超时脚本；
  - 删除 `/data/adb/tpdp/`（配置、日志、pid/状态文件）；
  - 模块本体与 staged 更新由 Magisk 负责删除，卸载后无任何残留。
- README 补充卸载自检命令与回滚方案（还原按钮 / 重装 zip / 安全模式）。

### 修复的问题

- **修复「卸载」按钮灰色不可点击**：此前经命令行升级（`magisk --install-module`）
  后未重启，模块停留在"待更新"状态（`update` 标志 + `modules_update` 残留），
  Magisk 在该状态下按设计禁用卸载按钮。重启完成更新后按钮即恢复可用。
  （此为安装方式导致的状态问题，v1.2.1 的正式安装+重启流程不会再出现。）

### 不兼容变更

- 无。

## v1.2.0

### 新增功能

- **USB 设备选择 Web 界面**：点击 Magisk 模块的「执行」按钮，自动在平板浏览器
  打开本地配置界面（`http://127.0.0.1:8899/`，仅监听本机）。
  - **自动搜索**：一键列出"屏幕相关"USB 设备，按设备名称与 USB 类别打分推荐
    （触摸 90 / 显示 85 / 坞站·集线器 55 / HID 40 / 视频类 30，当前配置设备置顶）；
  - **手动列出**：一键列出全部外接 USB 设备（VID/PID、名称、厂商、序列号、
    总线位置、接口类别、速率），由用户自行挑选；
  - **保存**：校验所选设备在线后写入 `/data/adb/tpdp/config`；
  - **手动恢复**：界面内"尝试恢复显示链路"按钮（链路正常时拒绝执行，不闪屏）。
- **配置热加载**：守护进程检测到配置文件变化（含从 Web 界面保存）后，
  在一个轮询周期（约 3 秒）内自动重新加载 VID/PID 等参数，无需重启。
- **界面超时自动关闭**：Web 服务开启 5 分钟后无论用户是否操作都会自动关闭
  （服务端权威计时 + 页面倒计时双保险），重复点击「执行」不会延长计时；
  服务仅绑定 127.0.0.1，不对外暴露。

### 技术实现

- 后端：Magisk 自带 busybox 的 `httpd`（CGI 模式），4 个 CGI 接口
  （`devices` / `status` / `save` / `recover`）+ `autoshut.sh` 超时脚本；
- 前端：单文件 `web/index.html`（原生 HTML/JS，无依赖）；
- 全部已在 SM-T970 实测：接口、热加载、15/90 秒超时自动关闭均验证通过。

### 不兼容变更

- 「执行」按钮行为变更：由"立即尝试恢复"改为"打开设备选择界面"
  （手动恢复功能移入界面内的按钮）。自动看门狗行为不变。

## v1.1.1

### 优化改进

- **模块元数据中文化**：Magisk app 中显示的模块名称现在附带中文名
  "Tab S7 DP 显示链路看门狗"，描述改为中文，便于中文用户理解模块功能
  （无需重新安装配置，升级后 Magisk app 刷新即可看到新名称与描述）。

### 不兼容变更

- 无。升级可直接覆盖安装；守护进程逻辑与 v1.1.0 完全一致。

## v1.1.0

### 新增

- **故障 B 检测（端口卡死自救）**：本次开机 DP 曾=1、现=0、且 Type-C partner
  在线/震荡时自动执行虚拟拔插。覆盖"从屏幕端拔插 PD 供电线"触发的
  `max77705_port_type_set: invalid typec_role` 端口卡死场景
  （实测时间线见 docs/troubleshooting.md）。
- 完整根因分析文档 `docs/troubleshooting.md` 与原始实验数据
  `docs/monitor-log-2026-11-09.txt`。

### 修复

- service.sh 启动日志变量名笔误（`${POLL}` → `${POLL_SEC}`，仅影响日志显示）。

### 不兼容变更

- 无。升级可直接覆盖安装。

## v1.0.1

### 修复

- `action.sh`（Magisk"执行"按钮）在 DP 链路健康时不再执行虚拟拔插。
  此前无条件拔插会导致正在使用的画面出现数秒闪断；
  现在先检查 extcon 状态，链路正常则直接退出并提示 "Nothing to do"。

## v1.0.0

首次发布。

- **新增**: DP Alt Mode 链路看门狗守护进程（service.sh）
  - 故障检测:外接触摸屏 USB（ELAN 04f3:8512）在线而内核 extcon 报 `DP=0`
  - 自动恢复:切换 Type-C `port_type`（sink → dual）执行"虚拟拔插"，
    强制 CC/PD/VDM/DP 全链路重新协商
  - 防抖（连续 2 次采样命中才动作）、退避重试（最多 5 次）、单次故障单轮处理
  - 覆盖:重启后黑屏 / 先插线后供电 / 运行中链路偶发掉线
- **新增**: Magisk app "执行"按钮手动恢复（action.sh）
- **新增**: 可选配置文件 `/data/adb/tpdp/config`（VID/PID、轮询、重试参数）
- **新增**: 日志 `/data/adb/tpdp/log`（自动截断 512KB）
- 实测:SM-T970 / One UI 5，重启后黑屏 25s 检出、6s 恢复
