# Tab S7 DP 显示链路看门狗 (Tab S7 DP Link Watchdog)

## 解决什么问题

Galaxy Tab S7 + 一线通(DP Alt Mode)外接触摸屏的各类"黑屏/不断电"问题:

| 场景 | 原本需要 | 装模块后 |
|---|---|---|
| 重启平板后黑屏 | 重新拔插一线通 | 开机后约 30s 内自动恢复 |
| 先插一线通、后给屏幕供电 | 重新拔插一线通 | 供电上电后约 10s 内自动恢复 |
| 运行中 DP 链路偶发掉线 | 重新拔插一线通 | 3~10s 内自动恢复 |
| **从屏幕端拔插 PD 供电线后卡死**(v1.1.0) | 从电源端重新拔插供电线 | 检测端口震荡卡死,自动虚拟拔插自救 |
| **拔掉屏幕 PD 后平板 panic 重启**(v1.6.0) | 只能等它重启完 | 无外部供电时绝不重新上流,链路按住不动 |
| **拔掉 PD 后屏幕仍被平板反供 5V**(v1.9.1) | 无(用户态以为做不到) | `otgcut` 每 200ms 压 `otg/online`,真正断电 |

**检测逻辑**:
- 故障 A = 触摸屏 USB(04f3:8512)在线 && 内核报 DP 未出流(`dp_debug pclock=0`)
- 故障 B(v1.1.0) = 本次开机 DP 曾经=1 && 现在=0 && Type-C partner 在线/闪烁
  (端口震荡卡死签名:对应屏幕端拔插供电线触发的"invalid typec_role"驱动卡死)
- **判活不能用 `card0-DP-1/status`**(v1.7.0):黑屏时它依然报 `connected` + `enabled`,
  只有 `pclock > 0` 才代表真的在出流
- 平板单独使用(从未连屏)永不误触发。

**原理**(本次实测验证):
- 故障特征 = 触摸屏 USB 设备(04f3:8512, ELAN)在线,但内核 extcon 报 `DP=0`。
  屏幕断电或拔线时触摸 USB 消失,不会误触发;插 PD 充电器也不会误触发。
- 修复动作 = 写 `/sys/class/typec/port0/port_type`:先 `sink` 再 `dual`,
  制造一次 CC 电气状态切换(等效拔插),强制 Type-C/PD/VDM/DP 全链路重新协商。
  实测在"重启后黑屏"场景下 100% 恢复 2560x1600@120Hz + 触摸。

## 安装

Magisk app → 模块 → 从本地安装 → 选择 `tab-dp-watchdog-v1.10.0.zip` → 重启。
（KernelSU / APatch 同样可从本地安装；TWRP 可直接刷入。）

## 本地配置界面(v1.2.0 起, v1.10.0 扩为四块)

换了触摸屏/扩展坞,不再需要手动改配置文件——点击 Magisk 模块页的**「执行」**按钮,
平板会自动弹出浏览器打开本地配置界面(`http://127.0.0.1:8899/`):

- **模块总开关**(v1.10.0):顶部「启用模块」,默认开启,详见下文;
- **屏幕唤醒控制**(v1.4.0):主开关 + 触摸唤醒子开关 + 强制息屏超时;
- **外接屏刷新率**(v1.3.3):`60` / `120` / `自动`;
- **USB 设备选择**:自动搜索屏幕相关设备(按名称/USB 类别打分:触摸 > 显示 > 坞站/集线器 > HID)、
  手动列出全部外接设备、保存后守护进程数秒内热加载(无需重启)、以及"尝试恢复显示链路";
- 界面**开启 5 分钟后自动关闭**(无论是否操作),服务只绑定 127.0.0.1,不对外网暴露;
  再次开启只需重新点击「执行」。

界面打不开时(浏览器未自动拉起),在平板任意浏览器手动访问上面的地址即可。

## 息屏切断视频输出(v1.3.0)

按电源键(或屏幕超时、AOD)息屏后**立即停止对外接屏的视频信号输出**,亮屏后**自动恢复**,
省电、也让外接屏进入待机(不再一直亮着显示桌面)。

