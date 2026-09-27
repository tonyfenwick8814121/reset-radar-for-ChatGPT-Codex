import XCTest
@testable import ResetRadar

final class ReconciliationTests: XCTestCase {
    func testCrossSourceEvidenceDoesNotDuplicateEvent() {
        let now = Date()
        var events: [ResetEvent] = [event(source: "rss", hash: "one", target: now.addingTimeInterval(3600))]
        let incoming = event(source: "atom", hash: "two", target: now.addingTimeInterval(3600))
        let outcome = EventReconciler().merge(incoming, into: &events)
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].evidence.count, 2)
        XCTAssertEqual(events[0].revision, 1)
    }

    func testTimeCorrectionIncrementsRevision() {
        let now = Date()
        var events = [event(source: "rss", hash: "one", target: now.addingTimeInterval(3600))]
        let outcome = EventReconciler().merge(event(source: "rss", hash: "two", target: now.addingTimeInterval(7200)), into: &events)
        XCTAssertEqual(outcome, .revised)
        XCTAssertEqual(events[0].revision, 2)
    }

    func testConflictingTimesFromDifferentSourcesRequireReview() {
        let now = Date()
        var events = [event(source: "rss", hash: "one", target: now.addingTimeInterval(3600))]
        let incoming = event(source: "atom", hash: "two", target: now.addingTimeInterval(7200))
        XCTAssertEqual(EventReconciler().merge(incoming, into: &events), .revised)
        XCTAssertNil(events[0].targetAt)
        XCTAssertEqual(events[0].state, .unresolved)
    }

    func testCrossSourceConflictStaysUnresolvedWhenAThirdSourceAddsAnotherTime() {
        let now = Date()
        var events = [event(source: "rss", hash: "one", target: now.addingTimeInterval(3600))]
        _ = EventReconciler().merge(event(source: "atom", hash: "two", target: now.addingTimeInterval(7200)), into: &events)

        XCTAssertEqual(EventReconciler().merge(event(source: "third", hash: "three", target: now.addingTimeInterval(10_800)), into: &events), .unchanged)
        XCTAssertNil(events[0].targetAt)
        XCTAssertEqual(events[0].state, .unresolved)
        XCTAssertEqual(events[0].evidence.map(\.sourceID).sorted(), ["atom", "rss", "third"])
    }

    func testAudienceAndExpiryCorrectionsPersist() {
        let now = Date()
        var initial = event(source: "rss", hash: "one", target: now.addingTimeInterval(3600))
        initial.kind = .bankedResetGrant
        initial.targetAt = nil
        initial.audience = "all"
        initial.expiresAt = now.addingTimeInterval(3600)
        var incoming = initial
        incoming.audience = "partial"
        incoming.expiresAt = now.addingTimeInterval(7200)
        var events = [initial]
        XCTAssertEqual(EventReconciler().merge(incoming, into: &events), .revised)
        XCTAssertEqual(events[0].audience, "partial")
        XCTAssertEqual(events[0].expiresAt, incoming.expiresAt)
    }

    func testSameTextFromDifferentSourcesRetainsBothProvenances() {
        let now = Date()
        var events = [event(source: "rss", hash: "same", target: now.addingTimeInterval(3600))]
        let incoming = event(source: "atom", hash: "same", target: now.addingTimeInterval(3600))
        _ = EventReconciler().merge(incoming, into: &events)
        XCTAssertEqual(events[0].evidence.map(\.sourceID).sorted(), ["atom", "rss"])
    }

    @MainActor
    func testGrantWithoutExpiryCannotBecomeActiveEvent() {
        let now = Date()
        var grant = event(source: "rss", hash: "grant", target: now.addingTimeInterval(3600))
        grant.kind = .bankedResetGrant
        grant.state = .available
        grant.targetAt = nil
        grant.expiresAt = nil
        XCTAssertNil(MonitorModel.selectActiveEvent([grant], now: now))

        grant.expiresAt = now.addingTimeInterval(3600)
        XCTAssertEqual(MonitorModel.selectActiveEvent([grant], now: now)?.id, grant.id)
    }

    @MainActor
    func testFreshGrantWithoutExpiryIsVisibleBriefly() {
        let now = Date()
        var grant = event(source: "rss", hash: "grant", target: now.addingTimeInterval(3600))
        grant.kind = .bankedResetGrant
        grant.state = .available
        grant.targetAt = nil
        grant.expiresAt = nil
        grant.firstSeenAt = now
        grant.evidence = [Evidence(sourceID: "rss", itemID: "fresh", sourceKind: .communityFeed, url: nil, publishedAt: now.addingTimeInterval(-60), fetchedAt: now, excerpt: "", contentHash: "fresh")]
        XCTAssertEqual(MonitorModel.selectActiveEvent([grant], now: now)?.id, grant.id)
    }

    @MainActor
    func testExpiredGrantNeverRemainsActiveBecauseItWasPublishedRecently() {
        let now = Date()
        var grant = event(source: "rss", hash: "grant", target: now)
        grant.kind = .bankedResetGrant
        grant.timeMeaning = .grantExpiry
        grant.targetAt = nil
        grant.expiresAt = now.addingTimeInterval(-1)
        grant.state = .expired
        grant.evidence[0] = Evidence(sourceID: "rss", itemID: "fresh", sourceKind: .communityFeed, url: nil, publishedAt: now, fetchedAt: now, excerpt: "", contentHash: "fresh")
        XCTAssertNil(MonitorModel.selectActiveEvent([grant], now: now))
    }

    @MainActor
    func testLifecycleMovesAutomaticResetAndGrantToTerminalStates() {
        let now = Date()
        var automatic = event(source: "rss", hash: "auto", target: now.addingTimeInterval(-1))
        automatic.timeMeaning = .automaticReset
        var grant = event(source: "rss", hash: "grant", target: now)
        grant.kind = .bankedResetGrant
        grant.timeMeaning = .grantExpiry
        grant.targetAt = nil
        grant.expiresAt = now.addingTimeInterval(-1)
        grant.state = .available
        var events = [automatic, grant]

        XCTAssertTrue(MonitorModel.advanceLifecycle(&events, now: now))
        XCTAssertEqual(events[0].state, .dueUnconfirmed)
        XCTAssertEqual(events[1].state, .expired)
        XCTAssertEqual(MonitorModel.selectActiveEvent(events, now: now)?.id, automatic.id)

        XCTAssertTrue(MonitorModel.advanceLifecycle(&events, now: now.addingTimeInterval(86_401)))
        XCTAssertEqual(events[0].state, .archived)
        XCTAssertNil(MonitorModel.selectActiveEvent(events, now: now.addingTimeInterval(86_401)))
    }

    @MainActor
    func testRecentlyDueEventRemainsVisibleAtZero() {
        let now = Date()
        var due = event(source: "rss", hash: "due", target: now.addingTimeInterval(-60))
        due.state = .dueUnconfirmed
        XCTAssertEqual(MonitorModel.selectActiveEvent([due], now: now)?.id, due.id)
        due.targetAt = now.addingTimeInterval(-90_000)
        XCTAssertNil(MonitorModel.selectActiveEvent([due], now: now))
    }

    @MainActor
    func testUndatedOpportunityArchives24HoursAfterDiscoveryWithoutReplayResurrection() {
        let now = Date()
        var grant = event(source: "rss", hash: "grant", target: now)
        grant.kind = .bankedResetGrant
        grant.state = .available
        grant.targetAt = nil
        grant.firstSeenAt = now
        grant.evidence = [Evidence(sourceID: "rss", itemID: "fresh", sourceKind: .communityFeed, url: nil, publishedAt: now.addingTimeInterval(-3600), fetchedAt: now, excerpt: "", contentHash: "grant")]
        var events = [grant]
        XCTAssertNotNil(MonitorModel.selectActiveEvent(events, now: now.addingTimeInterval(86_399)))
        XCTAssertTrue(MonitorModel.advanceLifecycle(&events, now: now.addingTimeInterval(86_400)))
        XCTAssertEqual(events[0].state, .archived)
        _ = EventReconciler().merge(grant, into: &events)
        XCTAssertEqual(events[0].state, .archived)
        XCTAssertNil(MonitorModel.selectActiveEvent(events, now: now.addingTimeInterval(86_401)))
    }

    private func event(source: String, hash: String, target: Date) -> ResetEvent {
        let now = Date(timeIntervalSince1970: 1_000)
        return ResetEvent(id: "same", revision: 1, kind: .automaticReset, confirmedAnnouncement: true, state: .scheduled, precision: .exact, title: "Reset", titleEN: "Reset", targetAt: target, windowStart: nil, windowEnd: nil, expiresAt: nil, products: ["codex"], audience: "all", evidence: [Evidence(sourceID: source, itemID: source, sourceKind: .communityFeed, url: nil, publishedAt: now, fetchedAt: now, excerpt: "", contentHash: hash)], firstSeenAt: now, updatedAt: now)
    }
}
