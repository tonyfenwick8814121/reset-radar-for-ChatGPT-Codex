# 归零 · Reset Radar

[中文](#中文) · [English](#english)

## 中文

免费的 macOS 菜单栏工具，监测 ChatGPT / Codex 公开额度重置公告，用悬浮倒计时和声音提醒你。

### 功能

- 自动重置预告与完成通知、手动重置及补偿机会提醒，支持手动录入公告。
- 悬浮窗、迷你窗、可选置顶；中英文切换和本地时区显示。
- 检测间隔可选 1 / 5 / 10 / 15 / 20 分钟，默认 10 分钟；显示查询结果与来源状态。
- 无需 X 登录或 API 密钥，不调用 AI，不消耗 ChatGPT / Codex 额度。

### 下载与环境

**[下载 v0.3.3 · Apple 芯片版](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases/download/v0.3.3/Reset-Radar-0.3.3-arm64.zip)**

需要 **macOS 14+、Apple 芯片（M 系列）和网络连接**。解压后将 `Reset Radar.app` 拖入“应用程序”并打开，无需安装开发工具。

当前为预览版，未做 Apple Developer ID 签名或公证，首次打开可能被 macOS 拦截。公开转引可能延迟或遗漏，额度与补偿资格请以账号实际状态为准。

### 版本更新

**v0.3.3 · 2026-10-11**

- 修复“全球重置，日内完成”等简短预告漏报；缺少明确时区时不猜倒计时。
- 识别相邻句子的“全部生效”完成确认，继续过滤猜测、问句和否定。
- 升级关联本次漏掉的预告与完成记录，补提醒一次，避免旧预告重新出现。

[完整版本记录](CHANGELOG.md) · [所有下载](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases)

## English

A free macOS menu-bar app that monitors public ChatGPT / Codex quota reset announcements with floating countdowns and sound alerts.

### Features

- Automatic reset previews and completion notices, manual reset and compensation alerts; manual announcement entry.
- Floating and mini windows, optional always-on-top, Chinese / English and local time zones.
- Checks every 1 / 5 / 10 / 15 / 20 minutes (default: 10), with check results and source status.
- No X login, API key, AI calls or ChatGPT / Codex quota usage.

### Download & requirements

**[Download v0.3.3 · Apple silicon](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases/download/v0.3.3/Reset-Radar-0.3.3-arm64.zip)**

Requires **macOS 14+, Apple silicon (M series) and internet access**. Unzip, drag `Reset Radar.app` into Applications and open it. No developer tools required.

This preview is not Developer ID signed or notarized; macOS may block the first launch. Public relays may delay or miss announcements. Check your account for actual quota and compensation eligibility.

### Updates

**v0.3.3 · 2026-10-11**

- Fixed missed concise promises such as “Global reset by EOD”, without guessing a countdown or timezone.
- Recognizes adjacent “All propagated” completion confirmations while filtering speculation, questions and negation.
- Upgrades join the missed preview and completion, notify once and keep the old preview from resurfacing.

[Version history](CHANGELOG.md) · [All downloads](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases)