- 实测时延:切断约 **1.1 秒**,恢复约 **1.1 秒**(2560x1600@120Hz 原样回来)
- 息屏期间触摸 USB 与供电链路**不受影响**(只切视频,不切 USB/PD)
- 开关:配置 `VIDEO_SWITCH=0` 可整体关闭;单独一次手动恢复:点 Magisk「执行」按钮

**原理**:`/sys/kernel/debug/drm_dp/hpd` 是高通 msm DP 的 HPD 仿真节点
(本内核上 `/sys/class/drm/card0-DP-1/dpms` 为只读,不可用):
写 `0` → 连接器上报断开、链路拆除、无视频信号;写 `1` → 重新训练链路、画面回来。

**状态管理**:单写者 `screenvid.sh`(由 `service.sh` 启动与监督),状态落在
`/data/adb/tpdp/`:`video.state`(on/off)、`video_off`(切断标记,主守护据此抑制 DP 误恢复)、
`video.disabled`(本次开机停用标记)、`hb.video`/`hb.main`(双向心跳)。

**切换流程**:屏幕事件(`logcat -b events -s screen_toggled`)**驱动为主**,
`dumpsys power` 轮询兜底(息屏态每 3s、亮屏态每 15s);事件与轮询冲突时以轮询为准
(日志记 `trusting power`),同一事件行只消费一次(避免旧事件重复触发)。

**异常恢复设计**(目标:任何情况下都不留下永久黑屏):

| 异常 | 处理 |
|---|---|
| 切换(写 HPD)失败 | 3 次重试;连续 5 次失败 → 自动停用本功能并**保持视频开启**,写 `video.disabled` |
| 亮屏事件丢失/事件流中断 | 轮询兜底 3~15s 内自行恢复;事件流进程死亡会被监督重启,重启有退避(不空转) |
| screenvid 崩溃/被杀 | `service.sh` 每 3s 检查并拉起;新实例启动即按**实际屏幕状态**重新对齐 |
| service.sh 崩溃/被杀 | `screenvid` 通过 `hb.main` 心跳发现(>90s)并重启主守护 |
| HPD 节点不可用(debugfs 未挂载) | 自动尝试挂载;仍不可用则直接走 `port_type` 虚拟拔插兜底 |
| 恢复失败 | 保留标记 → 交给主守护的 `port_type` 重放(双引擎);仍失败则每 10s 重试 |
| 重启平板(含息屏态下重启) | 开机 `boot_video_failsafe` 先清标记并强制 HPD 高;`screenvid` 启动再按实际状态对齐 + HPD 失败自动降级到 port_type 重放(实测 12s 内恢复) |
| 模块被卸载/安装 | `uninstall.sh`、`customize.sh` 均先恢复 HPD=1 再清理 |
| 双守护同时死亡(极端) | 开机自愈;或点 Magisk「执行」按钮一键强制恢复视频 |

**已知副作用**:切断/恢复在系统层等效于"外接屏被拔出/接入",因此息屏期间窗口会回流到
平板屏,亮屏后外接屏会重新枚举一次(窗口布局可能重排)。这是 HPD 方案的固有特性。

## 外接屏刷新率档位(v1.3.3)

外接屏跑 2560×1600@120Hz 时链路负载接近临界(像素时钟约 537MHz),会出现**瞬时黑屏**
与**息屏后自己亮起来**。做法是限制 DP 像素时钟,让框架挑不到高带宽模式:

| 档位(`HZ_MODE`) | 上限(`/sys/kernel/debug/drm_dp/max_pclk_khz`) | 效果 |
|---|---|---|
| `60`(默认) | 300000 | 只能 60Hz(268.5MHz),链路最稳 |
| `120` | 560000 | 允许 120Hz(537MHz) |
| `auto` | 内核原值(本机 675000) | 不过滤,行为同原厂 |

- 切换档位后需要一次重枚举(`port_type` sink→dual)才会生效;这一步同样受外部供电
  守卫约束——没有外部供电时只写上限,不做重枚举(否则就是 panic 路径);
- 上限原值在首次写入前就记录下来,关闭模块或卸载时恢复,不留残留;
- 界面「外接屏刷新率」卡片与配置 `HZ_MODE` 等价,保存即热加载。

