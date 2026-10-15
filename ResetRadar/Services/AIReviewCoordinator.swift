import Foundation

@MainActor
final class AIReviewCoordinator: ObservableObject {
    static let dailyRequestLimit = 20
    @Published private(set) var state = AIReviewState()
    @Published private(set) var isConfiguring = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var hasKey = false
    @Published private(set) var message: AIReviewFailure?
    @Published private(set) var authorizationSucceeded = false
    var onReviewNotice: (() -> Void)?

    private let store: LocalStore
    private let client: any AIReviewServing
    private let keys: any AIKeyStoring
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let classifier = AnnouncementClassifier()

    init(store: LocalStore, client: any AIReviewServing = OpenRouterReviewClient(), keys: any AIKeyStoring = OpenRouterKeychain()) {
        self.store = store; self.client = client; self.keys = keys
    }

    func load() async {
        let loaded = await store.loadAIReviewResult()
        state = loaded.value
        hasKey = state.keyConfigured ?? false
        if loaded.issue != nil { message = .storage }
        for index in state.records.indices where state.records[index].status == .analyzing {
            state.records[index].status = .failed
            state.records[index].failure = .network
            state.records[index].retryAt = Date().addingTimeInterval(600)
        }
        // Default-off installs never access credentials or call a model.
        if state.enabled {
            do { hasKey = try keys.read() != nil }
            catch { message = .keychain }
            if !hasKey { state.authorizationRequired = true; message = .unauthorized }
        }
    }

