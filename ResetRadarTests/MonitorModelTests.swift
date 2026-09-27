import XCTest
import Foundation
@testable import ResetRadar

@MainActor
final class MonitorModelTests: XCTestCase {
    func testRoutineChecksAndNonOpportunitiesNeverTriggerDiscovery() async {
        for mode in [MonitorURLProtocol.Mode.empty, .serverError, .complete, .cancelled, .expiredGrant] {
            MonitorURLProtocol.mode = mode
            let model = makeModel()
            var discoveries = 0
            model.onNewActionableEvent = { _ in discoveries += 1 }
            await model.refresh()
            await model.refresh()
            XCTAssertEqual(discoveries, 0, "Unexpected discovery for \(mode)")
        }
    }

    func testSameOpportunityDoesNotAlertOnRepeatedChecks() async {
        for mode in [MonitorURLProtocol.Mode.grant, .automatic, .lead, .futureGrant] {
            MonitorURLProtocol.mode = mode
            let model = makeModel()
            var discoveries = 0
            model.onNewActionableEvent = { _ in discoveries += 1 }
            await model.refresh()
            await model.refresh()
            XCTAssertEqual(discoveries, 1)
        }
    }

    func testOpportunityCancelledInSameBatchNeverTriggersDiscovery() async {
        MonitorURLProtocol.mode = .mixed
        let model = makeModel()
        var discoveries = 0
        model.onNewActionableEvent = { _ in discoveries += 1 }
        await model.refresh()
        XCTAssertEqual(discoveries, 0)
        XCTAssertNil(model.activeEvent)
    }

    func testCorrectedFutureTimeAlertsOnceThenStaysSilent() async {
        MonitorURLProtocol.mode = .automatic
        let model = makeModel()
        var discoveries = 0
        model.onNewActionableEvent = { _ in discoveries += 1 }
        await model.refresh()
        MonitorURLProtocol.mode = .revised
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(discoveries, 2)
    }

    func testPersistedOpportunityDoesNotRepeatDiscoveryOnRestart() async throws {
        MonitorURLProtocol.mode = .automatic
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(directory: directory)
        let original = MonitorModel(store: store, client: makeClient(), scheduler: RecordingScheduler())
        await original.refresh()
        let restarted = MonitorModel(store: store, client: makeClient(), scheduler: RecordingScheduler())
        var discoveries = 0
        restarted.onNewActionableEvent = { _ in discoveries += 1 }
        await restarted.start().value
        await restarted.refresh()
        restarted.stop()
        XCTAssertNotNil(restarted.activeEvent)
        XCTAssertEqual(discoveries, 0)
    }

    func testHandledOpportunityStaysSilentAfterRefresh() async throws {
        for state in [EventState.used, .dismissed, .announcedComplete] {
            MonitorURLProtocol.mode = state == .announcedComplete ? .automatic : .grant
            let model = makeModel()
            await model.refresh()
            let id = try XCTUnwrap(model.activeEvent?.id)
            model.markEvent(id, as: state)
            var discoveries = 0
            model.onNewActionableEvent = { _ in discoveries += 1 }
            await model.refresh()
            XCTAssertEqual(discoveries, 0)
            XCTAssertEqual(model.events.first { $0.id == id }?.state, state)
            XCTAssertNil(model.activeEvent)
        }
    }

    func testExpiredManualEntryNeverTriggersDiscovery() {
        let model = makeModel()
        var discoveries = 0
        model.onNewActionableEvent = { _ in discoveries += 1 }
        model.addManualEvent(ManualEntryDraft(text: "expired", kind: .bankedResetGrant, date: Date().addingTimeInterval(-60), product: "codex", audience: "unknown"))
        XCTAssertEqual(discoveries, 0)
    }

    func testFreshUndatedGrantTriggersDiscovery() async {
        MonitorURLProtocol.mode = .grant
        let scheduler = RecordingScheduler()
        let model = makeModel(scheduler: scheduler)
        var discoveries = 0
        model.onNewActionableEvent = { _ in discoveries += 1 }

        await model.refresh()

        XCTAssertEqual(discoveries, 1)
        XCTAssertEqual(model.activeEvent?.kind, .bankedResetGrant)
    }

    func testRetryAfterAndManualRefreshRespectCooldown() async throws {
        MonitorURLProtocol.mode = .rateLimit
        MonitorURLProtocol.requestCount = 0
        let model = makeModel()
        let began = Date()

        await model.refresh()
        let firstCount = MonitorURLProtocol.requestCount
        let retry = try XCTUnwrap(model.statuses.first { $0.sourceID == "modelyard" }?.nextCheckAt)
        XCTAssertGreaterThanOrEqual(retry.timeIntervalSince(began), 3_500)

        await model.refresh(force: true)
        XCTAssertEqual(MonitorURLProtocol.requestCount, firstCount)
    }