## 亮屏来源控制与息屏超时强制执行(v1.4.0)

接外接屏时,三星 `system_server` 会长期持有 `DisplayDeviceRepository.mHDMIWakeLock`
(等级 `SCREEN_DIM_WAKE_LOCK`,`ACQUIRE_CAUSES_WAKEUP`)。由此产生两个现象:

1. **自己亮屏**:充电状态跳变(`powered change (plugged_in)`)、网络/定时唤醒,
   以及该唤醒锁自身的 `ACQUIRE_CAUSES_WAKEUP`,都会把屏幕点亮;
2. **30 秒息屏不生效**:`SCREEN_DIM_WAKE_LOCK` 在系统语义上**禁止屏幕熄灭**
   (只允许变暗),所以 `mScreenOffTimeoutSetting=30000` 到点也不会黑屏,
   实测可连续亮 5 小时(02:11 持有 → 07:15 拔线才释放)。

两者都无法在应用层修改 PowerManager,因此由 `wakegate.sh` 在系统之上接管:

- **唤醒闸门**:屏幕点亮后 1 秒内判定是否为用户操作,不是则立刻发
  `KEYCODE_SLEEP`(等效按一下电源键,可突破唤醒锁)按灭;
- **超时强制执行**:用 `mLastUserActivityTime` 判断真实空闲时长,超过系统设定
  的自动息屏时间(默认 30s,+2s 容差)即强制休眠。

**判定依据**(本机实测):

| 信号 | 说明 |
|---|---|
| 电源键 | `logcat -b main` 中 `interceptKeyTq keycode=26`(5 秒内) |
| 触摸/输入 | `mLastUserActivityTime` 与 `mLastWakeTime` 差值在 ±1.5s 内;辅以 `dumpsys input` 的 `MotionEvent age` |
| 其他事件 | 唤醒时两者差值远离(如充电跳变时为负、熄屏前按键后为正)→ 判为非用户唤醒 |
| 排除项 | `/sys/class/sec/sec_key/key_pressed_count` 的 `KPWR` 恒为 0,不可用;`getevent` 读不到事件(`sec_key_notifier` 提前消费) |

**两个开关的联动关系**:

| 主开关(仅触摸/电源键亮屏) | 子开关(允许点击触摸屏唤醒) | 实际效果 |
|---|---|---|
| 开 | 开 | 触摸点击、电源键都能点亮 |
| 开 | 关 | **只有电源键**能点亮,触摸唤醒会被按灭 |
| 关 | 任意 | 不限制亮屏来源(子开关置灰,不生效) |

保存逻辑:子开关取值**始终写入配置**(主开关关闭时也保存),只是不生效;
重新打开主开关即恢复用户上次的选择。三个开关一次性 POST 到 `cgi-bin/wake`,
配置以"临时文件 + mv"原子替换,守护进程 1 秒内热加载,无需重启。

**失效保护**:5 分钟内抑制超过 8 次,说明判定依据不可靠,闸门自动暂停 10 分钟
(避免把用户锁在熄屏状态);每次判定都会在日志里留下证据快照。
开启"强制息屏超时"时,若检测到前台应用持有 `SCREEN_BRIGHT_WAKE_LOCK`
(如全屏播放视频)则**不**强制休眠。

## 外部供电守卫:拔掉屏幕 PD 电源不再重启(v1.6.0)

**现象**:一线通正常工作,拔掉**屏幕端 PD 供电线**后,平板在数秒~十几秒内直接 panic
重启(三星安全看门狗复位)。多次复现,`ro.boot.bootreason=kernel_panic,asynchroomus_serror_ilterrupt`,
RAMDUMP `eRR.p` 中同一签名 4 次(`RWC 80/83/86/89`)。

**根因链**(kmsg 与 `power_supply` 逐帧对齐):

