import Foundation

enum ReconcileOutcome: Equatable {
    case inserted
    case revised
    case unchanged
}

struct EventReconciler {
    func merge(_ incoming: ResetEvent, into events: inout [ResetEvent]) -> ReconcileOutcome {
        guard let index = events.firstIndex(where: { $0.id == incoming.id }) else {
            events.append(incoming)
            return .inserted
        }
        var stored = events[index]
        if let aliases = incoming.relatedPostIDs {
            stored.relatedPostIDs = Array(Set((stored.relatedPostIDs ?? []) + aliases)).sorted()
        }
        let contentChanged = incoming.evidence.contains { evidence in
            stored.evidence.contains { Self.evidenceIdentity($0) == Self.evidenceIdentity(evidence) && $0.contentHash != evidence.contentHash }
        }
        for evidence in incoming.evidence {
            if let position = stored.evidence.firstIndex(where: { Self.evidenceIdentity($0) == Self.evidenceIdentity(evidence) }) {
                stored.evidence[position] = evidence
            } else { stored.evidence.append(evidence) }
        }
        let lowerRank = (incoming.evidenceRank ?? 0) < (stored.evidenceRank ?? 0)
        let unsupportedDowngrade = stored.confirmedAnnouncement && !incoming.confirmedAnnouncement &&
            !(contentChanged && incoming.evidenceRank == 3)
        if lowerRank || unsupportedDowngrade {
            events[index] = stored
            return .unchanged
        }
        // A feed replay must not resurrect an opportunity the user already handled.
        let explicitCorrection = contentChanged && incoming.evidenceRank == 3 && incoming.confirmedAnnouncement
        let stages = ["unverified": 0, "preview": 1, "rollingOut": 2, "available": 3]
        if let oldStage = stored.announcementStage, let newStage = incoming.announcementStage,
           let oldOrder = stages[oldStage], let newOrder = stages[newStage],
           oldOrder > newOrder && !explicitCorrection {
            events[index] = stored
            return .unchanged
        }
        if [.used, .dismissed].contains(stored.state) ||
            ([.announcedComplete, .cancelled, .archived].contains(stored.state) && !explicitCorrection) {
            events[index] = stored
            return .unchanged
        }
        let existingSources = Set(events[index].evidence.map(\.sourceID))
        let incomingSources = Set(incoming.evidence.map(\.sourceID))
        let unresolvedCrossSourceConflict = stored.state == .unresolved &&
            stored.precision == .unknown && stored.targetAt == nil &&
            existingSources.count > 1 && existingSources.isDisjoint(with: incomingSources)
        if unresolvedCrossSourceConflict && (incoming.evidenceRank ?? 0) <= (stored.evidenceRank ?? 0) {
            stored.updatedAt = max(stored.updatedAt, incoming.updatedAt)
            events[index] = stored
            return .unchanged
        }
        let crossSourceTimeConflict = stored.targetAt != nil && incoming.targetAt != nil &&
            stored.targetAt != incoming.targetAt && existingSources.isDisjoint(with: incomingSources)
        if crossSourceTimeConflict && (incoming.evidenceRank ?? 0) == (stored.evidenceRank ?? 0) {
            stored.revision += 1
            stored.targetAt = nil
            stored.state = .unresolved
            stored.precision = .unknown
            stored.updatedAt = max(stored.updatedAt, incoming.updatedAt)
            events[index] = stored
            return .revised
        }

        let audienceChanged = incoming.audience != "unknown" && stored.audience != incoming.audience
        let expiryChanged = incoming.expiresAt != nil && stored.expiresAt != incoming.expiresAt
        let windowChanged = (incoming.windowStart != nil && stored.windowStart != incoming.windowStart) ||
            (incoming.windowEnd != nil && stored.windowEnd != incoming.windowEnd)
        let productChanged = !Set(incoming.products.filter { $0 != "unspecified" }).isSubset(of: Set(stored.products))
        let meaningChanged = productChanged || stored.evidenceRank != incoming.evidenceRank || stored.announcementStage != incoming.announcementStage || stored.kind != incoming.kind || stored.timeMeaning != incoming.timeMeaning ||
            stored.state != incoming.state || stored.confirmedAnnouncement != incoming.confirmedAnnouncement || stored.targetAt != incoming.targetAt ||
            stored.precision != incoming.precision || audienceChanged || expiryChanged || windowChanged
        if meaningChanged {
            stored.revision += 1
            stored.classifierVersion = incoming.classifierVersion
            stored.evidenceRank = incoming.evidenceRank
            stored.announcementStage = incoming.announcementStage
            stored.matchedText = incoming.matchedText
            stored.reviewUntil = incoming.reviewUntil
            stored.completedAt = stored.completedAt ?? incoming.completedAt
            stored.confirmedAnnouncement = incoming.confirmedAnnouncement
            stored.kind = incoming.kind
            stored.timeMeaning = incoming.timeMeaning
            stored.state = incoming.state
            stored.precision = incoming.precision
            stored.targetAt = incoming.targetAt
            stored.windowStart = incoming.windowStart
            stored.windowEnd = incoming.windowEnd
            stored.expiresAt = incoming.expiresAt
            if incoming.audience != "unknown" { stored.audience = incoming.audience }
            stored.products = Array(Set(stored.products + incoming.products)).filter { $0 != "unspecified" }.sorted()
            if stored.products.isEmpty { stored.products = ["unspecified"] }
            if incoming.announcementStage == "available", events[index].announcementStage != "available" {
                stored.firstSeenAt = incoming.firstSeenAt
            }
            stored.updatedAt = incoming.updatedAt
            stored.title = incoming.title
            stored.titleEN = incoming.titleEN
            events[index] = stored
            return .revised
        }
        events[index] = stored
        return .unchanged
    }

    private static func evidenceIdentity(_ evidence: Evidence) -> String {
        "\(evidence.sourceID)|\(evidence.itemID)|\(evidence.url?.absoluteString ?? "")"
    }
}
