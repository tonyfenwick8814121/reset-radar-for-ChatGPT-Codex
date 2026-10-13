# 归零 · Reset Radar

[中文](#中文) · [English](#english)

## 中文

免费的 macOS 菜单栏工具，监测 ChatGPT / Codex 公开额度重置公告，用悬浮倒计时和声音提醒你。

### 功能

- 自动重置预告与完成通知、手动重置及补偿机会提醒，支持手动录入公告。
- 悬浮窗、迷你窗、可选置顶；中英文切换和本地时区显示。
- 检测间隔可选 1 / 5 / 10 / 15 / 20 分钟，默认 10 分钟；显示查询结果与来源状态。
- 默认无需 X 登录或 API 密钥，不消耗 ChatGPT / Codex 额度。可选 AI 交叉验证需自行授权 OpenRouter 免费 Key。

### 下载与环境

**[下载 v0.4.1 · Apple 芯片版](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases/download/v0.4.1/Reset-Radar-0.4.1-arm64.zip)**

需要 **macOS 14+、Apple 芯片（M 系列）和网络连接**。解压后将 `Reset Radar.app` 拖入“应用程序”并打开，无需安装开发工具。

当前为预览版，未做 Apple Developer ID 签名或公证，首次打开可能被 macOS 拦截。公开转引可能延迟或遗漏，额度与补偿资格请以账号实际状态为准。

### 版本更新

**v0.4.1 · 2026-10-13**

- 修复明确时区的 EOD / end of day 预告没有倒计时的问题，显示“预计最迟”完成时间。
- PST / PDT 使用原文固定时差，PT 按夏令时换算；EOD 按当地午夜估算，可能提前完成。
- 升级静默补全已有预告；截止后等待确认，完成公告可提前结束倒计时。

可选 AI 交叉验证默认关闭，配置方式见[说明](docs/AI_REVIEW.md)。

[完整版本记录](CHANGELOG.md) · [所有下载](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases)

## English

A free macOS menu-bar app that monitors public ChatGPT / Codex quota reset announcements with floating countdowns and sound alerts.

### Features

- Automatic reset previews and completion notices, manual reset and compensation alerts; manual announcement entry.
- Floating and mini windows, optional always-on-top, Chinese / English and local time zones.
- Checks every 1 / 5 / 10 / 15 / 20 minutes (default: 10), with check results and source status.
- No X login or ChatGPT / Codex quota usage. Optional AI cross-check requires your authorization and a free OpenRouter key.

### Download & requirements

**[Download v0.4.1 · Apple silicon](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases/download/v0.4.1/Reset-Radar-0.4.1-arm64.zip)**

Requires **macOS 14+, Apple silicon (M series) and internet access**. Unzip, drag `Reset Radar.app` into Applications and open it. No developer tools required.

This preview is not Developer ID signed or notarized; macOS may block the first launch. Public relays may delay or miss announcements. Check your account for actual quota and compensation eligibility.

### Updates

**v0.4.1 · 2026-10-13**

- Fixed missing countdowns for EOD / end-of-day previews with an explicit time zone; displays an estimated completion deadline.
- PST / PDT keep their stated offsets; PT follows daylight saving time. EOD is estimated at local midnight and the reset may finish earlier.
- Silently restores saved preview countdowns on upgrade. Reaching the deadline awaits confirmation; an early completion notice ends the countdown.

Optional AI cross-check is off by default. [Setup guide](docs/AI_REVIEW.md)

[Version history](CHANGELOG.md) · [All downloads](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases)
