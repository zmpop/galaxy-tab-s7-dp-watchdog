# Tab S7 DP 显示链路看门狗 (Tab S7 DP Link Watchdog)

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

Magisk app → 模块 → 从本地安装 → 选择 tab-dp-watchdog-v1.4.0.zip → 重启。

## USB 设备选择界面(v1.2.0)

换了触摸屏/扩展坞,不再需要手动改配置文件——点击 Magisk 模块页的**「执行」**按钮,
平板会自动弹出浏览器打开本地配置界面(`http://127.0.0.1:8899/`):

- **自动搜索**:一键列出"屏幕相关"USB 设备(按名称/USB 类别打分推荐:触摸 > 显示 > 坞站/集线器 > HID);
- **手动列出**:一键列出当前全部外接 USB 设备,自行挑选;
- **保存**:选定设备后点击"保存所选设备",写入配置,守护进程数秒内自动热加载(无需重启);
- **手动恢复**:界面内还有"尝试恢复显示链路"按钮(链路正常时不会动作);
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

## 配置(可选)

复制并编辑 `/data/adb/tpdp/config`:

```sh
TP_VID=04f3            # 触摸屏 idVendor
TP_PID=8512            # 触摸屏 idProduct
POLL_SEC=3             # 轮询间隔(秒)
STRIKES=2              # 连续多少次检测到故障才动作(防抖)
MAX_RETRY=5            # 每次故障最多尝试恢复次数
BOOT_DELAY=20          # 开机后延迟(秒),等待系统稳定
WEB_TIMEOUT=300        # 配置界面自动关闭秒数(默认 5 分钟)
VIDEO_SWITCH=1         # 1=息屏切断视频输出, 0=关闭该功能
POLL_TICKS_ON=15       # 亮屏态: 每多少秒用 dumpsys 兜底校验一次
POLL_TICKS_OFF=3       # 息屏态: 每多少秒兜底校验一次(越小唤醒恢复越快)
VIDEO_MAX_FAIL=5       # 切断连续失败多少次后自动停用该功能(保持视频开启)
WAKE_GATE=1            # 1=仅触摸/电源键可亮屏, 0=不限制亮屏来源
WAKE_GATE_TOUCH=1      # 1=允许触摸点击唤醒(仅 WAKE_GATE=1 时生效)
TIMEOUT_ENFORCE=1      # 1=系统自动息屏被唤醒锁屏蔽时强制休眠
VBUS_GUARD=1           # 1=无外部供电时禁止任何"重新上流"动作(v1.6.0, 建议保持 1)
ENABLED=1              # 1=启用模块, 0=完全停手(Web 界面顶部的总开关, v1.10.0)
```

配置文件被修改(含从 Web 界面保存)后,守护进程会在一个轮询周期内自动重新加载。

`ENABLED=0` 不是「少做一点」而是「完全不做」:三个守护(`screenvid` / `wakegate` /
`otgcut`)全部退出,故障恢复停止,`sink_gate` 与 `video_off` 标记被释放、`port_type`
写回 `dual`(sink-only 端口不能充电,且该状态跨重启保留),像素时钟上限恢复成内核
原值。其余设置全部保留,写回 `ENABLED=1` 后 3 秒内恢复,无需重启。

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

Magisk app → 模块 → 本模块 → **「卸载」**按钮 → 重启。v1.2.1 起清理完全自动化：

**卸载时会发生什么**:
1. 点击卸载后模块进入"待卸载"状态(重启后生效;此期间可点「还原」撤销);
2. 重启时 Magisk 删除模块本体(代码、Web 界面、staged 更新),并执行 `uninstall.sh`:
   - 终止看门狗守护进程、Web 服务(httpd)及超时脚本(若仍在运行)。kill 前先校验
     `/proc/<pid>/cmdline`,不会误杀复用了旧 PID 的其他进程;
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
