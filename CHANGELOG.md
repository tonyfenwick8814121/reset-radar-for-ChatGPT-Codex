# 版本记录 · Changelog

## 0.2.4 — 2026-09-28

- 修复“Resets all propagated. That will be all.”被误显示为新重置预告；完成公告优先按已完成处理。
- 旧版保存的未确认预告不再占据主窗口；最近记录显示原帖日期并区分预告与重置。

- Fixed a completed reset post being displayed as a new upcoming reset because of “That will be all.”
- Previously saved unconfirmed leads no longer occupy the main window; recent history uses the post date and distinguishes previews from resets.

## 0.2.3 — 2026-09-23

- 修复 GPT-6 Sol 发布时，Tibo 原帖未写 Codex／ChatGPT 导致的手动重置机会漏报。
- 周二明确承诺作为时间、类型待定的预告提醒；向 Plus／Pro／Business 发放中的手动机会提醒但不宣称已到账。
- 对真实公告回放、跨来源合并和重复提醒增加回归测试。

- Fixed the missed Sol launch banked-reset announcement when the original post omitted Codex/ChatGPT keywords.
- Trusted Tuesday promises alert with time/type pending; banked-reset rollouts name eligible plans without claiming delivery is complete.
- Added regression coverage for real announcements, source merging, and duplicate alerts.

## 0.2.2 — 2026-09-13

- 新增公开 JSON 来源，改进确定预告的识别；时间不明确时提醒但不猜测倒计时。
- 补偿机会保留提醒并说明适用条件；完善完成、24小时归档与重复提醒处理。
- 新增置顶开关、单色菜单栏状态、快捷查询及五档检测间隔（默认10分钟）。

- Added a public JSON source and improved confirmed-announcement detection without guessing ambiguous times.
- Kept compensation alerts with eligibility wording; improved completion, 24-hour archival and deduplication.
- Added pin controls, monochrome menu-bar states, quick refresh and five polling intervals (default: 10 minutes).

## 0.2.1 — 2026-09-09

- 常规查询静音，仅新机会或重要更正响铃，修复重复提醒。
- Silent routine checks; sound only for new opportunities or important corrections; duplicate alert fixes.

## 0.2.0 — 2026-09-09

- 区分自动重置与手动机会的倒计时和结束流程；增加手动录入，改进时间解析。
- Separate countdown and completion flows for automatic resets and manual opportunities; manual entry and improved time parsing.

## 0.1.0-preview — 2026-09-09

- 首个 macOS 预览版：公开订阅、悬浮倒计时、双语、时区和本地通知。
- First macOS preview: public feeds, floating countdown, bilingual UI, time zones and local notifications.
