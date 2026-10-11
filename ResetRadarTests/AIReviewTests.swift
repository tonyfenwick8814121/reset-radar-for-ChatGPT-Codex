import Foundation
import XCTest
@testable import ResetRadar

@MainActor
final class AIReviewTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at: directory) } }

    private func setup(client: ReviewStub = ReviewStub(), key: String? = nil, saved: AIReviewState? = nil) async throws -> (AIReviewCoordinator, ReviewStub, MemoryAIKeys, LocalStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rr-ai-" + UUID().uuidString)
        directories.append(dir)
        let store = LocalStore(directory: dir)
        if let saved { try await store.saveAIReview(saved) }
        let keys = MemoryAIKeys(key)
        let reviewer = AIReviewCoordinator(store: store, client: client, keys: keys)
        await reviewer.load()
        return (reviewer, client, keys, store)
    }

    private func post(_ id: String = "10", _ text: String = "Global reset by EOD.", parent: String? = nil, date: Date = Date().addingTimeInterval(-60)) -> FeedItem {
        FeedItem(id: id, title: "", body: text, url: URL(string: "https://x.com/thsottiaux/status/" + id), publishedAt: date, replyParentID: parent)
    }
    private func finish(_ reviewer: AIReviewCoordinator) async {
        for _ in 0..<2000 { if !reviewer.isAnalyzing { return }; try? await Task.sleep(for: .milliseconds(1)) }
        XCTFail("Review queue did not finish")
    }
    private func claim(_ type: AIResetType = .automatic, phase: AIResetPhase = .preview, quote: String = "Global reset by EOD.") -> AIClaim {
        AIClaim(type: type, phase: phase, explicit: true, quote: quote, noteZH: "全球重置预告，时间不明确", noteEN: "Global reset preview; imprecise timing", timeText: nil)
    }

    func testOffAndConsentGateSendNoRequestsOrCredentialReads() async throws {
        let (reviewer, client, keys, _) = try await setup()
        await reviewer.ingest([post()]); reviewer.kick(); await finish(reviewer)
        let enabled = await reviewer.authorize(key: "test-key", consent: false)
        XCTAssertFalse(enabled); XCTAssertFalse(reviewer.state.enabled)
        let counts = await client.counts()
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(keys.reads, 0)
        XCTAssertNil(keys.key)
    }

    func testAuthorizedKeyStoredOnlyInSecretStore() async throws {
        let (reviewer, _, keys, store) = try await setup()
        let enabled = await authorize(reviewer); XCTAssertTrue(enabled)
        await finish(reviewer)
        XCTAssertEqual(keys.key, "test-key"); XCTAssertTrue(reviewer.state.enabled)
        let saved = await store.loadAIReviewResult()
        let json = String(data: try JSONEncoder().encode(saved.value), encoding: .utf8)!
        XCTAssertFalse(json.contains("test-key")); XCTAssertFalse(json.contains("Bearer"))
    }

    private func authorize(_ reviewer: AIReviewCoordinator) async -> Bool { await reviewer.authorize(key: "test-key", consent: true) }

    func testInvalidCredentialDoesNotEnableOrSave() async throws {
        let client = ReviewStub(); await client.setFailure(.unauthorized)
        let (reviewer, _, keys, _) = try await setup(client: client)
        let success = await authorize(reviewer)
        XCTAssertFalse(success); XCTAssertNil(keys.key); XCTAssertFalse(reviewer.state.enabled)
        XCTAssertEqual(reviewer.message, .unauthorized)
    }

    func testAgreementCachedAcrossRefreshAndRestartWithoutNotice() async throws {
        let client = ReviewStub(); await client.setAnalysis(AIAnalysis(claims: [claim()], contextMissing: false))
        let (reviewer, _, keys, store) = try await setup(client: client)
        var notices = 0; reviewer.onReviewNotice = { notices += 1 }
        let item = post()
        await reviewer.ingest([item]); _ = await authorize(reviewer); await finish(reviewer)
        await reviewer.ingest([item]); reviewer.kick(); await finish(reviewer)
        let restarted = AIReviewCoordinator(store: store, client: client, keys: keys)
        await restarted.load(); await restarted.ingest([item]); restarted.kick(); await finish(restarted)
        let counts = await client.counts()
        XCTAssertEqual(counts.1, 1); XCTAssertEqual(notices, 0)
        XCTAssertEqual(restarted.recentRecords.first?.comparison, .agreement)
    }

    func testNoKeywordFilterAIOnlyPreviewNotifiesOnceAndIsNeverVerifiedEvent() async throws {
        let client = ReviewStub()
        await client.setAnalysis(AIAnalysis(claims: [claim(quote: "Everyone gets a fresh tank tomorrow.")], contextMissing: false))
        let (reviewer, _, _, _) = try await setup(client: client)
        let item = post("11", "Everyone gets a fresh tank tomorrow.")
        var notices = 0; reviewer.onReviewNotice = { notices += 1 }
        await reviewer.ingest([item]); _ = await authorize(reviewer); await finish(reviewer)
        reviewer.kick(); await finish(reviewer)
        XCTAssertEqual(notices, 1); XCTAssertEqual(reviewer.recentRecords.first?.comparison, .possibleMiss)
        XCTAssertTrue(reviewer.needsAttention)
        await reviewer.acknowledge(try XCTUnwrap(reviewer.recentRecords.first?.id))
        XCTAssertFalse(reviewer.needsAttention)
    }

    func testAIDisagreementDoesNotDeleteRuleOpportunity() async throws {
        let analysis = AIAnalysis(claims: [], contextMissing: false)
        let rules = AnnouncementClassifier().classifyAll(post(), source: FeedSource.defaults.first { $0.id == "codex-reset-json" }!, fetchedAt: Date())
        XCTAssertTrue(rules.contains { $0.confirmedAnnouncement })
        XCTAssertEqual(AIReviewCoordinator.compare(analysis, rules: rules), .disagreement)
        XCTAssertTrue(rules.contains { $0.confirmedAnnouncement && $0.announcementStage == "preview" })
    }

    func testPropagatedFollowupAndBankedCompensationAgreeWithRules() {
        let source = FeedSource.defaults.first { $0.id == "codex-reset-json" }!
        let cases: [(String, AIClaim)] = [
            ("Resets all propagated. That will be all. Have a fantastic weekend.", claim(phase: .completed, quote: "Resets all propagated.")),
            ("We will restore a banked reset to users whose reset failed during the bug.", claim(.banked, phase: .preview, quote: "restore a banked reset"))]
        for (text, value) in cases {
            let rules = AnnouncementClassifier().classifyAll(post("20", text), source: source, fetchedAt: Date())
            XCTAssertEqual(AIReviewCoordinator.compare(AIAnalysis(claims: [value], contextMissing: false), rules: rules), .agreement, text)
        }
    }

    func testReplyParentAndEditsInvalidateCacheWhileUnchangedContentDoesNot() async throws {
        let client = ReviewStub()
        let (reviewer, _, _, _) = try await setup(client: client)
        let now = Date()
        let reply = post("12", "All propagated.", parent: "11", date: now.addingTimeInterval(-60))
        await reviewer.ingest([reply]); _ = await authorize(reviewer); await finish(reviewer)
        var inputs = await client.inputs
        XCTAssertNil(inputs.first?.parent)
        await reviewer.ingest([post("11", "Global reset by EOD.", date: now.addingTimeInterval(-120)), reply])
        reviewer.kick(); await finish(reviewer)
        inputs = await client.inputs
        XCTAssertTrue(inputs.contains { $0.post.id == "12" && $0.parent?.id == "11" })
        let count = inputs.count
        await reviewer.ingest([post("11", "Global reset tomorrow.", date: now.addingTimeInterval(-120))]); reviewer.kick(); await finish(reviewer)
        let newCount = await inputCount(client); XCTAssertGreaterThan(newCount, count)
    }
    private func inputCount(_ client: ReviewStub) async -> Int { await client.inputs.count }

    func testOldOrUntrustedPostsNeverSent() async throws {
        let (reviewer, client, _, _) = try await setup()
        let fake = FeedItem(id: "22", title: "", body: "Global reset tomorrow.", url: URL(string: "https://x.com/fake/status/22"), publishedAt: Date())
        await reviewer.ingest([post("21", date: Date().addingTimeInterval(-90_000)), fake])
        _ = await authorize(reviewer); await finish(reviewer)
        let count = await inputCount(client); XCTAssertEqual(count, 0)
    }

    func testRateLimitStopsBatchAndManualRetryCannotBypassCooldown() async throws {
        let client = ReviewStub(); await client.setAnalysisFailure(AIRateLimit(delay: 3600))
        let (reviewer, _, _, _) = try await setup(client: client)
        await reviewer.ingest([post(), post("11")]); _ = await authorize(reviewer); await finish(reviewer)
        await reviewer.retryFailures(); await finish(reviewer)
        let count = await inputCount(client); XCTAssertEqual(count, 1)
        XCTAssertEqual(reviewer.recentRecords.first(where: { $0.status == .failed })?.failure, .rateLimited)
        XCTAssertGreaterThan(try XCTUnwrap(reviewer.state.cooldownUntil).timeIntervalSinceNow, 3500)
    }

    func testUnauthorizedReviewStopsFurtherModelRequests() async throws {
        let client = ReviewStub(); await client.setAnalysisFailure(AIReviewFailure.unauthorized)
        let (reviewer, _, _, _) = try await setup(client: client)
        await reviewer.ingest([post(), post("11")]); _ = await authorize(reviewer); await finish(reviewer)
        reviewer.kick(); await finish(reviewer); await reviewer.retryFailures(); await finish(reviewer)
        XCTAssertTrue(reviewer.state.authorizationRequired)
        let count = await inputCount(client); XCTAssertEqual(count, 1)
    }

    func testDailyBudgetIsPersistedAndSurvivesRetry() async throws {
        var state = AIReviewState(); state.requests = Array(repeating: Date(), count: AIReviewCoordinator.dailyRequestLimit)
        let (reviewer, client, _, store) = try await setup(saved: state)
        await reviewer.ingest([post()]); _ = await authorize(reviewer); await finish(reviewer)
        let count = await inputCount(client); XCTAssertEqual(count, 0)
        let saved = await store.loadAIReviewResult()
        XCTAssertEqual(saved.value.requests.count, 20)
    }

    func testFailuresAreBoundedToTwoAttemptsAndNotReportedAsNoOpportunity() async throws {
        let client = ReviewStub(); await client.setAnalysisFailure(AIReviewFailure.network)
        let (reviewer, _, _, _) = try await setup(client: client)
        await reviewer.ingest([post()]); _ = await authorize(reviewer); await finish(reviewer)
        await reviewer.retryFailures(); await finish(reviewer)
        await reviewer.retryFailures(); await finish(reviewer)
        let count = await inputCount(client); XCTAssertEqual(count, 2)
        XCTAssertEqual(reviewer.recentRecords.first?.status, .failed)
        XCTAssertTrue(reviewer.summary(.zhHans).contains("失败"))
    }

    func testDisablingIgnoresLateResponseAndRemovingKeyStopsRequests() async throws {
        let client = ReviewStub(); await client.pause()
        let (reviewer, _, keys, _) = try await setup(client: client)
        await reviewer.ingest([post()]); _ = await authorize(reviewer)
        for _ in 0..<100 { if await inputCount(client) > 0 { break }; await Task.yield() }
        await reviewer.disable()
        await client.resume(); await Task.yield()
        XCTAssertFalse(reviewer.state.enabled); XCTAssertFalse(reviewer.recentRecords.contains { $0.status == .success })
        await reviewer.removeKey(); reviewer.kick(); await finish(reviewer)
        XCTAssertNil(keys.key); let count = await inputCount(client); XCTAssertEqual(count, 1)
    }

    func testRequestIsIndependentFreeOnlyStructuredAndNoKeyInBody() throws {
        let input = AIReviewInput(post: try XCTUnwrap(AIOriginalPost(post())), parent: nil)
        let body = try OpenRouterReviewClient.requestBody(input)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "openrouter/free")
        XCTAssertNil(json["models"]); XCTAssertNil(json["tools"]); XCTAssertNil(json["plugins"])
        XCTAssertEqual((json["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains("test-key"))
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertFalse(messages[1]["content"]!.contains("rule"))
    }

    func testDecodeRejectsInventedQuoteTimeAndTruncatedOutput() throws {
        let input = AIReviewInput(post: try XCTUnwrap(AIOriginalPost(post())), parent: nil)
        func envelope(_ analysis: AIAnalysis, finish: String = "stop") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["model": "test/free:free", "choices": [["finish_reason": finish, "message": ["content": String(data: try JSONEncoder().encode(analysis), encoding: .utf8)!]]]])
        }
        var value = claim()
        XCTAssertNoThrow(try OpenRouterReviewClient.decode(envelope(AIAnalysis(claims: [value], contextMissing: false)), input: input))
        value.quote = "Everyone gets another reset."
        XCTAssertThrowsError(try OpenRouterReviewClient.decode(envelope(AIAnalysis(claims: [value], contextMissing: false)), input: input))
        value = claim(); value.timeText = "10:00 PST"
        XCTAssertThrowsError(try OpenRouterReviewClient.decode(envelope(AIAnalysis(claims: [value], contextMissing: false)), input: input))
        XCTAssertThrowsError(try OpenRouterReviewClient.decode(envelope(AIAnalysis(claims: [claim()], contextMissing: false), finish: "length"), input: input))
    }

    func testCachedAnalysisIsComparedAgainAfterRuleChangesWithoutCloudCall() async throws {
        let item = post()
        let original = try XCTUnwrap(AIOriginalPost(item))
        let input = AIReviewInput(post: original, parent: nil)
        var state = AIReviewState(); state.posts = [original]
        var record = AIReviewRecord(fingerprint: input.fingerprint, postID: original.id)
        record.status = .success; record.analysis = AIAnalysis(claims: [claim()], contextMissing: false)
        record.comparison = .possibleMiss; state.records = [record]
        let (reviewer, client, _, _) = try await setup(saved: state)
        await reviewer.ingest([item]); _ = await authorize(reviewer); await finish(reviewer)
        XCTAssertEqual(reviewer.recentRecords.first?.comparison, .agreement)
        let count = await inputCount(client); XCTAssertEqual(count, 0)
    }

    func testPrimaryReminderDoesNotWaitForAIOrLoseEventOnAIDisagreement() async throws {
        let client = ReviewStub(); await client.pause()
        let (reviewer, _, _, store) = try await setup(client: client)
        _ = await authorize(reviewer); await finish(reviewer)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIPublicFeedStub.self]
        let model = MonitorModel(store: store, client: FeedClient(session: URLSession(configuration: configuration)), scheduler: QuietAIScheduler(), aiReview: reviewer)
        var notices = 0; model.onNewActionableEvent = { _ in notices += 1 }
        await model.refresh()
        XCTAssertEqual(notices, 1); XCTAssertTrue(model.activeEvent?.confirmedAnnouncement == true)
        for _ in 0..<100 { if await inputCount(client) > 0 { break }; await Task.yield() }
        XCTAssertTrue(reviewer.isAnalyzing)
        await client.resume(); await finish(reviewer)
        XCTAssertEqual(reviewer.recentRecords.first?.comparison, .disagreement)
        XCTAssertEqual(notices, 1); XCTAssertTrue(model.activeEvent?.confirmedAnnouncement == true)
        model.stop()
    }

    func testReauthorizationCannotBypassServerCooldown() async throws {
        var state = AIReviewState(); state.cooldownUntil = Date().addingTimeInterval(3600)
        let (reviewer, client, _, _) = try await setup(saved: state)
        await reviewer.ingest([post()]); _ = await authorize(reviewer); await finish(reviewer)
        let count = await inputCount(client); XCTAssertEqual(count, 0)
        XCTAssertGreaterThan(try XCTUnwrap(reviewer.state.cooldownUntil).timeIntervalSinceNow, 3500)
    }

    func testDisabledSavedKeyIsNotReadUntilExplicitReauthorization() async throws {
        var state = AIReviewState(); state.keyConfigured = true
        let (reviewer, _, keys, _) = try await setup(key: "test-key", saved: state)
        XCTAssertTrue(reviewer.hasKey); XCTAssertEqual(keys.reads, 0)
        let enabled = await reviewer.authorize(key: "", consent: true); await finish(reviewer)
        XCTAssertTrue(enabled); XCTAssertGreaterThan(keys.reads, 0)
    }

    func testUpgradeBootstrapsOriginalsDespiteUnchangedFeedETag() async throws {
        let (reviewer, client, _, store) = try await setup()
        let future = Date().addingTimeInterval(600)
        try await store.saveStatuses([SourceStatus(sourceID: "codex-reset-json", enabled: true, lastAttemptAt: Date(), lastTransportSuccessAt: Date(), latestCoveredPublicationAt: Date(), nextCheckAt: future, result: .success, message: nil, consecutiveFailures: 0, etag: "cached-before-ai", lastModified: nil)])
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIPublicFeedStub.self]
        let model = MonitorModel(store: store, client: FeedClient(session: URLSession(configuration: config)), scheduler: QuietAIScheduler(), aiReview: reviewer)
        AIPublicFeedStub.publicRequest = nil
        await model.start().value
        XCTAssertNil(AIPublicFeedStub.publicRequest?.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertFalse(reviewer.state.posts.isEmpty)
        let count = await inputCount(client); XCTAssertEqual(count, 0)
        model.stop()
    }

    func testPublicFeedPreservesReplyParent() throws {
        let data = Data(#"{"stale":false,"tweets":[{"id":"10","url":"https://x.com/thsottiaux/status/10","text":"All propagated.","at":"2026-10-11T04:01:09Z","in_reply_to_tweet_id":"9"}]}"#.utf8)
        XCTAssertEqual(try FeedClient.parsePublicFeed(data).first?.replyParentID, "9")
    }
}