    @discardableResult
    func authorize(key: String, consent: Bool) async -> Bool {
        guard consent else { message = .consentRequired; return false }
        guard !isConfiguring else { return false }
        authorizationSucceeded = false
        var key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            do { key = try keys.read() ?? "" }
            catch { message = .keychain; return false }
        }
        guard !key.isEmpty, key.count <= 512, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else { message = .unauthorized; return false }
        isConfiguring = true
        defer { isConfiguring = false }
        let token = generation
        do {
            try await client.validateKey(key)
            guard token == generation else { return false }
            stop()
            try keys.save(key)
            hasKey = true; state.keyConfigured = true; state.enabled = true; state.authorizationRequired = false; message = nil
            for index in state.records.indices where state.records[index].failure == .unauthorized || state.records[index].failure == .keychain {
                state.records[index].status = .pending; state.records[index].retryAt = nil; state.records[index].attempts = 0
            }
            guard await persist() else { state.enabled = false; return false }
            authorizationSucceeded = true
            kick()
            return true
        } catch let error as AIReviewError { message = error.failure }
        catch let error as AIReviewFailure { message = error }
        catch is AIRateLimit { message = .rateLimited }
        catch { message = .network }
        return false
    }

    func disable() async {
        stop(); state.enabled = false; message = nil; authorizationSucceeded = false
        _ = await persist()
    }

    func removeKey() async {
        await disable()
        do { try keys.remove(); hasKey = false; state.keyConfigured = false; state.authorizationRequired = false; _ = await persist() }
        catch { message = .keychain }
    }

    func stop() {
        generation = UUID(); task?.cancel(); task = nil; isAnalyzing = false
        for index in state.records.indices where state.records[index].status == .analyzing {
            state.records[index].status = .failed
            state.records[index].failure = .network
            state.records[index].retryAt = Date().addingTimeInterval(600)
        }
    }

    func ingest(_ items: [FeedItem], now: Date = Date()) async {
        for post in items.compactMap(AIOriginalPost.init) {
            if let index = state.posts.firstIndex(where: { $0.id == post.id }) { state.posts[index] = post }
            else { state.posts.append(post) }
        }
        state.posts = Array(state.posts.sorted { $0.publishedAt > $1.publishedAt }.prefix(150))
        // Initial authorization reviews the latest 24 hours, not weeks of old posts.
        for post in state.posts where post.publishedAt >= now.addingTimeInterval(-86_400) && post.publishedAt <= now.addingTimeInterval(300) {
            let input = input(for: post)
            if !state.records.contains(where: { $0.fingerprint == input.fingerprint }) {
                state.records.append(AIReviewRecord(fingerprint: input.fingerprint, postID: post.id))
            } else if let index = state.records.firstIndex(where: { $0.fingerprint == input.fingerprint }),
                      let analysis = state.records[index].analysis, state.records[index].status == .success {
                // Rule upgrades may change the comparison without another model call.
                state.records[index].comparison = Self.compare(analysis, rules: ruleClaims(for: post, now: now))
            }
        }
        let known = Set(state.posts.map(\.id))
        state.records = Array(state.records.filter { known.contains($0.postID) }.suffix(300))
        _ = await persist()
    }

    func kick() {
        guard task == nil, state.enabled, !state.authorizationRequired else { return }
        isAnalyzing = true
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            await self.processQueue(token: token)
            if token == self.generation { self.task = nil; self.isAnalyzing = false }
        }
    }

    // Explicit retry clears transient per-post errors, but never bypasses server cooldown or daily budget.
    func retryFailures() async {
        guard canRetryFailures else { return }
        for index in state.records.indices where state.records[index].status == .failed && state.records[index].attempts < 2 {
            state.records[index].retryAt = nil
        }
        _ = await persist(); kick()
    }

    func acknowledge(_ id: String) async {
        if let index = state.records.firstIndex(where: { $0.id == id }) { state.records[index].acknowledged = true; _ = await persist() }
    }

    var recentRecords: [AIReviewRecord] {
        state.records.filter { record in
            guard let post = state.posts.first(where: { $0.id == record.postID }) else { return false }
            return record.fingerprint == input(for: post).fingerprint
        }.sorted { first, second in
            let a = state.posts.first { $0.id == first.postID }?.publishedAt ?? .distantPast
            let b = state.posts.first { $0.id == second.postID }?.publishedAt ?? .distantPast
            return a > b
        }
    }

    var attentionRecord: AIReviewRecord? {
        guard state.enabled else { return nil }
        return freshRecords.first { record in
            record.status == .success && [.possibleMiss, .disagreement].contains(record.comparison) && !record.acknowledged
        }
    }

    var needsAttention: Bool { attentionRecord != nil }

    func attentionTitle(_ locale: AppLocale) -> String {
        if attentionRecord?.comparison == .possibleMiss {
            return locale == .zhHans ? "AI 发现重置线索 · 待核对" : "AI reset finding · Needs review"
        }
        return locale == .zhHans ? "AI / 规则有分歧 · 待核对" : "AI / rules disagree · Needs review"
    }

    func attentionTiming(_ locale: AppLocale) -> String {
        if let time = attentionRecord?.analysis?.claims.first(where: { $0.actionable && $0.timeText != nil })?.timeText {
            return (locale == .zhHans ? "原文时间：" : "Original timing: ") + time
        }
        return locale == .zhHans ? "规则未确认 · 点击查看原文依据" : "Unconfirmed by rules · Open evidence"
    }

    var canRetryFailures: Bool {
        state.enabled && !state.authorizationRequired && !isAnalyzing &&
        (state.cooldownUntil.map { $0 <= Date() } ?? true) &&
        state.requests.filter { $0 > Date().addingTimeInterval(-86_400) }.count < Self.dailyRequestLimit &&
        freshRecords.contains { $0.status == .failed && $0.attempts < 2 }
    }

    func retryExplanation(_ locale: AppLocale) -> String? {
        let zh = locale == .zhHans
        guard state.enabled else { return nil }
        if state.authorizationRequired { return zh ? "请先重新授权 Key。" : "Authorize your key again first." }
        if let until = state.cooldownUntil, until > Date() { return zh ? "免费服务冷却中，稍后重试。" : "The free service is cooling down; retry later." }
        if state.requests.filter({ $0 > Date().addingTimeInterval(-86_400) }).count >= Self.dailyRequestLimit { return zh ? "近24小时的20次请求已用完，稍后自动继续。" : "All 20 requests for the last 24 hours were used; resumes later." }
        if freshRecords.contains(where: { $0.status == .failed }) && !freshRecords.contains(where: { $0.status == .failed && $0.attempts < 2 }) {
            return zh ? "近期失败项已各尝试2次；后续新帖仍会自动分析。" : "Recent failed posts have each used both attempts; new posts will still be reviewed."
        }
        return nil
    }

    private var freshRecords: [AIReviewRecord] {
        recentRecords.filter { record in
            state.posts.first(where: { $0.id == record.postID }).map({ $0.publishedAt >= Date().addingTimeInterval(-86_400) }) == true
        }
    }

    func summary(_ locale: AppLocale) -> String {
        let zh = locale == .zhHans
        if !state.enabled { return zh ? "未启用" : "Off" }
        if let message { return message.message(locale) }
        if state.authorizationRequired { return AIReviewFailure.unauthorized.message(locale) }
        if needsAttention { return zh ? "有分歧 · 待核对" : "Disagreement · Needs review" }
        if isAnalyzing { return zh ? "正在独立分析" : "Analyzing independently" }
        if let until = state.cooldownUntil, until > Date() { return zh ? "免费服务冷却中" : "Free service cooling down" }
        if state.requests.filter({ $0 > Date().addingTimeInterval(-86_400) }).count >= Self.dailyRequestLimit { return zh ? "近 24 小时请求上限已到，稍后继续" : "24-hour request cap reached; waiting" }
        if freshRecords.contains(where: { $0.status == .failed }) { return zh ? "部分 AI 分析失败" : "Some AI reviews failed" }
        if freshRecords.contains(where: { $0.status == .pending }) { return zh ? "等待分析" : "Queued" }
        if freshRecords.contains(where: { $0.comparison != nil && $0.comparison != .agreement }) { return zh ? "复核完成 · 分歧已读" : "Reviewed · Disagreement acknowledged" }
        return freshRecords.isEmpty ? (zh ? "等待新帖" : "Waiting for new posts") : (zh ? "复核完成 · 结论一致" : "Reviewed · Agreement")
    }

    static func compare(_ analysis: AIAnalysis, rules: [ResetEvent]) -> AIComparison {
        let ruleClaims = Set(rules.filter(\.confirmedAnnouncement).compactMap { event -> String? in
            guard let stage = event.announcementStage, ["preview", "rollingOut", "available", "completed", "cancelled"].contains(stage) else { return nil }
            let type = event.kind == .bankedResetGrant ? "banked" : "automatic"
            return type + ":" + stage
        })
        let aiClaims = Set(analysis.claims.filter { $0.explicit }.map(\.signature))
        if aiClaims == ruleClaims { return .agreement }
        if !Set(analysis.claims.filter(\.actionable).map(\.signature)).subtracting(ruleClaims).isEmpty, ruleClaims.isEmpty { return .possibleMiss }
        return .disagreement
    }

    private func input(for post: AIOriginalPost) -> AIReviewInput {
        AIReviewInput(post: post, parent: state.posts.first { $0.id == post.replyParentID && $0.publishedAt <= post.publishedAt })
    }

    private func ruleClaims(for post: AIOriginalPost, now: Date) -> [ResetEvent] {
        classifier.classifyAll(post.feedItem, source: FeedSource.defaults.first { $0.id == "codex-reset-json" }!, fetchedAt: now)
    }

    private func processQueue(token: UUID) async {
        while token == generation && !Task.isCancelled && state.enabled && !state.authorizationRequired {
            let now = Date()
            state.requests.removeAll { $0 <= now.addingTimeInterval(-86_400) }
            guard state.cooldownUntil.map({ $0 <= now }) ?? true, state.requests.count < Self.dailyRequestLimit else { return }
            guard let index = state.records.firstIndex(where: { record in
                guard record.status == .pending || (record.status == .failed && record.attempts < 2),
                      record.retryAt.map({ $0 <= now }) ?? true,
                      let post = state.posts.first(where: { $0.id == record.postID }),
                      post.publishedAt >= now.addingTimeInterval(-86_400) else { return false }
                return self.input(for: post).fingerprint == record.fingerprint
            }), let post = state.posts.first(where: { $0.id == state.records[index].postID }) else { return }
            let input = input(for: post)
            let key: String
            do { guard let stored = try keys.read() else { throw AIReviewFailure.unauthorized }; key = stored }
            catch { state.authorizationRequired = true; message = (error as? AIReviewFailure) ?? .keychain; _ = await persist(); return }
            isAnalyzing = true
            state.records[index].status = .analyzing; state.records[index].attempts += 1; state.requests.append(now)
            guard await persist() else { return }
            do {
                let (analysis, model) = try await client.analyze(input, key: key)
                guard token == generation, state.enabled, !Task.isCancelled,
                      let current = state.records.firstIndex(where: { $0.id == input.fingerprint }) else { return }
                let rules = ruleClaims(for: post, now: now)
                let comparison = Self.compare(analysis, rules: rules)
                state.records[current].status = .success; state.records[current].checkedAt = Date()
                state.records[current].analysis = analysis; state.records[current].model = model
                state.records[current].comparison = comparison; state.records[current].failure = nil
                state.records[current].diagnostic = nil
                message = nil
                let notify = comparison != .agreement && analysis.claims.contains(where: \.actionable) &&
                    !state.records[current].acknowledged && state.records[current].notifiedAt == nil &&
                    post.publishedAt >= Date().addingTimeInterval(-86_400) &&
                    state.posts.first(where: { $0.id == post.id }).map({ self.input(for: $0).fingerprint == input.fingerprint }) == true
                if notify { state.records[current].notifiedAt = Date() }
                guard await persist() else { return }
                if notify { onReviewNotice?() }
            } catch {
                guard token == generation, !Task.isCancelled,
                      let current = state.records.firstIndex(where: { $0.id == input.fingerprint }) else { return }
                let failure = (error as? AIReviewError)?.failure ?? (error as? AIReviewFailure) ?? (error is AIRateLimit ? .rateLimited : .network)
                state.records[current].status = .failed; state.records[current].checkedAt = Date(); state.records[current].failure = failure
                state.records[current].diagnostic = (error as? AIReviewError)?.diagnostic
                state.records[current].retryAt = Date().addingTimeInterval(600)
                if failure == .unauthorized { state.authorizationRequired = true; message = failure }
                if let limit = error as? AIRateLimit { state.cooldownUntil = Date().addingTimeInterval(limit.delay); state.records[current].retryAt = state.cooldownUntil }
                _ = await persist()
                // A transport/service failure stops this batch instead of hammering the provider.
                return
            }
        }
    }

    @discardableResult private func persist() async -> Bool {
        do { try await store.saveAIReview(state); return true }
        catch { message = .storage; return false }
    }
}
