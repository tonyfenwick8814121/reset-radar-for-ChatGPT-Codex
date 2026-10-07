import CryptoKit
import Foundation

/// Local, deterministic claims: each sentence has its own action, polarity and time.
/// A missing date never prevents a credible explicit announcement from being surfaced.
struct AnnouncementClassifier {
    static let version = 6
    private let resolver = TimeResolver()

    func classify(_ item: FeedItem, source: FeedSource, fetchedAt: Date) -> ResetEvent? {
        classifyAll(item, source: source, fetchedAt: fetchedAt).first
    }

    func classifyAll(_ item: FeedItem, source: FeedSource, fetchedAt: Date) -> [ResetEvent] {
        let combined = "\(item.title) \(item.body)"
        let lower = normalize(combined)
        guard matches(#"\breset(?:s|ting)?\b|额度重置|重置机会|手动重置"#, lower) else { return [] }
        let originalURL = originalPostURL(in: combined)
        let postURL = item.url.flatMap { isPost($0) ? $0 : nil } ?? originalURL ?? item.url
        let trustedAuthor = postURL.map { isPost($0) && $0.path.lowercased().hasPrefix("/thsottiaux/status/") } == true
        let official = source.kind == .officialFeed && ["openai.com", "status.openai.com"].contains(source.url.host?.lowercased() ?? "")
        let relay = ["modelyard", "codex-reset"].contains(source.id) && !(postURL.map(isPost) == true && !trustedAuthor)
        let trusted = trustedAuthor || official || relay
        let rank = official || (trustedAuthor && source.id == "codex-reset-json") ? 3 : (trustedAuthor ? 2 : (relay ? 1 : 0))
        let products = productNames(lower)
        guard !products.isEmpty || trustedAuthor else { return [] }
        let globalGrant = isGrant(lower)
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = normalize(body.isEmpty ? item.title : body)
        let sentences = text.replacingOccurrences(of: #"(?<=[.!?;。！？])\s+|\n+|\s+but\s+|\s+and\s+(?=(?:we|i|another|more|a new|the next)\b)"#, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        var claims: [Claim] = []
        for sentence in sentences {
            let grant = isGrant(sentence) || (globalGrant && matches(#"another one|getting|receiv|grant|expires?|valid until|use by|lands?\b|loading|added|it is done"#, sentence))
            let relevant = matches(#"\breset(?:s|ting)?\b|额度重置|重置机会|手动重置"#, sentence) || grant
            guard relevant else { continue }
            if matches(#"password|factory reset|reset (?:your |the )?(?:password|settings|context)|重置密码"#, sentence) { continue }
            let cancelled = matches(#"cancelled|canceled|called off|no longer planned|no (?:new |more )?(?:banked )?resets?\b|no reset is planned|will not (?:happen|reset|receive|get)|won't (?:reset|receive|get)|不会重置|预告取消"#, sentence)
            let eligibilityCondition = matches(#"\bif (?:your|you|the reset)\b.{0,65}\b(?:failed|affected|didn't|did not)\b"#, sentence)
            let uncertain = (!eligibilityCondition && matches(#"\b(?:maybe|might|could|would|rumou?rs?|probability|prediction|forecast|wish|hope|hoping|hopefully|please|likely|unlikely|joke|if)\b|可能性|传闻|预测"#, sentence))
            let question = sentence.contains("?") || sentence.contains("？") || matches(#"^\s*(?:how to|how do|what is|what are|can (?:i|we|you)|will (?:i|we|you)|does|do you)\b"#, sentence)
            let explanatory = matches(#"\b(?:how to|tutorial|guide to|for example|example of|lets you|allows you|means you|you can use)\b"#, sentence)
            let negated = matches(#"\b(?:not|never|won't|don't|doesn't|isn't|aren't|without)\b.{0,40}\b(?:reset|grant|receive|give|add|load)|\breset\b.{0,20}\b(?:not happening|not coming)\b"#, sentence)
            if cancelled {
                claims.append(Claim(text: sentence, grant: grant, stage: "cancelled", confirmed: trusted))
                continue
            }
            guard !uncertain && !question && !negated && !explanatory else { continue }
            let future = matches(#"\b(?:tomorrow|tonight|today|soon|later|next|upcoming|planned|planning|promise[ds]?|will|we'll|going to)\b|\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b|即将|明天|下周"#, sentence)
            let processed = matches(#"\bresets? (?:has|have) been (?:processed|completed|applied)\b|\bwe (?:have )?(?:processed|completed|applied) (?:the |a |this )?(?:codex |chatgpt )?reset\b"#, sentence)
            let completed = processed || matches(#"\b(?:resets? (?:all )?propagated|already reset|have been reset|has been reset|limits (?:are |were )?reset for|usage (?:was )?reset for|returned to 100%|back to 100%|fully propagated)\b"#, sentence)
            let promise = matches(#"\b(?:i|we) (?:have |had )?promised?\b.{0,60}\breset\b|\b(?:we|i) (?:will|are|am|'re|'m) (?:be )?(?:reset|resetting)\b|\bwe'll reset\b|\b(?:limits|quotas) (?:will |are going to )?reset\b|\bresets? (?:is |are |is also |are also |will be )?(?:landing|lands?|coming|planned|scheduled|rolling out)\b|\b(?:another|more|a) resets? (?:is |are )?(?:coming|next)\b|\b(?:reset|resetting)\b.{0,45}\b(?:tomorrow|tonight|next week)\b|将.{0,12}重置|即将重置"#, sentence)
            let grantAction = grant && matches(#"\b(?:get|gets|getting|receive|receives|receiving|give|giving|granting|awarding|loading|load|adding|added|add|restor\w*|reissu\w*|credited|crediting|available|arrive|arriving|lands?|landing|issued|distributed|expires?|valid until|use by|deadline)\b|getting another one|补发|发放|可用|失效|到期"#, sentence)
            let delivered = grant && matches(#"\b(?:has been added|have been added|added to|has been issued|have been issued|now available|is available|are available|already available|distributed|credited|restored|it is done|can now use|can now claim)\b|发放完成|已到账|已发放"#, sentence)
            let rolling = grant && matches(#"\b(?:loading|adding|rolling out|distributing)\b|发放中"#, sentence)
            if grant && (grantAction || delivered || (completed && !future)) {
                let notYet = matches(#"\b(?:tomorrow|tonight|next|later|will|going to)\b"#, sentence)
                let stage = (delivered && !notYet) || (completed && !future) ? "available" : (rolling ? "rollingOut" : (future ? "preview" : "available"))
                claims.append(Claim(text: sentence, grant: true, stage: stage, confirmed: trusted))
            } else if !grant && completed && (!future || processed || matches(#"fully propagated|resets? all propagated|already reset|have been reset"#, sentence)) {
                claims.append(Claim(text: sentence, grant: false, stage: "completed", confirmed: trusted))
            } else if !grant && promise {
                claims.append(Claim(text: sentence, grant: false, stage: "preview", confirmed: trusted))
            }
        }

        // Cancellation applies to the same type; a different new action is kept separately.
        let cancellations = claims.filter { $0.stage == "cancelled" }
        claims.removeAll { claim in
            claim.stage != "cancelled" && cancellations.contains { cancellation in
                guard cancellation.grant == claim.grant else { return false }
                let first = timeHint(cancellation.text), second = timeHint(claim.text)
                return first == nil || second == nil || first == second
            }
        }
        if claims.isEmpty {
            // Preserve an inspectable candidate, with no actionable state or countdown.
            claims = [Claim(text: text, grant: globalGrant, stage: "unverified", confirmed: false)]
        }
        var grouped: [Claim] = []
        for claim in claims {
            // Consolidate clauses about one grant, retaining both availability and expiry dates.
            if let index = grouped.firstIndex(where: { $0.grant == claim.grant && ($0.stage == claim.stage || (claim.grant && $0.stage != "cancelled" && claim.stage != "cancelled")) }) {
                grouped[index].text += " " + claim.text
                if claim.grant && claim.stage == "available" && !matches(#"^(?:it |the banked reset |your banked reset )?(?:expires?|valid until|use by)\b"#, claim.text) {
                    grouped[index].stage = "available"
                }
            } else { grouped.append(claim) }
        }
        // Upcoming action is primary; a completion in another sentence cannot swallow it.
        grouped.sort { priority($0.stage) > priority($1.stage) }
        let hash = SHA256.hash(data: Data(combined.utf8)).map { String(format: "%02x", $0) }.joined()
        let evidence = Evidence(sourceID: source.id, itemID: item.id, sourceKind: source.kind,
                                url: postURL, publishedAt: item.freshnessDate, fetchedAt: fetchedAt,
                                excerpt: String(combined.prefix(1600)), contentHash: hash)
        let canonical = canonicalID(item, originalURL: postURL)
        return grouped.enumerated().map { index, claim in
            let expiryText = suffix(from: #"\b(?:expires?|expiry|valid until|use by|deadline)\b|失效|到期"#, in: claim.text)
            let actionText = suffix(from: #"\breset(?:s|ting)?\b|重置"#, in: claim.text) ?? claim.text
            let startText = claim.grant ? prefix(before: #"\b(?:expires?|expiry|valid until|use by|deadline)\b|失效|到期"#, in: actionText) : actionText
            let arrival = resolved(startText, publishedAt: item.publishedAt)
            let expiry = claim.grant ? expiryText.flatMap { resolved($0, publishedAt: item.publishedAt) } : nil
            let canDate = claim.confirmed && !["cancelled", "unverified", "completed"].contains(claim.stage)
            let target = !claim.grant && canDate ? arrival : nil
            let start = claim.grant && canDate ? arrival : nil
            let end = canDate ? expiry : nil
            let state: EventState
            switch claim.stage {
            case "cancelled": state = .cancelled
            case "completed": state = .announcedComplete
            case "unverified": state = .unresolved
            default:
                if claim.grant {
                    state = end.map { $0 <= fetchedAt } == true ? .expired : (claim.stage == "available" ? .available : .unresolved)
                } else if let target { state = target > fetchedAt ? .scheduled : .dueUnconfirmed }
                else { state = .unresolved }
            }
            let kind: ResetKind = claim.grant ? .bankedResetGrant : (target == nil && !["completed", "cancelled"].contains(claim.stage) ? .lead : .automaticReset)
            var event = ResetEvent(id: index == 0 ? canonical : "\(canonical)-\(claim.grant ? "grant" : "auto")-\(claim.stage)", revision: 1,
                kind: kind, timeMeaning: claim.grant ? (end == nil ? .grantAvailability : .grantExpiry) : (kind == .lead ? .unknown : .automaticReset),
                confirmedAnnouncement: claim.confirmed && claim.stage != "unverified", state: state,
                precision: target != nil || start != nil || end != nil ? .exact : .unknown,
                title: claim.grant ? "发现重置机会" : (claim.stage == "completed" ? "重置已完成" : "额度重置预告"), titleEN: claim.grant ? "Reset opportunity" : (claim.stage == "completed" ? "Reset completed" : "Quota reset announced"),
                targetAt: target, windowStart: start, windowEnd: nil, expiresAt: end,
                products: products.isEmpty ? ["unspecified"] : products, audience: audience(claim.stage == "completed" ? claim.text : lower), evidence: [evidence], firstSeenAt: fetchedAt, updatedAt: fetchedAt)
            event.classifierVersion = Self.version
            event.evidenceRank = rank
            event.announcementStage = claim.stage
            event.matchedText = claim.text
            if claim.confirmed && claim.stage == "completed" { event.completedAt = item.publishedAt }
            // Retain distant, imprecise previews for updates without asserting an exact reset time.
            if claim.confirmed && ["preview", "rollingOut"].contains(claim.stage) {
                let days: Double = matches(#"\bnext week\b|下周"#, claim.text) ? 14 : (matches(#"\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#, claim.text) ? 8 : 2)
                event.reviewUntil = max(start ?? .distantPast, (item.freshnessDate ?? fetchedAt).addingTimeInterval(days * 86_400))
            }
            return event
        }
    }

    private struct Claim { var text: String; var grant: Bool; var stage: String; var confirmed: Bool }
    private func timeHint(_ text: String) -> String? {
        guard let range = text.range(of: #"\b(?:today|tomorrow|tonight|next week|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
    private func priority(_ stage: String) -> Int { ["preview": 5, "rollingOut": 4, "available": 3, "cancelled": 2, "completed": 1][stage] ?? 0 }
    private func normalize(_ text: String) -> String { text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'") }
    private func matches(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private func isGrant(_ text: String) -> Bool { matches(#"\b(?:banked resets?|reset grants?|reset credits?|reset opportunit(?:y|ies)|manual resets?)\b|手动重置|重置机会"#, text) }
    private func isPost(_ url: URL) -> Bool { ["x.com", "twitter.com"].contains(url.host?.lowercased() ?? "") && matches(#"/[^/]+/status/\d+"#, url.path) }
    private func productNames(_ text: String) -> [String] {
        var names: [String] = []
        if text.contains("codex") { names.append("codex") }
        if text.contains("chatgpt work") { names.append("chatgpt-work") }
        else if text.contains("chatgpt") { names.append("chatgpt") }
        if text.contains("astra") { names.append("astra") }
        if names.isEmpty && matches(#"usage limit|weekly limit"#, text) { names.append("unspecified") }
        return names
    }
    private func audience(_ text: String) -> String {
        if text.contains("affected") && matches(#"failed|not fully apply|not fully applying|affected time window"#, text) { return "affected-reset-users" }
        if matches(#"plus.{0,15}pro.{0,15}business|paid (?:users|accounts|codex)"#, text) { return "paid-plans" }
        if matches(#"all (?:users|accounts)|everyone|every user"#, text) { return "all" }
        if matches(#"\bsome\b|500k"#, text) { return "partial" }
        return "unknown"
    }
    private func resolved(_ text: String, publishedAt: Date?) -> Date? {
        if case .exact(let date) = resolver.resolve(text, publishedAt: publishedAt) { return date }
        return nil
    }
    private func suffix(from pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range.lowerBound...])
    }
    private func prefix(before pattern: String, in text: String) -> String {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return text }
        return String(text[..<range.lowerBound])
    }
    private func canonicalID(_ item: FeedItem, originalURL: URL?) -> String {
        if let url = originalURL ?? item.url, let match = url.path.range(of: #"status/\d+"#, options: .regularExpression) {
            return String(url.path[match]).replacingOccurrences(of: "/", with: "-")
        }
        return SHA256.hash(data: Data(item.id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    private func originalPostURL(in text: String) -> URL? {
        guard let range = text.range(of: #"https://(?:x\.com|twitter\.com)/[^\s/]+/status/\d+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}
