import Foundation
import XCTest
@testable import ResetRadar

@MainActor
final class RuleNotificationTests: XCTestCase {
    private func makeModel() -> (MonitorModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rr-rules-" + UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RuleFeedProtocol.self]
        let model = MonitorModel(store: LocalStore(directory: directory), client: FeedClient(session: URLSession(configuration: config)), scheduler: RecordingScheduler())
        RuleFeedProtocol.posts = []
        RuleFeedProtocol.summary = ""
        return (model, directory)
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
    static let publication = Date().addingTimeInterval(-120)
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
