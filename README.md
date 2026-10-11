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

**[下载 v0.4.0 · Apple 芯片版](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases/download/v0.4.0/Reset-Radar-0.4.0-arm64.zip)**

需要 **macOS 14+、Apple 芯片（M 系列）和网络连接**。解压后将 `Reset Radar.app` 拖入“应用程序”并打开，无需安装开发工具。

当前为预览版，未做 Apple Developer ID 签名或公证，首次打开可能被 macOS 拦截。公开转引可能延迟或遗漏，额度与补偿资格请以账号实际状态为准。

### 版本更新

**v0.4.0 · 2026-10-11**

- 新增默认关闭的 AI 交叉验证，授权后用 OpenRouter 免费模型独立理解新帖，保留规则提醒。
- 结论不一致或疑似漏报时弹出“待核对”窗口，展示原文依据；失败、限流分别显示。
- Key 存入 macOS 钥匙串；缓存结果，每 24 小时最多 20 次分析，无付费模型回退。

在菜单栏选择“AI 交叉验证…”即可配置。[配置说明](docs/AI_REVIEW.md)

[完整版本记录](CHANGELOG.md) · [所有下载](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases)

## English

A free macOS menu-bar app that monitors public ChatGPT / Codex quota reset announcements with floating countdowns and sound alerts.

### Features

- Automatic reset previews and completion notices, manual reset and compensation alerts; manual announcement entry.
- Floating and mini windows, optional always-on-top, Chinese / English and local time zones.
- Checks every 1 / 5 / 10 / 15 / 20 minutes (default: 10), with check results and source status.
- No X login or ChatGPT / Codex quota usage. Optional AI cross-check requires your authorization and a free OpenRouter key.

### Download & requirements

**[Download v0.4.0 · Apple silicon](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases/download/v0.4.0/Reset-Radar-0.4.0-arm64.zip)**

Requires **macOS 14+, Apple silicon (M series) and internet access**. Unzip, drag `Reset Radar.app` into Applications and open it. No developer tools required.

This preview is not Developer ID signed or notarized; macOS may block the first launch. Public relays may delay or miss announcements. Check your account for actual quota and compensation eligibility.

### Updates

**v0.4.0 · 2026-10-11**

- Added optional AI cross-check, off by default. Authorized OpenRouter free models independently interpret new posts while rule alerts continue.
- Possible misses or disagreements open a review window with original evidence; failures and rate limits remain visible.
- Keys stay in macOS Keychain. Results are cached, with up to 20 analyses per rolling 24 hours and no paid model fallback.

Choose “AI cross-check…” in the menu bar to configure it. [Setup guide](docs/AI_REVIEW.md)

[Version history](CHANGELOG.md) · [All downloads](https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex/releases)