```
1. 拔掉屏幕 PD  -> MUIC 判为 OTG -> port0 翻 Source
                 power_role=source, otg/online=1, 放电 ~1.9A, Vbat 3.90 -> 3.73V
2. 链路掉一次  -> 模块按"亮屏但视频没了"去恢复 -> echo 1 > drm_dp/hpd
                 [sh: 1837] dp_display_usbpd_configure_cb: +++
3. DP 在无外部供电的端口上重新上流 2560x1600@60 (pclk 268.5/300MHz)
4. PD 插回 -> VDM 重协商 -> HPD 拉低时流仍 ENABLED
5. dp_display_disconnect_sync: DP_STATE_ABORTED state(0x15f)
   sde_kms_wait_for_commit_done -110  x2
6. TZBSP_ERR_FATAL_NOC_ERROR -> SError(NMI) -> panic
```

关键反证:同一次开机里 `0x15f` 出现 2 次都**没有**崩;拔掉 PD 后把链路彻底拆干净也不崩。
致死的不是"断电",而是**断电后又被软件把视频流拉活,然后二次拆链**。

**修复**:所有会写 `echo 1 > drm_dp/hpd`(或等效重新上流)的路径全部校验外部供电。

| 触发点 | v1.6.0 行为(无外部供电时) |
|---|---|
| `screenvid.sh` 亮屏恢复 | 整段跳过,保持 `video_off` 标记(同时抑制主守护的虚拟拔插);只记一条日志 |
| `screenvid.sh` 主动守卫 | `usb/online` 边沿立刻 `hpd=0`;无供电期间每 3 秒复核,被重新拉活就再按下去 |
| `service.sh` 开机补救 | 不清标记、不拉高 HPD |
| `service.sh` 刷新率重枚举 | 跳过,只保留像素时钟上限 |
| `service.sh` 恢复引擎 | 解除武装(不再空转 100 秒重试阶梯),供电回来自动重新武装 |
| `action.sh`(「执行」按钮) | 拒绝强制恢复并提示先接 PD |
| `web/cgi-bin/hz` | 只写上限,跳过重枚举 |
| `web/cgi-bin/recover` | 拒绝虚拟拔插 |

**供电判定依据**(本机实测):

| 状态 | usb/online | power_role | otg/online | 电池电流 |
|---|---|---|---|---|
| 屏 PD 在位 | 1 | sink | 0 | 充电(正) |
| 屏 PD 拔掉 | 0 | source | 1 | 放电 ~1.9A |

节点不存在(安装/卸载脚本环境)时判定为"无法判断",**不**拦截,避免安装后黑屏。

**行为取舍**:屏幕 PD 断电期间外接屏不显示(宁可黑屏,不要重启)。**PD 接回后约 3 秒
画面自动恢复**,无需重新插拔一线通。息屏/亮屏切换在供电正常时行为完全不变。

**关闭方式**(不推荐):`/data/adb/tpdp/config` 写 `VBUS_GUARD=0`。
此时模块恢复 v1.4.0 行为,允许平板用自身电池给屏供电——崩溃风险自负。

## 判活方式与供电防抖(v1.7.0 / v1.8.1)

守卫本身也踩过两个坑,现在都改掉了:

**一、`status=connected` 会骗人(v1.7.0)。** PD 一回来就立刻 `echo 1 > hpd` 会把链路
打成半协商态:内核报 `status=connected` + `enabled`、`dpms=On`,而 `dp_debug pclock=0`
——软件以为正常,屏幕是黑的。所以判活统一改成 **`pclock > 0`**,并且:

- `hpd=0` 在本内核是**空操作**(`rc=0`、零状态变化、零内核日志),所有「拉低 HPD」的
  路径全部删除,不再假装在做事;
- PD 回来后先 `PD_SETTLE=4` 秒等 VDM 协商结束,再考虑恢复。

**二、VBUS 会抖(v1.8.1)。** 写 `port_type` 期间 `usb/online` 会出现 1→0→1 的跳变,
单次采样就判定「供电回来了」会在协商窗口里上流(19:18 那次黑屏就是这么来的)。现在
要求 **连续 `VBUS_OK_STRIKES=3` 次采样**都是 `usb/online=1` 才算回来;启动时心跳计数
先按满值播种,避免开机瞬间误判成「VBUS 断了」。

