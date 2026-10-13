# 版本记录 · Changelog

## 0.4.1 — 2026-10-13

- 新增明确太平洋时区的 EOD / end of day 截止倒计时，以原帖当地日期的次日午夜作为估算上限，明确标注“预计最迟 / 可能提前”。
- PST 固定 UTC−8、PDT 固定 UTC−7、PT 跟随夏令时；支持 today / tomorrow，缺少时区、发布时间或不支持的日期不猜测。
- 修复已保存预告的倒计时；提前完成公告结束同一次倒计时，不另报新机会。到零仍等待确认，24 小时后归档。原有手动机会、用户处理状态及提示音规则保持。

- Added estimated EOD / end-of-day deadline countdowns with explicit Pacific zones, anchored to the original publication date. Midnight is an estimate, not an exact reset instant.
- PST is UTC−8, PDT UTC−7, and PT follows seasonal Pacific time. Missing context or unsupported dates remain unresolved.
- Restores saved previews silently, joins early completion with the same opportunity, and waits for confirmation at zero before 24-hour archival. Manual grants, handled states and sound behavior are preserved.

## 0.4.0 — 2026-10-11

- 新增默认关闭、需明确授权的 OpenRouter 免费模型交叉验证；所有新鲜 Tibo 原帖都参与复核，不以 reset 关键词预筛选。
- AI 与现有规则独立判断，疑似漏报或分歧显示待核对与原文依据；保留规则提醒，不将 AI 判断自动升级为确认重置或倒计时。
- 凭据仅保存在 macOS 钥匙串；固定 `openrouter/free`，禁止付费回退，同帖缓存，回复上文和编辑会更新缓存。
- AI 授权失败、连接失败、格式/原文校验失败、限流单独展示；每 24 小时最多 20 次分析，每个版本最多两次尝试，停用取消后续处理。
- Optional, explicitly authorized OpenRouter free-model cross-check. Rules remain independent; possible misses are shown as unverified review findings, with original evidence. Keychain storage, caching, bounded requests, no paid fallback.


## 0.3.3 — 2026-10-11

- 修复可信发布者的 “Global reset by EOD” 等简短承诺被留在未确认状态；无精确时间或时区时提前提醒但不生成倒计时。
- 修复 “Put the reset in the bag. All propagated.” 的跨句完成确认漏报；仅继承相邻、肯定且非未来承诺的自动重置上下文。
- 同次完成及传播消息去重；升级关联已保存的漏报预告与完成，补发一次近期完成通知，保留处理状态。

- Fixed trusted concise promises such as “Global reset by EOD” being left unconfirmed; imprecise timing alerts without inventing a countdown.
- Fixed split completion confirmations such as “Put the reset in the bag. All propagated.”, using only adjacent affirmative automatic-reset context.
- Deduplicates propagation follow-ups and joins missed saved previews with their completion on upgrade, backfilling one recent notice and preserving handled state.

## 0.3.2 — 2026-10-07

- 新增独立的“刚刚已重置”通知：窗口自动显示、按声音设置响铃，并发送系统横幅；不生成倒计时。
- 识别 reset has been processed / completed / applied 等完成表达，仍过滤否定、问句、猜测与发放中表述。
- 主窗口、迷你窗和菜单栏显示完成标志；显示公告发布时间，可点“知道了”收起，24小时后自动归档。
- 同次预告、完成及传播确认合并，保存已提醒记录；重复查询、重启、已忽略记录及旧公告不重复提醒。升级补发24小时内尚未提醒的完成公告。

- Added separate reset-completed notices: automatic window reveal, sound according to preferences, and a system banner, without a countdown.
- Recognizes processed / completed / applied reset wording while filtering negation, questions, speculation and in-progress claims.
- Main / mini windows and the menu bar show completion; the announcement timestamp is displayed, with acknowledgement and 24-hour archival.
- Previews, completion and propagation follow-ups share one event and persistent notification receipt. Rechecks, restarts, dismissals and stale posts remain quiet; upgrades backfill unnotified completions from the last 24 hours.

## 0.3.1 — 2026-10-02

- 修复 “tomorrow 10am PST” 未写 at 导致明确时间被显示为待确认的问题。
- “明天”按原帖发布时间及原文时区计算；PST 固定 UTC−8，PDT 固定 UTC−7，PT 按当地夏令时规则。
- 升级时静默补全已保存预告的倒计时，保留已处理记录；缺少发布时间或时区时仍不猜测。

- Fixed explicit reset times being left unresolved when “tomorrow 10am PST” omits “at”.
- Resolves “tomorrow” from the publication date and stated zone: PST is UTC−8, PDT is UTC−7, and PT follows seasonal Pacific time.
- Silently restores countdowns for saved previews on upgrade while preserving handled records; missing publication dates or zones remain unresolved.

## 0.3.0 — 2026-09-28

- 重写句子级判断：明确承诺即提醒，时间不确定时保留预告；过滤否定、疑问、教程与猜测。
- 手动机会区分预告、发放中、可用与失效；受影响用户补发保留资格说明。
- 完成公告只结束对应事件；原文优先于摘要，同一次机会的多帖更新不重复创建。
- 发放、重置、失效时间分别解析；升级静默重评旧记录，保留用户处理状态。

- Rebuilt sentence-level detection: explicit promises alert before precise timing is known; negation, questions, tutorials and speculation are filtered.
- Banked-reset previews, rollouts, availability and expiry are distinct; compensation keeps eligibility information.
- Completion closes the matching event; original evidence outranks summaries and related posts update one opportunity.
- Availability, reset and expiry times are parsed separately; upgrades silently reassess old evidence while preserving user choices.

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
