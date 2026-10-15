# AI 交叉验证 / AI cross-check

## 中文

默认关闭。开启后，原有规则仍独立检测、提醒和生成倒计时。AI 不使用规则结果，而是理解公开原帖，再与规则比较。

1. 从菜单栏选择“AI 交叉验证…”，点击“创建免费 Key”。在 [OpenRouter](https://openrouter.ai/settings/keys) 注册/登录并自行创建 Key；无需充值。不要把 Key 发到聊天或仓库。
2. 在应用的密码输入框用 ⌘V 粘贴 Key，阅读并勾选授权说明，然后选择“授权并启用”。先验证凭据，成功后存入本机 macOS 钥匙串，并显示绿色“授权成功 · AI 已启用”确认。单次分析失败与授权状态分别显示。
3. 后续随原有查询周期分析新帖。首次开启复核最近 24 小时的帖子。无需 X 登录，复核不消耗 ChatGPT / Codex 订阅额度。

仅调用 `openrouter/free`，由 OpenRouter 选择当前可用的免费模型。没有付费模型回退；免费服务会限流，可能暂时不可用。每个帖子/编辑/回复上文版本缓存一次成功结果，每 24 小时最多 20 次分析，每个版本最多两次尝试。失败不会显示成“未发现重置”，手动重试不能越过服务冷却或本地请求上限。新版区分超时、服务不可用、回答截断、空回答、格式和依据校验等原因；旧版笼统失败记录无法还原具体原因。禁用重试时会说明原因，新帖继续独立处理。输出上限4096、较低思考强度，减少思考挤占回答空间；不保存模型思考内容。

发送的数据只有 Tibo 公开帖子原文、发布时间、帖子 ID，以及公开转引中能获取到的直接回复上文。不会发送 Key 给模型，也不会发送你的订阅、额度、其他本地文件或规则结果。Key 仅通过 HTTPS 的 Authorization 头发送给 OpenRouter。不会访问原帖里的链接。转引缺帖或缺上下文时，AI 也无法补齐。

- 一致：保留原有提醒，不重复弹窗。
- 疑似漏报或分歧：主窗口、迷你窗及菜单栏显示醒目的 AI 待核对提示，点击进入原帖、依据和解释。规则已有结果仍保留；“知道了”、停用或原帖24小时过期后取消该提示。
- 类型/阶段等有分歧：显示待核对，原有规则提醒不会被撤销。AI 提供明确的候选重置判断时，弹出复核窗口。
- 待核对窗口无提示音，不把结果当成账号已重置；AI 提取的时间仅作参考，不单独生成倒计时。
- “知道了”仅确认已阅读；“停用 AI”停止新请求；“移除 Key”停用并移除本机凭据。需要撤销网站上的 Key 时，在 OpenRouter 操作。

**验收边界：** v0.4.0 的授权、请求限制、缓存、状态、交叉验证、原文校验和界面已通过模拟服务及本机测试。没有用户凭据时无法验证实时模型判断质量；本功能仍为可选复核，不能保证所有公告都会被抓取或正确理解。

[免费路由说明](https://openrouter.ai/docs/guides/routing/routers/free-router) · [授权说明](https://openrouter.ai/docs/api_reference/authentication)

## English

Off by default. Rules continue to detect, alert and create countdowns independently. AI receives original public posts, not rule results, and its interpretation is compared afterward.

1. Choose “AI cross-check…” from the menu bar. Create your own free key at [OpenRouter](https://openrouter.ai/settings/keys). No top-up is required. Keep keys out of chats and repositories.
2. Paste it into the app’s secure field, accept the authorization notice and choose “Authorize & enable”. Valid credentials are stored in this Mac’s Keychain, with a green authorization confirmation. Analysis failures are shown separately from authorization status. Standard ⌘V / ⌘A shortcuts are supported.
3. New posts are reviewed on the regular check cycle. Initial authorization reviews the latest 24 hours. No X login or ChatGPT / Codex subscription quota is needed.

Requests use only `openrouter/free`, with no paid fallback. OpenRouter selects an available free model; rate limits and temporary unavailability are possible. Successful results are cached per post/content/reply-context version, with up to 20 analyses per rolling 24 hours and two attempts per version. Retries respect cooldowns and the request budget.

Only public post text, publication dates, IDs and available direct reply context are sent to OpenRouter and its model providers. Account data, local files and rule results are excluded. The key goes only to OpenRouter in the HTTPS Authorization header, never in the model input. Links in posts are not visited. Missing relay content cannot be recovered by this feature.

Agreement produces no extra alert. Possible misses and differing types/phases appear with original evidence as unverified review findings. Explicit AI reset candidates open the review window without sound. Pending findings also appear in the main/mini windows and menu bar, with a direct evidence link, while confirmed rule results remain. Acknowledgment, disabling AI or the post aging past 24 hours clears the indicator. Rule alerts remain; AI timing never independently creates a countdown. Acknowledgment does not confirm an account reset. Disable stops requests; removal deletes the local key. Revoke a key on OpenRouter separately if needed.

**Validation boundary:** authorization, request limits, cache, states, comparison, evidence validation and UI have been checked locally with simulated services. Live interpretation quality requires an authorized credential and remains unverified without one. This optional feature cannot guarantee complete capture or correct interpretation of every announcement.


## v0.4.2 诊断说明 / Diagnostics

分析失败仅保存明确的错误类别、服务状态码、结束原因和用量数字，不保存 Key、服务器错误原文或模型思考内容。旧版记录只包含笼统错误类别，无法据此断定当时究竟是截断、格式还是引用问题。新的错误分类不提高重试次数，也不绕过免费路由或冷却。

Failures retain only a typed reason, HTTP status, finish reason and numeric usage metadata. Keys, raw server error messages and model reasoning are not stored. Legacy generic failures cannot establish whether truncation, formatting or evidence validation caused the historical failure. Retry limits and free-only routing remain unchanged.

[OpenRouter 思考与输出长度说明 / Reasoning and output limits](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)
