# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)（MAJOR.MINOR.PATCH）。
每个版本的完整发布说明见 [GitHub Releases](../../releases)。

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
