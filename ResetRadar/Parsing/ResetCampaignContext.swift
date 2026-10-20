import Foundation

/// An author's time-bounded public pledge supplies topic context, never proof that a reset happened.
struct ResetCampaignContext: Sendable {
    let postID: String
    let announcement: AIOriginalPost
    let parent: AIOriginalPost?
    let day: Int

    init?(post: AIOriginalPost, originals: [AIOriginalPost]) {
        let parent = originals.first {
            $0.id == post.replyParentID && $0.publishedAt <= post.publishedAt && post.publishedAt.timeIntervalSince($0.publishedAt) <= 86_400
        }
        let marker = Self.dayNumber(post.text) != nil ? post : parent
        guard let marker, let day = Self.dayNumber(marker.text), day > 0, Self.isDayResetTopic(marker.text),
              marker.id == post.id || Self.isReviewCandidate(marker.text),
              marker.id == post.id || Self.matches(#"(?i)^\s*landing\s+(?:within|sometime|today|tomorrow|by|in)\b"#, post.text),
              let anchor = originals.filter({ anchor in
                  guard let days = Self.duration(anchor) else { return false }
                  return day <= days && anchor.publishedAt <= post.publishedAt &&
                      post.publishedAt.timeIntervalSince(anchor.publishedAt) < Double(days) * 86_400
              }).max(by: { $0.publishedAt < $1.publishedAt }) else { return nil }
        postID = post.id; announcement = anchor; self.parent = marker.id == post.id ? nil : marker; self.day = day
    }

    static func duration(_ post: AIOriginalPost) -> Int? {
        let text = post.text.lowercased().replacingOccurrences(of: "’", with: "'")
        guard matches(#"^\s*over the next\s+\d{1,2}\s+days\b"#, text),
              matches(#"\beach day\b.{0,60}\bship\b"#, text), text.contains("codex"), text.contains("work"),
              matches(#"\bor ship a full reset\b"#, text),
              let range = text.range(of: #"\d{1,2}(?=\s+days\b)"#, options: .regularExpression),
              let days = Int(text[range]), (1...60).contains(days) else { return nil }
        return days
    }

    static func isReviewCandidate(_ text: String) -> Bool {
        isDayResetTopic(text) && !isExcluded(text)
    }

    private static func isDayResetTopic(_ text: String) -> Bool {
        dayNumber(text) != nil && matches(#"(?i)\breset\b"#, text) &&
        !matches(#"(?i)\bfactory reset\b|\breset (?:your |the )?(?:password|settings|context)\b"#, text)
    }

    static func isDelivery(_ text: String) -> Bool {
        isReviewCandidate(text) && matches(#"(?i)\band\s+(?:(?:a|the)\s+)?(?:(?:full|global|quota|limit)\s+)?reset\s*[.!]\s*enjoy\b"#, text)
    }

    private static func dayNumber(_ text: String) -> Int? {
        guard let range = text.range(of: #"(?im)^\s*day\s+\d{1,2}\s*/"#, options: .regularExpression),
              let number = String(text[range]).range(of: #"\d{1,2}"#, options: .regularExpression) else { return nil }
        return Int(String(text[range])[number])
    }

    private static func isExcluded(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "’", with: "'")
        return matches(#"(?i)\b(?:not|no|never|without|maybe|might|could|would|if|hope|hopefully|wish|please|asking|asks|asked|want|wants|joke|cancelled|canceled|tomorrow|next|soon|later|will|won't|planned|planning|yesterday|last|previous|historical|quoted|quoting|password|factory|context|settings|banked|manual|example|tutorial)\b|[?？]"#, normalized)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