`sink` 闸门(`SINK_GATE`)实测无效甚至更差,默认关闭:钉 `sink` 并不能停掉 5V,内核
约 48 秒后重新装回 Source,期间仍供 1.3–1.5A,比原厂自然翻转的 ~25 秒更差,还会反复
撕链路让端口卡在 `[source]` 充不进电。保留开关仅供实验。

## 切断对外 5V:拔掉 PD 后屏幕真的没电(v1.9.1)

v1.6.0 只保证「不崩溃」,拔掉 PD 后屏幕其实**一直有电**——平板翻成 Source 用电池反供
(实测约 1.9A)。要让屏幕断电必须关掉平板的 5V boost,而本机实测有效的杠杆只有一个:

| 杠杆 | 结果 |
|---|---|
| `hpd=0` / `power_role=sink` | 空操作 / 被拒,回读仍 `[source]` |
| `port_type=sink` | 立刻断链,但内核 ~48s 后重装 Source,期间仍供 1.3–1.5A;partner 挂着时直接 `invalid typec_role` |
| `otg/online=0` 单次写 | 充电驱动 1 秒内重新打开 |
| **`otg/online=0` 每 200ms 持续压制** | **有效,真正断电** |

`otgcut.sh`(v1.9.1 新增,第四个守护):

- 外部 VBUS 连续 `CUT_STRIKES=3` 次缺失(默认 0.2s 一次)后接管,把 `otg/online` 按回 0;
- PD 回来连续 `CUT_RELEASE=20` 次采样才释放,避免抖动期反复开合;
- **安全闸** `OTG_CUT_GUARD=1`:只有对端 `supports_usb_power_delivery=yes`、或本次开机
  DP 亮过(`/data/adb/tpdp/dp_ever`),才允许压制——否则接 U 盘的普通 OTG 会话也会被断电;
- 心跳 `hb.otg`,由 `service.sh` 监督;`ENABLED=0` 或卸载时随其它守护一起退出,
  退出后 `otg/online` 立即交还内核。

判断到底断没断电看电流,不要靠摸:

```bash
adb shell su -c 'watch -n1 "cat /sys/class/power_supply/battery/current_now; cat /sys/class/power_supply/otg/online"'
# -1900 左右 = 仍在反供; -700 以上 = 已停供
```

## 恢复阶梯中途被拔 PD 立即中止(v1.9.2)

`restore_video()` 的阶梯(虚拟拔插 2s + 12 次轮询 + 4 次轮询 + 熄屏亮屏 6 次)要跑 20 多秒。
此前只在**入口**查一次外部供电,阶梯跑到一半拔线仍会走到 `hpd=1`——正是 17:36 panic
那条路径(20:48:13 实测撞上,只是运气好没炸)。现在每级执行前、以及每个轮询里都复查
(`vbus_lost_mid_restore()`),供电消失立即中止:

```
restore ABORTED at step1/poll: external VBUS disappeared mid-repair (...) - holding the link down instead of forcing HPD
```

## 模块总开关(v1.10.0,默认启用)

界面顶部「启用模块」,或者配置 `ENABLED`。**`ENABLED=0` 不是「少做一点」,而是「完全不做」**,
且所有副作用只在一处执行(`service.sh` 的 `apply_enabled()`),Web 端只负责改写配置,
避免两个写者和 supervisor 抢状态。

| 关闭时 | 原因 |
|---|---|
| `screenvid` / `wakegate` / `otgcut` 全部退出(先 TERM,1 秒后仍活着再 KILL) | 实测 `screenvid`、`wakegate` 卡在 `sleep` 里不响应 TERM |
| 释放 `sink_gate` 标记,`port_type` 写回 `dual` | sink-only 端口**不能充电**,而且这个状态跨重启保留 |
| 清 `video_off`;**只有确有外部供电**才 `hpd=1` | 无供电强拉 HPD 就是 panic 路径 |
| 像素时钟上限恢复内核原值 | 否则限帧还在,等于没关干净 |
| 主循环转纯观察态 | 不碰端口、不做故障恢复、不拉守护,只写心跳 + 盯 `config`,所以随时能再打开 |

开启后三个守护重新拉起、上限重新施加,**3 秒内生效,无需重启**,其它设置(目标设备、
唤醒控制、刷新率档位)全部保留。