private final class MemoryAIKeys: AIKeyStoring, @unchecked Sendable {
    var key: String?
    var reads = 0
    init(_ key: String?) { self.key = key }
    func read() throws -> String? { reads += 1; return key }
    func save(_ key: String) throws { self.key = key }
    func remove() throws { key = nil }
}

private actor ReviewStub: AIReviewServing {
    var inputs: [AIReviewInput] = []
    private var validations = 0
    private var failure: AIReviewFailure?
    private var analysisFailure: Error?
    private var analysis = AIAnalysis(claims: [], contextMissing: false)
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    func setFailure(_ value: AIReviewFailure) { failure = value }
    func setAnalysisFailure(_ value: Error) { analysisFailure = value }
    func setAnalysis(_ value: AIAnalysis) { analysis = value }
    func counts() -> (Int, Int) { (validations, inputs.count) }
    func pause() { paused = true }
    func resume() { paused = false; continuation?.resume(); continuation = nil }
    func validateKey(_ key: String) async throws { validations += 1; if let failure { throw failure } }
    func analyze(_ input: AIReviewInput, key: String) async throws -> (AIAnalysis, String) {
        inputs.append(input)
        if paused { await withCheckedContinuation { continuation = $0 } }
        if let analysisFailure { throw analysisFailure }
        return (analysis, "test/model:free")
    }
}

