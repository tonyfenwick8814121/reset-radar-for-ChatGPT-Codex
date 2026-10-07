import Foundation
import XCTest
@testable import ResetRadar

@MainActor
final class RuleNotificationTests: XCTestCase {
    private func makeModel(directory: URL? = nil) -> (MonitorModel, URL) {
        let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("rr-rules-" + UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RuleFeedProtocol.self]
        let model = MonitorModel(store: LocalStore(directory: directory), client: FeedClient(session: URLSession(configuration: config)), scheduler: RecordingScheduler())
        RuleFeedProtocol.posts = []
        RuleFeedProtocol.summary = ""
        RuleFeedProtocol.publication = Date().addingTimeInterval(-120)
        return (model, directory)
    }

    func testNewCompletionNotifiesOnceWithoutAnUpcomingCountdown() async throws {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "Therefore ... the reset has been processed. Enjoy!")]
        RuleFeedProtocol.summary = "The Codex reset has been processed. Source: https://x.com/thsottiaux/status/10"
        var completions = 0
        var previews = 0
        model.onNewCompletedReset = { _ in completions += 1 }
        model.onNewActionableEvent = { _ in previews += 1 }
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(previews, 0)
        XCTAssertEqual(model.events.count, 1)
        XCTAssertEqual(model.activeEvent?.state, .announcedComplete)
        XCTAssertNil(model.activeEvent?.countdownAt)
        XCTAssertNotNil(model.activeEvent?.completionNotifiedAt)
        let saved = await LocalStore(directory: dir).loadEventsResult()
        XCTAssertNotNil(saved.value.first?.completionNotifiedAt)
    }

    func testCompletionReceiptSurvivesRestart() async {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "The Codex reset has been processed.")]
        await model.refresh()
        let (restarted, _) = makeModel(directory: dir)
        defer { restarted.stop() }
        RuleFeedProtocol.posts = [("10", "The Codex reset has been processed.")]
        var completions = 0
        restarted.onNewCompletedReset = { _ in completions += 1 }
        await restarted.start().value
        await restarted.refresh()
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(restarted.activeEvent?.state, .announcedComplete)
        XCTAssertNotNil(restarted.activeEvent?.completionNotifiedAt)
    }

    func testCompletionReceiptAndAliasesSurviveRuleUpgrade() async throws {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "We will reset Codex tomorrow."), ("11", "The Codex reset has been processed.")]
        await model.refresh()
        var saved = model.events
        let receipt = try XCTUnwrap(saved.first?.completionNotifiedAt)
        saved[0].classifierVersion = 4
        try await LocalStore(directory: dir).saveEvents(saved)
        let (restarted, _) = makeModel(directory: dir)
        defer { restarted.stop() }
        var completions = 0
        restarted.onNewCompletedReset = { _ in completions += 1 }
        await restarted.start().value
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(restarted.activeEvent?.announcementStage, "completed")
        XCTAssertEqual(restarted.activeEvent?.relatedPostIDs, ["status-11"])
        XCTAssertEqual(restarted.activeEvent?.completionNotifiedAt?.timeIntervalSince1970 ?? 0, receipt.timeIntervalSince1970, accuracy: 1)
    }

    func testOldOrFutureDatedCompletionDoesNotNotify() async {
        for offset in [-172_800.0, 900.0] {
            let (model, dir) = makeModel()
            defer { try? FileManager.default.removeItem(at: dir) }
            RuleFeedProtocol.publication = Date().addingTimeInterval(offset)
            RuleFeedProtocol.posts = [("10", "The Codex reset has been processed.")]
            var completions = 0
            model.onNewCompletedReset = { _ in completions += 1 }
            await model.refresh()
            XCTAssertEqual(completions, 0)
            XCTAssertNil(model.activeEvent)
        }
    }

    func testPreviewCompletionAndPropagationShareOneReceipt() async {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "We will reset Codex tomorrow.")]
        var completions = 0
        model.onNewCompletedReset = { _ in completions += 1 }
        await model.refresh()
        RuleFeedProtocol.posts.append(("11", "The Codex reset has been processed."))
        await model.refresh()
        let completedAt = model.activeEvent?.completedAt
        RuleFeedProtocol.posts.append(("12", "Codex reset all propagated. Enjoy."))
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(model.events.count, 1)
        XCTAssertEqual(model.activeEvent?.state, .announcedComplete)
        XCTAssertEqual(model.activeEvent?.completedAt, completedAt)
        XCTAssertNil(model.activeEvent?.countdownAt)
        XCTAssertEqual(Set(model.activeEvent?.relatedPostIDs ?? []), Set(["status-11", "status-12"]))
    }

    func testDismissedPreviewDoesNotReappearAsACompletion() async throws {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "We will reset Codex tomorrow.")]
        await model.refresh()
        model.markEvent(try XCTUnwrap(model.activeEvent?.id), as: .dismissed)
        var completions = 0
        model.onNewCompletedReset = { _ in completions += 1 }
        RuleFeedProtocol.posts.append(("11", "The Codex reset has been processed."))
        await model.refresh()
        XCTAssertEqual(completions, 0)
        XCTAssertNil(model.activeEvent)
        XCTAssertEqual(model.events.count, 1)
    }

    func testAcknowledgedCompletionStaysHiddenOnReplay() async throws {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "The Codex reset has been processed.")]
        var completions = 0
        model.onNewCompletedReset = { _ in completions += 1 }
        await model.refresh()
        model.markEvent(try XCTUnwrap(model.activeEvent?.id), as: .dismissed)
        await model.refresh()
        RuleFeedProtocol.posts.append(("11", "Codex reset all propagated. Enjoy."))
        await model.refresh()
        XCTAssertEqual(completions, 1)
        XCTAssertNil(model.activeEvent)
        XCTAssertEqual(model.events.count, 1)
    }

    func testIndependentSecondCompletionStillNotifies() async {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "The Codex reset has been processed.")]
        var completions = 0
        model.onNewCompletedReset = { _ in completions += 1 }
        await model.refresh()
        RuleFeedProtocol.posts.append(("11", "Another Codex reset has been processed."))
        await model.refresh()
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(model.events.count, 2)
        XCTAssertEqual(model.activeEvent?.id, "status-11")
    }

    func testCompletionReturnsToIdleAfter24Hours() async throws {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "The Codex reset has been processed.")]
        await model.refresh()
        let event = try XCTUnwrap(model.activeEvent)
        let publication = try XCTUnwrap(event.completedAt)
        var events = model.events
        XCTAssertTrue(MonitorModel.advanceLifecycle(&events, now: publication.addingTimeInterval(86_400)))
        XCTAssertNil(MonitorModel.selectActiveEvent(events, now: publication.addingTimeInterval(86_400)))
        XCTAssertEqual(events.first?.state, .archived)
        XCTAssertNotNil(events.first?.completionNotifiedAt)
    }

    func testUpgradeBackfillsMissedFreshCompletionOnce() async throws {
        let (model, dir) = makeModel()
        defer { model.stop(); try? FileManager.default.removeItem(at: dir) }
        let published = Date().addingTimeInterval(-120)
        let item = FeedItem(id: "10", title: "", body: "The reset has been processed.", url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: published)
        var legacy = try XCTUnwrap(AnnouncementClassifier().classify(item, source: FeedSource.defaults[0], fetchedAt: published))
        legacy.kind = .lead
        legacy.state = .unresolved
        legacy.confirmedAnnouncement = false
        legacy.announcementStage = "unverified"
        legacy.classifierVersion = 4
        legacy.completedAt = nil
        try await LocalStore(directory: dir).saveEvents([legacy])
        var completions = 0
        model.onNewCompletedReset = { _ in completions += 1 }
        await model.start().value
        await model.refresh()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(model.activeEvent?.state, .announcedComplete)
        XCTAssertNotNil(model.activeEvent?.completionNotifiedAt)
    }

    func testNewPreviewStillAlertsAfterCompletion() async {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "The Codex reset has been processed.")]
        await model.refresh()
        RuleFeedProtocol.posts.append(("11", "We will reset Codex again tomorrow."))
        var previews = 0
        model.onNewActionableEvent = { _ in previews += 1 }
        await model.refresh()
        XCTAssertEqual(previews, 1)
        XCTAssertEqual(model.activeEvent?.announcementStage, "preview")
        XCTAssertNil(model.completionNoticeID)
    }

    func testMixedPostNeverClosesItsOwnNewPreviewOnReplay() async {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "Codex resets all propagated. We will reset Codex again tomorrow.")]
        var alerts = 0
        model.onNewActionableEvent = { _ in alerts += 1 }
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(alerts, 1)
        XCTAssertEqual(model.activeEvent?.announcementStage, "preview")
        XCTAssertEqual(model.events.filter { $0.state == .announcedComplete }.count, 1)
    }

    func testPreviewAndGrantDistributionAreOneOpportunityWithPhaseUpdates() async {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "I promised a reset for Wednesday.")]
        var stages: [String] = []
        model.onNewActionableEvent = { stages.append($0.announcementStage ?? "") }
        await model.refresh()
        RuleFeedProtocol.posts.append(("11", "We are loading a banked reset into all Pro accounts."))
        await model.refresh()
        RuleFeedProtocol.posts.append(("12", "Your banked reset is now available in Codex."))
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(stages, ["preview", "rollingOut", "available"])
        XCTAssertEqual(model.events.count, 1)
        XCTAssertEqual(model.activeEvent?.state, .available)
        // A relay replay of an earlier phase must not downgrade an available grant.
        RuleFeedProtocol.posts = [("10", "I promised a reset for Wednesday.")]
        await model.refresh()
        XCTAssertEqual(stages.count, 3)
        XCTAssertEqual(model.activeEvent?.state, .available)
    }

    func testSummaryCannotSuppressOriginalOrCauseRepeatedAlerts() async {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "Codex limits will reset tomorrow.")]
        RuleFeedProtocol.summary = "Codex reset expected tomorrow. Source: https://x.com/thsottiaux/status/10"
        var alerts = 0
        model.onNewActionableEvent = { _ in alerts += 1 }
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(alerts, 1)
        XCTAssertTrue(model.activeEvent?.confirmedAnnouncement == true)
        XCTAssertEqual(model.activeEvent?.evidenceRank, 3)
    }

    func testFutureGrantAnnouncesNowWithoutPretendingItHasArrived() async {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7200))
        RuleFeedProtocol.posts = [("10", "We will give Codex users a banked reset at \(target).")]
        var alerts = 0
        model.onNewActionableEvent = { _ in alerts += 1 }
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(alerts, 1)
        XCTAssertEqual(model.activeEvent?.state, .unresolved)
        XCTAssertEqual(model.activeEvent?.announcementStage, "preview")
        XCTAssertNil(model.activeEvent?.expiresAt)
    }

    func testUpgradeReclassifiesOldFalseGrantSilentlyAndPreservesDismissal() async throws {
        let (model, dir) = makeModel()
        defer { model.stop(); try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let text = "No new banked reset for Codex users."
        var legacy = ResetEvent(id: "status-10", revision: 1, kind: .bankedResetGrant,
            state: .available, precision: .unknown, title: "Reset", titleEN: "Reset",
            products: ["codex"], audience: "all",
            evidence: [Evidence(sourceID: "codex-reset-json", itemID: "10", sourceKind: .communityFeed,
                url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: now, fetchedAt: now, excerpt: text, contentHash: "legacy")],
            firstSeenAt: now, updatedAt: now)
        var dismissed = legacy
        dismissed.id = "dismissed"
        dismissed.state = .dismissed
        legacy.confirmedAnnouncement = false
        try await LocalStore(directory: dir).saveEvents([legacy, dismissed])
        var alerts = 0
        model.onNewActionableEvent = { _ in alerts += 1 }
        await model.start().value
        XCTAssertEqual(alerts, 0)
        XCTAssertNil(model.activeEvent)
        XCTAssertEqual(model.events.first { $0.id == "dismissed" }?.state, .dismissed)
    }

    func testNewMetadataSurvivesPersistence() throws {
        let now = Date()
        let item = FeedItem(id: "10", title: "", body: "More resets coming next week.", url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: now)
        let event = try XCTUnwrap(AnnouncementClassifier().classify(item, source: FeedSource.defaults[0], fetchedAt: now))
        let decoded = try JSONDecoder().decode(ResetEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded, event)
        XCTAssertNotNil(decoded.reviewUntil)
    }

    func testUpgradeRestoresCountdownForSavedPreviewWithoutNewDiscovery() async throws {
        let (model, dir) = makeModel()
        defer { model.stop(); try? FileManager.default.removeItem(at: dir) }
        let published = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 120)
        let text = "Global reset landing tomorrow 10am PST for all paid ChatGPT accounts."
        let source = try XCTUnwrap(FeedSource.defaults.first { $0.id == "codex-reset-json" })
        let item = FeedItem(id: "10", title: "", body: text, url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: published)
        var legacy = try XCTUnwrap(AnnouncementClassifier().classify(item, source: source, fetchedAt: published))
        legacy.kind = .lead
        legacy.state = .unresolved
        legacy.precision = .unknown
        legacy.targetAt = nil
        legacy.timeMeaning = .unknown
        legacy.classifierVersion = 3
        var dismissed = legacy
        dismissed.id = "dismissed"
        dismissed.state = .dismissed
        try await LocalStore(directory: dir).saveEvents([legacy, dismissed])
        var alerts = 0
        model.onNewActionableEvent = { _ in alerts += 1 }
        await model.start().value
        let revised = try XCTUnwrap(model.activeEvent)
        XCTAssertEqual(revised.kind, .automaticReset)
        XCTAssertEqual(revised.state, .scheduled)
        XCTAssertNotNil(revised.countdownAt)
        XCTAssertEqual(revised.firstSeenAt, legacy.firstSeenAt)
        XCTAssertEqual(revised.classifierVersion, AnnouncementClassifier.version)
        XCTAssertEqual(alerts, 0)
        XCTAssertEqual(model.events.first { $0.id == "dismissed" }?.state, .dismissed)
    }

    func testSeparateCancellationPostClearsFutureReset() async {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7200))
        RuleFeedProtocol.posts = [("10", "Codex limits will reset at \(target).")]
        var alerts = 0
        model.onNewActionableEvent = { _ in alerts += 1 }
        await model.refresh()
        XCTAssertNotNil(model.activeEvent)
        RuleFeedProtocol.posts.append(("11", "The Codex reset is cancelled."))
        await model.refresh()
        XCTAssertEqual(alerts, 1)
        XCTAssertNil(model.activeEvent)
    }

    func testSeparateCancellationPostClearsGrantPreview() async {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        RuleFeedProtocol.posts = [("10", "Codex users will receive a banked reset tomorrow.")]
        await model.refresh()
        XCTAssertNotNil(model.activeEvent)
        RuleFeedProtocol.posts.append(("11", "The banked reset for Codex is cancelled."))
        await model.refresh()
        XCTAssertNil(model.activeEvent)
    }
}

private final class RuleFeedProtocol: URLProtocol {
    static var posts: [(String, String)] = []
    static var summary = ""
    static var publication = Date().addingTimeInterval(-120)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data: Data
        if request.url?.path == "/api/feed" {
            let tweets = Self.posts.enumerated().map { index, entry in
                ["id": entry.0, "url": "https://x.com/thsottiaux/status/\(entry.0)", "text": entry.1,
                 "at": ISO8601DateFormatter().string(from: Self.publication.addingTimeInterval(Double(index)))]
            }
            data = try! JSONSerialization.data(withJSONObject: ["stale": false, "tweets": tweets])
        } else {
            let item = request.url?.host == "codex-reset.com" && !Self.summary.isEmpty
                ? "<item><guid>summary</guid><title>Codex reset</title><description>\(Self.summary)</description></item>" : ""
            data = Data("<rss><channel>\(item)</channel></rss>".utf8)
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