与「面具里禁用模块」的区别:那样要重启才生效,而且不会执行上面这些还原动作。

## 配置(可选)

复制并编辑 `/data/adb/tpdp/config`:

```sh
# ---- 目标设备与轮询 ----
TP_VID=04f3            # 触摸屏 idVendor
TP_PID=8512            # 触摸屏 idProduct
POLL_SEC=3             # 轮询间隔(秒)
STRIKES=2              # 连续多少次检测到故障才动作(防抖)
MAX_RETRY=5            # 每次故障最多尝试恢复次数
BOOT_DELAY=20          # 开机后延迟(秒),等待系统稳定

# ---- 本地配置界面 ----
WEB_TIMEOUT=300        # 配置界面自动关闭秒数(默认 5 分钟)

# ---- 息屏切断视频(v1.3.0) ----
VIDEO_SWITCH=1         # 1=息屏切断视频输出, 0=关闭该功能
POLL_TICKS_ON=15       # 亮屏态: 每多少秒用 dumpsys 兜底校验一次
POLL_TICKS_OFF=3       # 息屏态: 每多少秒兜底校验一次(越小唤醒恢复越快)
VIDEO_MAX_FAIL=5       # 切断连续失败多少次后自动停用该功能(保持视频开启)

# ---- 刷新率(v1.3.3) ----
HZ_MODE=60             # 60 / 120 / auto(像素时钟上限分别 300000 / 560000 / 内核原值)
PCLK_CAP_KHZ=300000    # 60 档的上限
PCLK_120_KHZ=560000    # 120 档的上限

# ---- 亮屏来源控制(v1.4.0) ----
WAKE_GATE=1            # 1=仅触摸/电源键可亮屏, 0=不限制亮屏来源
WAKE_GATE_TOUCH=1      # 1=允许触摸点击唤醒(仅 WAKE_GATE=1 时生效)
TIMEOUT_ENFORCE=1      # 1=系统自动息屏被唤醒锁屏蔽时强制休眠

# ---- 外部供电守卫(v1.6.0 / v1.8.1) ----
VBUS_GUARD=1           # 1=无外部供电时禁止任何"重新上流"动作(建议保持 1)
PD_SETTLE=4            # PD 接回后等多少秒让协议协商结束再恢复
VBUS_OK_STRIKES=3      # usb/online 连续几次采样为 1 才算"供电回来"
SINK_GATE=0            # 钉 sink 来断电:实测无效且更差,勿开

# ---- 切断对外 5V(v1.9.1) ----
OTG_CUT=1              # 1=拔 PD 后压制 otg/online, 0=不压制(屏幕会继续被反供)
OTG_CUT_GUARD=1        # 1=仅对端支持 PD/本次开机 DP 亮过才压制, 防误伤 U 盘
CUT_POLL=0.2           # 压制周期(秒),5Hz
CUT_STRIKES=3          # 连续几次无 VBUS 才开始压制
CUT_RELEASE=20         # 连续几次有 VBUS 才释放

# ---- 总开关(v1.10.0) ----
ENABLED=1              # 1=启用模块, 0=完全停手(等同界面顶部开关)
```

配置文件被修改(含从 Web 界面保存)后,守护进程会在一个轮询周期内自动重新加载。