final class OpenRouterReviewClientTests: XCTestCase {
    private func client() -> OpenRouterReviewClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIHTTPStub.self]
        AIHTTPStub.status = 200; AIHTTPStub.headers = [:]; AIHTTPStub.data = Data(); AIHTTPStub.request = nil
        return OpenRouterReviewClient(session: URLSession(configuration: config))
    }

    func testKeyValidationUsesAuthenticatedGETWithoutCompletionCall() async throws {
        let client = client(); AIHTTPStub.data = Data(#"{"data":{"label":"Test key"}}"#.utf8)
        try await client.validateKey("test-key")
        XCTAssertEqual(AIHTTPStub.request?.httpMethod, "GET")
        XCTAssertEqual(AIHTTPStub.request?.url?.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertNil(AIHTTPStub.request?.httpBody)
        XCTAssertEqual(AIHTTPStub.request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testAuthenticationErrorNeverIncludesServerBodyOrSecret() async throws {
        let client = client(); AIHTTPStub.status = 401
        AIHTTPStub.data = Data(#"{"error":{"message":"Key test-key is invalid"}}"#.utf8)
        do { try await client.validateKey("test-key"); XCTFail("Should fail") }
        catch { XCTAssertEqual(error as? AIReviewFailure, .unauthorized); XCTAssertFalse(String(describing: error).contains("test-key")) }
    }

    func testRateLimitRespectsRetryAfter() async throws {
        let client = client(); AIHTTPStub.status = 429; AIHTTPStub.headers = ["Retry-After": "7200"]
        do { try await client.validateKey("test-key"); XCTFail("Should fail") }
        catch { XCTAssertEqual((error as? AIRateLimit)?.delay, 7200) }
    }

    func testRedirectResponseIsRejectedRatherThanUsedAsAnalysis() async throws {
        let client = client(); AIHTTPStub.status = 302; AIHTTPStub.headers = ["Location": "https://example.invalid/"]
        do { try await client.validateKey("test-key"); XCTFail("Should fail") }
        catch { XCTAssertEqual(error as? AIReviewFailure, .invalidResponse) }
    }
}

private final class AIHTTPStub: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var data = Data()
    static var headers: [String: String] = [:]
    static var request: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: Self.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor QuietAIScheduler: ReminderScheduling {
    func reconcile(events: [ResetEvent], preferences: UserPreferences, now: Date) async {}
    func cancelAll() async {}
}

private final class AIPublicFeedStub: URLProtocol, @unchecked Sendable {
    static var publicRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isPublicFeed = request.url?.path == "/api/feed"
        let body: Data
        if isPublicFeed {
            Self.publicRequest = request
            let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
            body = try! JSONSerialization.data(withJSONObject: ["stale": false, "tweets": [["id": "10", "url": "https://x.com/thsottiaux/status/10", "text": "Global reset by EOD.", "at": date]]])
        } else { body = Data() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: isPublicFeed ? 200 : 503, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
