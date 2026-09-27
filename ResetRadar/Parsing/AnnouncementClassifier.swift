import CryptoKit
import Foundation

struct AnnouncementClassifier {
    private let resolver = TimeResolver()

    func classify(_ item: FeedItem, source: FeedSource, fetchedAt: Date) -> ResetEvent? {
        let combined = "\(item.title) \(item.body)"
        let lower = combined.lowercased()
        let resetWords = lower.contains("reset") || lower.contains("额度重置")
        let originalURL = originalPostURL(in: combined)
        let postURL = originalURL ?? item.url
        let trustedAuthor = ["x.com", "twitter.com"].contains(postURL?.host?.lowercased() ?? "") &&
            postURL?.path.lowercased().hasPrefix("/thsottiaux/status/") == true && source.kind == .communityFeed
        let explicitReset = lower.range(of: #"(?:reset (?:is |is also )?(?:landing|lands)|(?:limits|quotas) will reset|(?:we(?:'re| are| will)|i(?:'m| am| will)) (?:resetting|reset)|resets? all propagated)"#, options: .regularExpression) != nil
        let promisedReset = trustedAuthor && lower.range(of: #"i promised a reset for (?:tuesday|today|tomorrow)"#, options: .regularExpression) != nil
        let grantRollout = trustedAuthor && lower.range(of: #"we (?:are|will be) loading a banked reset into all accounts of our plus, pro and business users"#, options: .regularExpression) != nil
        let productWords = (trustedAuthor && explicitReset && (lower.contains("astra users") || lower.contains("reset all propagated") || lower.contains("resets all propagated"))) ||
            promisedReset || grantRollout || lower.contains("chatgpt") || lower.contains("codex") ||
            lower.contains("usage limit") || lower.contains("weekly limit")
        guard resetWords && productWords else { return nil }
        let unrelatedResets = ["password reset", "reset password", "reset your password", "reset the password", "reset settings", "reset context", "factory reset"]
        guard !unrelatedResets.contains(where: lower.contains) else { return nil }

        let grantMarkers = ["banked reset", "reset grant", "reset credit", "reset opportunity", "manual reset", "one-time reset", "重置机会", "手动重置"]
        let isGrant = grantMarkers.contains { lower.contains($0) }
        let expiryMarkers = ["expires", "expiry", "valid until", "use by", "deadline", "失效", "到期"]
        let isGrantExpiry = isGrant && expiryMarkers.contains { lower.contains($0) }
        let forwardMarkers = ["lands ", "landing ", "tomorrow", "later today", "end of day", "planned", "upcoming", "next hour"]
        let isForwardLooking = forwardMarkers.contains { lower.contains($0) } ||
            lower.range(of: #"\b(?:will|we'll) (?:be )?reset\b"#, options: .regularExpression) != nil
        let completeMarkers = ["it is done", "already reset", "returned to 100%", "back to 100%", "reset propagated", "reset all propagated", "resets all propagated", "limits reset for", "usage reset for"]
        let cancelMarkers = ["cancelled", "canceled", "will not happen", "called off", "no longer planned", "预告取消", "不会重置"]
        let uncertaintyMarkers = ["probability", "chance of", "forecast", "prediction", "rumor", "rumour", "maybe", "might", "could reset", "if we", "would reset", "wish", "hoping", "please reset", "likely", "unlikely", "joke", "no reset is planned", "可能性", "预测", "传闻"]
        let isCancelled = cancelMarkers.contains { lower.contains($0) }
        let isUncertain = uncertaintyMarkers.contains { lower.contains($0) }
        let isComplete = !isCancelled && !isUncertain && completeMarkers.contains { lower.contains($0) }
        let resolution = resolver.resolve(combined, publishedAt: item.publishedAt, verifiedContextZone: inferredContextZone(lower))
        var target: Date?
        var windowStart: Date?
        var expiresAt: Date?
        let state: EventState
        let precision: TimePrecision
        let timeMeaning: TimeMeaning
        if isCancelled {
            target = nil
            state = .cancelled
            precision = .unknown
            timeMeaning = isGrant ? (isGrantExpiry ? .grantExpiry : .grantAvailability) : .automaticReset
        } else if isUncertain {
            target = nil
            state = .unresolved
            precision = .unknown
            timeMeaning = .unknown
        } else if isComplete {
            target = nil
            state = .announcedComplete
            precision = .unknown
            timeMeaning = .automaticReset
        } else if isGrant {
            target = nil
            timeMeaning = isGrantExpiry ? .grantExpiry : .grantAvailability
            if case .exact(let date) = resolution {
                if isGrantExpiry { expiresAt = date }
                else { windowStart = date }
                precision = .exact
            } else {
                precision = .unknown
            }
            state = expiresAt.map { $0 <= fetchedAt } == true ? .expired : (grantRollout ? .unresolved : .available)
        } else {
            timeMeaning = .automaticReset
            switch resolution {
            case .exact(let date):
                target = date
                state = date > fetchedAt ? .scheduled : .dueUnconfirmed
                precision = .exact
            case .unresolved:
                target = nil
                state = isForwardLooking ? .unresolved : .unresolved
                precision = .unknown
            }
        }
        let kind: ResetKind = isGrant ? .bankedResetGrant : ((isForwardLooking || promisedReset) && target == nil && !isComplete && !isCancelled && !isUncertain ? .lead : .automaticReset)
        let hash = SHA256.hash(data: Data(combined.utf8)).map { String(format: "%02x", $0) }.joined()
        let canonical = canonicalID(item, originalURL: originalURL)
        let evidence = Evidence(
            sourceID: source.id,
            itemID: item.id,
            sourceKind: source.kind,
            url: originalURL ?? item.url,
            publishedAt: item.freshnessDate,
            fetchedAt: fetchedAt,
            excerpt: String(combined.prefix(1600)),
            contentHash: hash
        )
        return ResetEvent(
            id: canonical,
            revision: 1,
            kind: kind,
            timeMeaning: timeMeaning,
            confirmedAnnouncement: trustedAuthor && (explicitReset || promisedReset || grantRollout) && !isUncertain && !isCancelled,
            state: state,
            precision: precision,
            title: isGrant ? "发现重置机会" : "额度重置预告",
            titleEN: isGrant ? "Reset opportunity" : "Quota reset announced",
            targetAt: target,
            windowStart: windowStart,
            windowEnd: nil,
            expiresAt: expiresAt,
            products: lower.contains("chatgpt work") ? ["chatgpt-work"] : (lower.contains("codex") ? ["codex"] : (promisedReset || grantRollout ? ["unspecified"] : (trustedAuthor && explicitReset ? ["astra"] : ["chatgpt"]))),
            audience: grantRollout ? "paid-plans" : ((isGrant && lower.contains("affected") && (lower.contains("not fully applying") || lower.contains("failed") || lower.contains("affected time window"))) ? "affected-reset-users" : lower.contains("all users") ? "all" : ((isGrant && lower.contains("some ")) || lower.contains("some users") || lower.contains("500k") ? "partial" : "unknown")),
            evidence: [evidence],
            firstSeenAt: fetchedAt,
            updatedAt: fetchedAt
        )
    }

    private func inferredContextZone(_ text: String) -> String? {
        text.contains(" pt") || text.contains("pst") || text.contains("pdt") ? "America/Los_Angeles" : nil
    }

    private func canonicalID(_ item: FeedItem, originalURL: URL?) -> String {
        if let url = originalURL ?? item.url {
            let path = url.path.lowercased()
            if let match = path.range(of: #"status/\d+"#, options: .regularExpression) {
                return String(path[match]).replacingOccurrences(of: "/", with: "-")
            }
        }
        return SHA256.hash(data: Data(item.id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func originalPostURL(in text: String) -> URL? {
        let pattern = #"https://(?:x\.com|twitter\.com)/[^\s/]+/status/\d+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}