`ENABLED=0` 的具体行为见上文[模块总开关](#模块总开关v1100默认启用),核心是三个守护
全部退出、状态标记全部释放、端口与像素时钟交回系统,重新写回 `1` 后 3 秒内恢复。

## 日志与排错

- 日志: `/data/adb/tpdp/log`(自动截断至 512KB)
- 手动触发: Magisk 模块页的"执行"按钮(action.sh)
- 一键看关键状态(判活只看 `pclock`):

```bash
adb shell su -c 'echo usb=$(cat /sys/class/power_supply/usb/online) otg=$(cat /sys/class/power_supply/otg/online) role=$(cat /sys/class/typec/port0/power_role) ma=$(cat /sys/class/power_supply/battery/current_now); echo dp=$(cat /sys/class/drm/card0-DP-1/status); grep -m1 pclock= /sys/kernel/debug/drm_dp/dp_debug'
```

- 常见日志行:`restore SUPPRESSED: no external VBUS`(守卫在拦)、
  `PD settled, link healthy`(供电回来且链路已自愈)、
  `[otgcut] otg boost cut #N`(5V 被压下去)、`restore ABORTED at step...`(中途被拔线)

## 已知边界

- 屏幕完全不上电时模块不会动作(触摸 USB 不在线,无从判断目标存在);
  先给屏幕供电,模块会在触摸 USB 枚举后自动接管。
- `port_type` 写入仅在 root(u:r:magisk:s0)上下文可用,普通 shell 无效;而且**partner
  挂着时内核会拒绝**(`max77705_port_type_set: invalid typec_role`),所以断电不能靠
  它,只能靠 `otgcut` 压 `otg/online`。
- 5V 切断有两个前提:对端声明支持 PD,或本次开机 DP 亮过。接 U 盘等普通 OTG 设备时
  `OTG_CUT_GUARD` 会拦住,不会被动断电。
- sink-only 端口**不能充电**,所以任何把 `port_type` 钉在 `sink` 的方案都是死路
  (这也是 `SINK_GATE` 默认关闭的原因)。
- 模块动作只会在 DP 已断链时发生,正常使用中不会打扰工作中的画面。

## 卸载

Magisk app → 模块 → 本模块 → **「卸载」**按钮 → 重启。v1.2.1 起清理完全自动化：

**卸载时会发生什么**:
1. 点击卸载后模块进入"待卸载"状态(重启后生效;此期间可点「还原」撤销);
2. 重启时 Magisk 删除模块本体(代码、Web 界面、staged 更新),并执行 `uninstall.sh`:
   - 终止全部守护(`service` / `screenvid` / `wakegate` / `otgcut`)、Web 服务(httpd)
     及超时脚本(若仍在运行)。kill 前先校验 `/proc/<pid>/cmdline`,不会误杀复用了
     旧 PID 的其他进程;`otgcut` 一退出,`otg/online` 立即交还内核,不会继续压制;
   - 还原内核侧改动:像素时钟上限恢复内核默认、被钉成 sink-only 的端口恢复 `dual`、
     DP 视频输出恢复。**最后一步只在 `usb/online=1`(确有外部供电)时执行**,
     否则保持链路关闭——无供电时强拉 HPD 会让 DP 在平板自身电池上重新上流,
     正是本模块要防的那条内核 panic 路径;
   - 删除 `/data/adb/tpdp/`(配置、日志、pid、心跳、`video_off` 等标记全部清除);
   - 复核 `/data/adb/tpdp*` 是否真的清空,结果打印到 Magisk 安装日志
     (最后一行应为 `cleanup complete - nothing outside the module dir remains`);
3. 模块**不创建**数据库、系统注册项、缓存或系统属性,卸载后无任何残留。
   (唯一相关的 `persist.adb.tcp.port` 是无线 ADB 的用户设置,早于本模块存在,
   卸载不触碰;不再需要无线 ADB 可执行 `adb shell su -c 'setprop persist.adb.tcp.port -1'`)

**卸载后自检**(确认系统功能不受影响):
```sh
adb shell su -c 'ls /data/adb/modules/ | grep tab_dp'      # 应无输出
adb shell su -c 'ls /data/adb/tpdp 2>&1'                   # 应报 No such file
adb shell su -c 'ls /data/adb/service.d/'                  # 不应出现任何 dp/tpdp 脚本
adb shell su -c 'cat /sys/class/extcon/extcon0/state'      # DP=1 外接屏仍正常
adb shell su -c 'pgrep -f tab_dp_watchdog'                 # 应无输出(无残留进程)
```

**卸载失败/出问题时的回滚**:
- 卸载前想撤销:直接点 Magisk 的「还原」按钮(卸载未生效前随时可反悔);
- 卸载后想恢复:重新安装 `tab-dp-watchdog-vX.Y.Z.zip` 即可(所有功能立即回归,
  无需任何手工修复);
- 万一模块导致开机异常:安全模式(开机动画时长按音量减)会自动禁用所有模块,
  进入后卸载本模块再重启;极端情况 `adb shell magisk --remove-modules` 移除全部模块。