    func testOrdinaryFailuresUseOneMinuteFirstRetry() async throws {
        MonitorURLProtocol.mode = .serverError
        let model = makeModel()
        let began = Date()
        await model.refresh()
        let retry = try XCTUnwrap(model.statuses.first?.nextCheckAt?.timeIntervalSince(began))
        XCTAssertGreaterThanOrEqual(retry, 55)
        XCTAssertLessThan(retry, 90)
    }

    func testStartReconcilesRemindersForPersistedFutureEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStore(directory: directory)
        let now = Date()
        let event = ResetEvent(id: "persisted", revision: 2, kind: .automaticReset, timeMeaning: .automaticReset, state: .scheduled, precision: .exact, title: "Reset", titleEN: "Reset", targetAt: now.addingTimeInterval(3600), windowStart: nil, windowEnd: nil, expiresAt: nil, products: ["codex"], audience: "all", evidence: [], firstSeenAt: now, updatedAt: now)
        try await store.saveEvents([event])
        try await store.saveStatuses(FeedSource.defaults.map { source in
            SourceStatus(sourceID: source.id, enabled: true, lastAttemptAt: now, lastTransportSuccessAt: now, latestCoveredPublicationAt: nil, nextCheckAt: now.addingTimeInterval(3600), result: .success, message: nil, consecutiveFailures: 0, etag: nil, lastModified: nil)
        })
        let scheduler = RecordingScheduler()
        let model = MonitorModel(store: store, client: makeClient(), scheduler: scheduler)

        await model.start().value

        let snapshots = await scheduler.snapshots
        XCTAssertTrue(snapshots.contains { $0.contains("persisted") })
        model.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func testManualGrantCanBeMarkedUsedAndReturnsToIdle() {
        let model = makeModel()
        model.addManualEvent(ManualEntryDraft(text: "https://example.com/reset", kind: .bankedResetGrant, date: Date().addingTimeInterval(3600), product: "codex", audience: "partial"))
        let id = model.activeEvent?.id
        XCTAssertEqual(model.activeEvent?.timeMeaning, .grantExpiry)
        XCTAssertNotNil(model.activeEvent?.expiresAt)

        model.markEvent(id!, as: .used)

        XCTAssertNil(model.activeEvent)
        XCTAssertEqual(model.events.first { $0.id == id }?.state, .used)
    }

    func testRealAnnouncementPathAlertsOnceAndCompletionClearsIt() async throws {
        MonitorURLProtocol.mode = .confirmed
        let model = makeModel()
        var discoveries = 0
        model.onNewActionableEvent = { _ in discoveries += 1 }
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(discoveries, 1)
        XCTAssertEqual(model.activeEvent?.kind, .lead)
        XCTAssertNil(model.activeEvent?.targetAt)
        MonitorURLProtocol.mode = .confirmedComplete
        await model.refresh()
        XCTAssertEqual(discoveries, 1)
        XCTAssertNil(model.activeEvent)
        await model.refresh()
        XCTAssertNil(model.activeEvent)
        XCTAssertEqual(discoveries, 1)
    }

    func testAnnouncementAlreadyCompletedInNewestFirstFeedNeverAlerts() async {
        MonitorURLProtocol.mode = .confirmedComplete
        let model = makeModel()
        var discoveries = 0
        model.onNewActionableEvent = { _ in discoveries += 1 }
        await model.refresh()
        XCTAssertEqual(discoveries, 0)
        XCTAssertNil(model.activeEvent)
    }

    func testTuesdayPromiseAndBankedRolloutProduceOneDiscovery() async {
        MonitorURLProtocol.mode = .solRollout
        let model = makeModel()
        var discoveries: [ResetEvent] = []
        model.onNewActionableEvent = { discoveries.append($0) }
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(discoveries.count, 1)
        XCTAssertEqual(discoveries.first?.kind, .bankedResetGrant)
        XCTAssertEqual(discoveries.first?.state, .unresolved)
        XCTAssertEqual(model.activeEvent?.audience, "paid-plans")
        XCTAssertEqual(model.events.filter { $0.confirmedAnnouncement }.count, 1)
        XCTAssertFalse(model.events.contains { $0.kind == .lead })
    }

    func testTuesdayPromiseAloneAlertsOnce() async {
        MonitorURLProtocol.mode = .tuesdayPromise
        let model = makeModel()
        var discoveries = 0
        model.onNewActionableEvent = { _ in discoveries += 1 }
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(discoveries, 1)
        XCTAssertEqual(model.activeEvent?.kind, .lead)
    }

