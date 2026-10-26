# 版本记录 · Changelog

## 0.4.4 — 2026-10-26

- 修复操作卡顿与持续高CPU占用：窗口每秒刷新曾反复筛选AI历史、解析活动背景并计算指纹，现在仅在数据变化后重建筛选结果。
- 帖子编辑、回复/活动背景、分析状态和已读变化仍立即更新显示；24小时有效期继续按当前时间判断，不缓存过期状态。
- 每秒倒计时、来源查询间隔、重置判断、提醒去重及AI调用限制保持；本次修复不要求重新分析旧帖。

- Fixed sluggish controls and sustained high CPU caused by repeatedly parsing and hashing AI history during display ticks.
- Unchanged history selection is reused; edits, context, analysis results and acknowledgments invalidate it. Expiry remains time-dependent.
- Preserves second-by-second countdowns, polling intervals, detection, notification deduplication and AI request limits. No historical reanalysis is required.

## 0.4.3 — 2026-10-20

- 修复“Day 15/ … and reset. Enjoy.”等连续活动完成公告漏报：引用同一作者有效期内的活动承诺，仅在本条有肯定交付表达时判为完成，不把每天的活动承诺当作每天已重置。
- 直接回复当天重置标记的时间预告可获得话题背景；继续区分预告和完成，保留日期及时区校验。
- AI 请求加入可追溯的活动原文；缺上下文或可信重置相关帖双方都没判断出来时显示“信息不足 · 待核对”，不再笼统视为一致。普通闲聊、愿望、密码重置等不因缺上下文而触发复核提醒。
- 升级按缓存原文补发24小时内漏掉的完成通知一次，保留首次发现时间、已读/已处理及通知记录；旧无关成功缓存不重新请求，旧历史可读。
- 活动背景按原文有效期约束并保留在有界缓存中；读取凭据移至实际分析时的后台操作，规则监测与启动不再等待钥匙串授权。仅在两个指定的免费模型间切换，明确关闭思考并将输入/输出价格上限设为0；404归类为服务不可用，每滚动24小时最多20次分析，不回退付费模型。

- Fixed concise campaign completion misses using the same author's active public pledge as topic context, while requiring an affirmative delivery in the current post.
- Supports reset-topic timing in direct replies and separates incomplete context from agreement. Unrelated chatter does not trigger uncertainty notices.
- Backfills one recent missed completion on upgrade; preserves handled states and history, reuses unrelated successful caches, and keeps Keychain waits off rule startup and the UI thread.

## 0.4.2 — 2026-10-15

- 补充 macOS 标准编辑菜单，修复密码输入框 ⌘V、⌘A 等快捷键无法生效。
- 授权成功后持续显示绿色确认；Key 已保存/已启用与单次分析失败分别展示。
- 主窗口、迷你窗及菜单栏同步显示 AI 待核对发现；点击可查看依据，确认阅读、停用或24小时过期后取消提示。规则倒计时与已确认结果继续显示，不将 AI 候选升级为已确认事件。
- 区分超时、服务不可用、请求被拒、额度不可用、回答截断、空回答、格式及原文校验失败；仅保存状态码、结束原因和用量数字，不保存 Key、服务器错误原文或模型思考内容。
- 免费请求输出上限调整为4096，并请求较低思考强度，降低截断风险。仍只使用 openrouter/free，每24小时20次、每条版本最多2次，不重新分析缓存成功项或重置旧失败次数。
- 禁用重试时解释冷却或次数限制，过期的未分析记录不再显示成正在排队。

- Restored standard macOS editing shortcuts and added persistent authorization confirmation.
- AI review findings now appear across the main/mini windows and menu bar without replacing confirmed rule events or creating AI-only countdowns.
- Distinct, sanitized failure reasons and bounded diagnostic metadata; a 4096-token output cap with low reasoning effort reduces truncation risk. Free-only routing, caching, the 20-per-24-hour cap and two-attempt limit remain.
- Explains disabled retries and marks unreviewed posts older than 24 hours as outside the review window.

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
