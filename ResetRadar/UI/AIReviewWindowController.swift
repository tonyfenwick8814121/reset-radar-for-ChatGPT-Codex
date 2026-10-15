import AppKit
import SwiftUI

@MainActor
final class AIReviewWindowController {
    private var window: NSWindow?
    func show(model: MonitorModel) {
        let locale = model.preferences.locale
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = locale == .zhHans ? "AI 交叉验证 · Reset Radar" : "AI cross-check · Reset Radar"
        window.isReleasedWhenClosed = false; window.center()
        window.contentView = NSHostingView(rootView: AIReviewView(model: model, reviewer: model.aiReview))
        self.window = window
        updatePreferences(model.preferences)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func updatePreferences(_ preferences: UserPreferences) {
        window?.title = preferences.locale == .zhHans ? "AI 交叉验证 · Reset Radar" : "AI cross-check · Reset Radar"
        window?.level = preferences.alwaysOnTop ? .floating : .normal
    }
}

struct AIReviewSummaryView: View {
    @ObservedObject var reviewer: AIReviewCoordinator
    let locale: AppLocale
    let onOpen: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(reviewer.needsAttention ? .orange : .secondary)
            Text("AI · " + reviewer.summary(locale)).lineLimit(2)
            Spacer()
            Button(locale == .zhHans ? "配置 / 查看" : "Setup / View", action: onOpen).buttonStyle(.plain).foregroundStyle(.blue)
        }.font(.system(size: 10))
    }
}