    func testIntervalAndPinDefaultsMigrateAndCooldownSurvivesChanges() async throws {
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs.checkIntervalMinutes, 10)
        XCTAssertFalse(prefs.alwaysOnTop)
        MonitorURLProtocol.mode = .rateLimit
        let model = makeModel()
        await model.refresh()
        let cooldowns = model.statuses.map(\.nextCheckAt)
        for minutes in [1, 5, 10, 15, 20] {
            model.setCheckInterval(minutes)
            XCTAssertEqual(model.checkInterval(for: FeedSource.defaults[0]), Double(minutes * 60))
            XCTAssertEqual(model.statuses.map(\.nextCheckAt), cooldowns)
        }
        model.setCheckInterval(2)
        XCTAssertEqual(model.preferences.checkIntervalMinutes, 20)
    }

    private func makeModel(scheduler: RecordingScheduler = RecordingScheduler()) -> MonitorModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return MonitorModel(store: LocalStore(directory: directory), client: makeClient(), scheduler: scheduler)
    }

    private func makeClient() -> FeedClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MonitorURLProtocol.self]
        return FeedClient(session: URLSession(configuration: configuration))
    }
}

actor RecordingScheduler: ReminderScheduling {
    private(set) var snapshots: [[String]] = []
    func reconcile(events: [ResetEvent], preferences: UserPreferences, now: Date) async {
        snapshots.append(events.map(\.id))
    }
    func cancelAll() async {}
}

private final class MonitorURLProtocol: URLProtocol {
    enum Mode { case confirmed, confirmedComplete, solRollout, tuesdayPromise, empty, grant, rateLimit, serverError, complete, lead, cancelled, automatic, revised, mixed, expiredGrant, futureGrant }
    static var mode: Mode = .empty
    static var requestCount = 0
    static let futureTarget = Date().addingTimeInterval(7200)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        let status = Self.mode == .rateLimit ? 429 : (Self.mode == .serverError ? 500 : 200)
        let headers = ["Retry-After": "3600", "Content-Type": "application/rss+xml"]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let published = formatter.string(from: Date())
        let future = ISO8601DateFormatter().string(from: Self.futureTarget)
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let automatic = "Codex limits will reset at \(future)"
        let cancelled = "Codex reset at \(future) cancelled; will not happen"
        let bodies: [String]
        switch Self.mode {
        case .grant: bodies = ["Some users receive a banked reset"]
        case .complete: bodies = ["Codex limits already reset"]
        case .lead: bodies = ["Codex limits will reset tomorrow"]
        case .cancelled: bodies = [cancelled]
        case .automatic: bodies = [automatic]
        case .revised: bodies = ["Codex limits will reset at \(ISO8601DateFormatter().string(from: Self.futureTarget.addingTimeInterval(3600)))"]
        case .mixed: bodies = [automatic, cancelled]
        case .expiredGrant: bodies = ["Codex banked reset expires \(past)"]
        case .futureGrant: bodies = ["Codex banked reset will arrive \(future)"]
        default: bodies = []
        }
        let item = bodies.map { body in
            "<item><guid>fresh-grant</guid><title>Codex reset news</title><description>\(body)</description><pubDate>\(published)</pubDate></item>"
        }.joined()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.path == "/api/feed" {
            var tweets: [[String: String]] = []
            if Self.mode == .confirmed || Self.mode == .confirmedComplete {
                if Self.mode == .confirmedComplete {
                    tweets.append(["id": "200", "url": "https://x.com/thsottiaux/status/200", "text": "Reset all propagated. Sweet dreams.", "at": ISO8601DateFormatter().string(from: Date())])
                }
                tweets.append(["id": "100", "url": "https://x.com/thsottiaux/status/100", "text": "Hi Astra users. A reset is also landing by midnight today.", "at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))])
            }
            if Self.mode == .solRollout || Self.mode == .tuesdayPromise {
                tweets.append(["id": "300", "url": "https://x.com/thsottiaux/status/300", "text": "We are almost Tuesday and I promised a reset for Tuesday. See you soon.", "at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))])
                if Self.mode == .solRollout {
                    tweets.append(["id": "301", "url": "https://x.com/thsottiaux/status/301", "text": "GPT-6 Sol and Luna are out. We are loading a banked reset into all accounts of our Plus, Pro and Business users.", "at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))])
                }
            }
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["stale": false, "tweets": tweets]))
        } else {
            client?.urlProtocol(self, didLoad: Data("<rss><channel>\(item)</channel></rss>".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