private struct AIReviewView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var reviewer: AIReviewCoordinator
    private var locale: AppLocale { model.preferences.locale }
    private var timeZoneID: String { model.preferences.displayTimeZone }
    @State private var key = ""
    @State private var consent = false
    @State private var removingKey = false
    private var zh: Bool { locale == .zhHans }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(.orange)
                    Text(zh ? "AI 交叉验证" : "AI cross-check").font(.system(size: 24, weight: .bold, design: .rounded))
                    Spacer()
                    Button("中 / EN") { model.setLocale(zh ? .en : .zhHans) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    Text(reviewer.state.enabled ? (zh ? "已启用" : "On") : (zh ? "未启用" : "Off"))
                        .font(.caption.bold()).padding(6)
                        .foregroundStyle(reviewer.state.enabled ? Color.green : .secondary)
                        .background(reviewer.state.enabled ? Color.green.opacity(0.14) : Color.gray.opacity(0.14), in: Capsule())
                }
                Text(reviewer.summary(locale)).font(.callout).foregroundStyle(reviewer.needsAttention || reviewer.message != nil ? .orange : .secondary)
                Text(zh ? "现有规则继续独立运行。AI 复核每篇新帖，发现疑似漏报或分歧时提供原文依据，结果需核对，不代表你的账户已重置。" : "Rules keep running independently. AI reviews each new post and surfaces possible misses or disagreements with original evidence. Review results do not confirm a reset in your account.")
                    .font(.callout).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(zh ? "授权 OpenRouter 免费模型" : "Authorize OpenRouter free models").font(.headline)
                            Spacer()
                            Link(zh ? "创建免费 Key ↗" : "Create free key ↗", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                        }
                        Text(zh ? "只使用 openrouter/free，无付费模型回退。每天最多 20 次分析；未变化的帖子不重复请求。免费服务可能限流或不可用。" : "Uses only openrouter/free, with no paid fallback. Up to 20 analyses per rolling 24 hours; unchanged posts are cached. Free service may be rate limited or unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField(zh ? "粘贴 Key（留空可使用已保存的 Key）" : "Paste key (leave blank to reuse saved key)", text: $key)
                            .textFieldStyle(.roundedBorder).disabled(reviewer.isConfiguring)
                            .accessibilityLabel("OpenRouter Key")
                        Toggle(zh ? "授权将公开原帖及可获取的直接回复上文发送给 OpenRouter 和模型服务商，并在本机钥匙串保存 Key。" : "Allow public posts and available direct reply context to be sent to OpenRouter and its model providers, and store the key in this Mac’s Keychain.", isOn: $consent)
                            .font(.caption).disabled(reviewer.isConfiguring)
                        HStack {
                            Button(reviewer.isConfiguring ? (zh ? "验证中…" : "Validating…") : (zh ? "授权并启用" : "Authorize & enable")) {
                                Task { if await reviewer.authorize(key: key, consent: consent) { key = ""; consent = false } }
                            }.disabled(!consent || reviewer.isConfiguring)
                            if reviewer.state.enabled {
                                Button(zh ? "停用 AI" : "Disable AI") { Task { await reviewer.disable() } }.disabled(reviewer.isConfiguring)
                            }
                            Button(zh ? "移除 Key…" : "Remove key…") { removingKey = true }.disabled(reviewer.isConfiguring || !reviewer.hasKey)
                            Spacer()
                        }
                        if reviewer.isConfiguring {
                            HStack { ProgressView().controlSize(.small); Text(zh ? "正在验证 Key，请稍候…" : "Validating your key…") }.font(.callout)
                        } else if reviewer.state.enabled && reviewer.hasKey && !reviewer.state.authorizationRequired {
                            Label(reviewer.authorizationSucceeded
                                  ? (zh ? "授权成功 · AI 已启用 · Key 已安全保存" : "Authorization successful · AI enabled · Key saved securely")
                                  : (zh ? "AI 已启用 · Key 已保存在本机钥匙串" : "AI enabled · Key saved in this Mac’s Keychain"), systemImage: "checkmark.circle.fill")
                                .font(.callout.bold()).foregroundStyle(.green)
                            Text(zh ? "后续分析失败不会撤销授权；具体原因见下方每条记录。" : "A failed analysis does not revoke authorization; see the reason on each record.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let failure = reviewer.message {
                            Label(failure.message(locale), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                        }
                        Text(zh ? "停用后不再请求模型；移除 Key 仅删除本机凭据，不撤销 OpenRouter 网站上的 Key。不要在聊天或截图中展示 Key。" : "Disabling stops model requests. Removing deletes the local credential; revoke it on OpenRouter separately if needed. Keep keys out of chats and screenshots.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(6)
                }
                HStack {
                    Text(zh ? "最近的独立复核" : "Recent independent reviews").font(.headline)
                    Spacer()
                    Button(zh ? "重试失败项" : "Retry failed") { Task { await reviewer.retryFailures() } }
                        .disabled(!reviewer.canRetryFailures)
                }
                if let explanation = reviewer.retryExplanation(locale) { Text(explanation).font(.caption).foregroundStyle(.secondary) }
                if reviewer.recentRecords.isEmpty {
                    Text(zh ? "尚无复核记录。授权后分析最近 24 小时的原帖，随后随检测周期复核新帖。" : "No reviews yet. Authorization reviews original posts from the last 24 hours, then new posts on the normal check cycle.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(reviewer.recentRecords.prefix(30)) { record in recordView(record) }
            }.padding(24)
        }
        .frame(width: 560, height: 660)
        .alert(zh ? "移除本机 OpenRouter Key？" : "Remove the local OpenRouter key?", isPresented: $removingKey) {
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
            Button(zh ? "停用并移除" : "Disable & remove", role: .destructive) { Task { await reviewer.removeKey(); key = ""; consent = false } }
        } message: {
            Text(zh ? "AI 复核将停用，现有规则监测与历史记录会保留。" : "AI review will be disabled. Rule monitoring and history are retained.")
        }
    }

    private func recordView(_ record: AIReviewRecord) -> some View {
        let post = reviewer.state.posts.first { $0.id == record.postID }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label(record)).font(.subheadline.bold()).foregroundStyle(record.comparison == .agreement ? Color.secondary : .orange)
                Spacer()
                if let date = record.checkedAt ?? post?.publishedAt {
                    Text(CountdownView.format(date, zoneID: timeZoneID, locale: locale)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let failure = record.failure { Text(failure.message(locale)).font(.caption).foregroundStyle(.red) }
            if let code = record.diagnostic?.httpStatus, code != 200 {
                Text((zh ? "服务状态：" : "Service status: ") + String(code)).font(.caption2).foregroundStyle(.secondary)
            }
            if let post {
                Text(post.text).font(.callout).textSelection(.enabled)
                Link(zh ? "查看原帖 ↗" : "Original post ↗", destination: post.url).font(.caption)
            }
            if let analysis = record.analysis {
                ForEach(Array(analysis.claims.enumerated()), id: \.offset) { _, claim in
                    Text((zh ? claim.noteZH : claim.noteEN)).font(.caption)
                    Text("“" + claim.quote + "”").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let time = claim.timeText { Text((zh ? "原文时间（未据此生成倒计时）：" : "Original timing (no AI countdown): ") + time).font(.caption2).foregroundStyle(.secondary) }
                }
                if analysis.contextMissing { Text(zh ? "缺少上下文，判断需谨慎" : "Missing context; interpretation needs review").font(.caption).foregroundStyle(.orange) }
                if analysis.claims.isEmpty { Text(zh ? "AI 未发现重置公告" : "AI found no reset announcement").font(.caption).foregroundStyle(.secondary) }
            }
            if let model = record.model { Text("OpenRouter · " + model).font(.caption2).foregroundStyle(.tertiary) }
            if record.status == .success && record.comparison != .agreement && !record.acknowledged {
                Button(zh ? "知道了（不确认账户已重置）" : "Acknowledge (does not confirm account reset)") { Task { await reviewer.acknowledge(record.id) } }.font(.caption)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func label(_ record: AIReviewRecord) -> String {
        switch record.status {
        case .pending:
            if let post = reviewer.state.posts.first(where: { $0.id == record.postID }), post.publishedAt < Date().addingTimeInterval(-86_400) {
                return zh ? "超出24小时 · 未复核" : "Older than 24 hours · Not reviewed"
            }
            return reviewer.state.enabled ? (zh ? "等待分析" : "Queued") : (zh ? "未启用 · 尚未分析" : "Off · Not analyzed")
        case .analyzing: return zh ? "分析中" : "Analyzing"
        case .failed: return zh ? "公告已抓到 · AI 分析失败" : "Post fetched · AI review failed"
        case .success:
            switch record.comparison {
            case .agreement: return zh ? "规则 / AI 结论一致" : "Rules / AI agree"
            case .possibleMiss: return zh ? "AI 复核发现 · 待核对" : "AI finding · Needs review"
            default: return zh ? "规则 / AI 有分歧 · 待核对" : "Rules / AI disagree · Needs review"
            }
        }
    }
}
