import Foundation
import AppKit
import Combine
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

    func testRepeatedDisplayReadsDoNotReparseUnchangedHistory() async throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let anchor = try XCTUnwrap(AIOriginalPost(post("1", "Over the next 28 days, each day we’ll either ship one thing that is a clear improvement and relevant for most codex/work users or ship a full reset.", date: now.addingTimeInterval(-20 * 86_400))))
        var state = AIReviewState(); state.posts = [anchor]
        for index in 0..<81 {
            let text = index.isMultiple(of: 3) ? "Day 21/ and reset. Enjoy." : "Day 21/ We shipped cache improvements."
            let date = now.addingTimeInterval(index < 39 ? -Double(index + 60) : -172_800)
            state.posts.append(try XCTUnwrap(AIOriginalPost(post(String(index + 10), text, date: date))))
        }
        for original in state.posts.dropFirst().prefix(39) {
            let input = AIReviewInput(post: original, parent: nil, campaign: ResetCampaignContext(post: original, originals: state.posts))
            var record = AIReviewRecord(fingerprint: input.fingerprint, postID: original.id, status: .success)
            record.analysis = AIAnalysis(claims: [], contextMissing: false)
            state.records.append(record)
        }
        let (reviewer, client, keys, _) = try await setup(saved: state)
        XCTAssertEqual(reviewer.recentRecords.count, 39)
        let start = ContinuousClock.now
        var count = 0
        for _ in 0..<100 { count += reviewer.recentRecords.count }
        let elapsed = start.duration(to: .now)
        print("100 unchanged AI history reads: \(elapsed)")
        XCTAssertEqual(count, 3900)
        // A generous frame budget catches the multi-second history reparse regression.
        XCTAssertLessThan(elapsed, .milliseconds(250))
        let requests = await inputCount(client); XCTAssertEqual(requests, 0); XCTAssertEqual(keys.reads, 0)
    }

    func testDisplayHistoryUpdatesAfterCampaignContextAndAcknowledgmentChange() async throws {
        let (reviewer, _, _, _) = try await setup()
        let current = post("20", "Day 21/ and reset. Enjoy.")
        await reviewer.ingest([current])
        let previous = try XCTUnwrap(reviewer.recentRecords.first?.id)
        let anchor = post("1", "Over the next 28 days, each day we’ll either ship one thing that is a clear improvement and relevant for most codex/work users or ship a full reset.", date: Date().addingTimeInterval(-20 * 86_400))
        await reviewer.ingest([anchor])
        let latest = try XCTUnwrap(reviewer.recentRecords.first?.id)
        XCTAssertNotEqual(previous, latest)
        XCTAssertEqual(reviewer.recentRecords.count, 1)
        XCTAssertFalse(reviewer.recentRecords[0].acknowledged)
        await reviewer.acknowledge(latest)
        XCTAssertTrue(reviewer.recentRecords[0].acknowledged)
        await reviewer.ingest([post("20", "Day 21/ We shipped cache improvements.", date: try XCTUnwrap(current.publishedAt))])
        XCTAssertNotEqual(reviewer.recentRecords.first?.id, latest)
        XCTAssertEqual(reviewer.recentRecords.count, 1)
    }

    func testCachedDisplayHistoryStillExpiresAttentionWithoutDataChanges() async throws {
        let expiry = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 2)
        let original = try XCTUnwrap(AIOriginalPost(post("20", "Landing within the next 2 hours", date: expiry.addingTimeInterval(-86_400))))
        var record = AIReviewRecord(fingerprint: AIReviewInput(post: original, parent: nil).fingerprint, postID: original.id, status: .success)
        record.analysis = AIAnalysis(claims: [claim(quote: original.text)], contextMissing: false)
        var state = AIReviewState(); state.enabled = true; state.posts = [original]; state.records = [record]
        let (reviewer, _, keys, _) = try await setup(saved: state)
        XCTAssertTrue(reviewer.needsAttention)
        XCTAssertEqual(reviewer.recentRecords.count, 1)
        try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow) + 0.05))
        XCTAssertEqual(reviewer.recentRecords.count, 1, "History remains visible")
        XCTAssertFalse(reviewer.needsAttention, "Attention expires independently of history-cache invalidation")
        XCTAssertEqual(keys.reads, 0)
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

    func testAuthorizationSuccessSurvivesAnalysisFailureAndClearsOnDisable() async throws {
        let client = ReviewStub(); await client.setAnalysisFailure(AIReviewFailure.truncatedResponse)
        let (reviewer, _, _, _) = try await setup(client: client)
        await reviewer.ingest([post()])
        let enabled = await authorize(reviewer)
        await finish(reviewer)
        XCTAssertTrue(enabled)
        XCTAssertTrue(reviewer.authorizationSucceeded)
        XCTAssertTrue(reviewer.state.enabled)
        XCTAssertTrue(reviewer.hasKey)
        XCTAssertEqual(reviewer.recentRecords.first?.failure, .truncatedResponse)
        await reviewer.disable()
        XCTAssertFalse(reviewer.authorizationSucceeded)
    }

    func testOctober15FindingIsVisibleWithoutARuleEventAndUpdatesOuterModel() async throws {
        let text = "Landing within the next 2 hours"
        let client = ReviewStub()
        var value = claim(quote: text)
        value.timeText = "within the next 2 hours"
        await client.setAnalysis(AIAnalysis(claims: [value], contextMissing: false))
        let (reviewer, _, _, store) = try await setup(client: client)
        let model = MonitorModel(store: store, scheduler: QuietAIScheduler(), aiReview: reviewer)
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        let parent = post("2110595484180214059", "The reports of my reset button being lost are greatly exaggerated\n\nDay 10/ Reset", date: Date().addingTimeInterval(-120))
        let reply = post("2110595554036400151", text, parent: parent.id)
        await reviewer.ingest([parent, reply]); _ = await authorize(reviewer); await finish(reviewer)
        XCTAssertNil(model.activeEvent, "AI findings do not create confirmed rule events")
        XCTAssertTrue(reviewer.needsAttention)
        XCTAssertTrue(reviewer.attentionTitle(.zhHans).contains("待核对"))
        XCTAssertTrue(reviewer.attentionTitle(.en).contains("Needs review"))
        XCTAssertTrue(reviewer.attentionTiming(.zhHans).contains("within the next 2 hours"))
        XCTAssertGreaterThan(changes, 0, "Main, mini and menu must observe nested AI changes")
        for record in reviewer.recentRecords { await reviewer.acknowledge(record.id) }
        XCTAssertFalse(reviewer.needsAttention)
        observation.cancel()
    }

    func testAttentionExpiryAndDisableDoNotShowAFalseFinding() async throws {
        let now = Date()
        let original = try XCTUnwrap(AIOriginalPost(post(date: now.addingTimeInterval(-90_000))))
        var record = AIReviewRecord(fingerprint: AIReviewInput(post: original, parent: nil).fingerprint, postID: original.id)
        record.status = .success; record.comparison = .possibleMiss; record.analysis = AIAnalysis(claims: [claim()], contextMissing: false)
        var state = AIReviewState(); state.enabled = true; state.keyConfigured = true; state.posts = [original]; state.records = [record]
        let (reviewer, _, _, _) = try await setup(key: "test-key", saved: state)
        XCTAssertFalse(reviewer.needsAttention, "Old findings expire after 24 hours")
        await reviewer.ingest([post()]); _ = await authorize(reviewer); await finish(reviewer)
        await reviewer.disable()
        XCTAssertFalse(reviewer.needsAttention)
    }

    func testDetailedFailureMetadataPersistsWithoutServerTextOrCredentials() async throws {
        let client = ReviewStub()
        let detail = AIReviewDiagnostic(httpStatus: 200, finishReason: "length", completionTokens: 1200, reasoningTokens: 1195)
        await client.setAnalysisFailure(AIReviewError(failure: .truncatedResponse, diagnostic: detail))
        let (reviewer, _, _, store) = try await setup(client: client)
        await reviewer.ingest([post()]); _ = await authorize(reviewer); await finish(reviewer)
        let saved = await store.loadAIReviewResult()
        XCTAssertEqual(saved.value.records.first?.failure, .truncatedResponse)
        XCTAssertEqual(saved.value.records.first?.diagnostic?.reasoningTokens, 1195)
        XCTAssertEqual(saved.value.records.first?.diagnostic?.finishReason, "length")
        let json = String(data: try JSONEncoder().encode(saved.value), encoding: .utf8)!
        XCTAssertFalse(json.contains("test-key"))
        XCTAssertFalse(json.contains("Bearer"))
    }

    func testRetryExhaustionAndCooldownExplainWhyRetryIsDisabled() async throws {
        let client = ReviewStub(); await client.setAnalysisFailure(AIReviewFailure.network)
        let (reviewer, _, _, _) = try await setup(client: client)
        await reviewer.ingest([post()]); _ = await authorize(reviewer); await finish(reviewer)
        XCTAssertTrue(reviewer.canRetryFailures)
        await reviewer.retryFailures(); await finish(reviewer)
        XCTAssertFalse(reviewer.canRetryFailures)
        XCTAssertTrue(reviewer.retryExplanation(.zhHans)?.contains("2次") == true)
        XCTAssertTrue(reviewer.retryExplanation(.en)?.contains("both attempts") == true)
    }

    func testStandardEditingMenuRoutesCommandShortcutsToFocusedResponder() {
        for locale in [AppLocale.zhHans, .en] {
            let menu = StandardEditingMenu.make(locale: locale)
            let actions = menu.items.flatMap { $0.submenu?.items ?? [] }
            for (key, selector) in [("v", "paste:"), ("a", "selectAll:"), ("c", "copy:"), ("x", "cut:")] {
                let item = actions.first { $0.keyEquivalent == key }
                XCTAssertEqual(item?.action, Selector(selector))
                XCTAssertTrue(item?.keyEquivalentModifierMask.contains(.command) == true)
                XCTAssertNil(item?.target)
            }
        }
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

    func testMissingContextForResetCandidateIsNotAnAgreement() {
        let item = post("2112432076767289678", "Day 15/ Nevermind, we're still cooking... and reset. Enjoy.")
        let rules = AnnouncementClassifier().classifyAll(item, source: FeedSource.defaults.first { $0.id == "codex-reset-json" }!, fetchedAt: Date())
        XCTAssertNotEqual(AIReviewCoordinator.compare(AIAnalysis(claims: [], contextMissing: true), rules: rules), .agreement)
    }

    func testInconclusiveCampaignResultNotifiesOnceWithoutConfirmedAIClaim() async throws {
        let client = ReviewStub(); await client.setAnalysis(AIAnalysis(claims: [], contextMissing: true))
        let (reviewer, _, keys, store) = try await setup(client: client)
        let anchor = post("1", "Over the next 28 days, each day we’ll either ship one thing that is a clear improvement and relevant for most codex/work users or ship a full reset.", date: Date().addingTimeInterval(-15 * 86_400))
        let current = post("20", "Day 15/ and reset. Enjoy.")
        var notices = 0; reviewer.onReviewNotice = { notices += 1 }
        await reviewer.ingest([anchor, current]); _ = await authorize(reviewer); await finish(reviewer)
        XCTAssertEqual(reviewer.recentRecords.first?.comparison, .inconclusive)
        XCTAssertEqual(notices, 1)
        XCTAssertTrue(reviewer.needsAttention)
        XCTAssertTrue(reviewer.attentionTitle(.zhHans).contains("信息不足"))
        XCTAssertTrue(reviewer.attentionTitle(.en).contains("incomplete"))
        let sent = await client.inputs
        XCTAssertEqual(sent.first?.campaign?.announcement.id, anchor.id)
        let restarted = AIReviewCoordinator(store: store, client: client, keys: keys)
        restarted.onReviewNotice = { notices += 1 }
        await restarted.load(); await restarted.ingest([anchor, current]); restarted.kick(); await finish(restarted)
        XCTAssertEqual(notices, 1)
        await restarted.acknowledge(try XCTUnwrap(restarted.attentionRecord?.id))
        XCTAssertFalse(restarted.needsAttention)
    }

    func testUnrelatedMissingContextDoesNotCreateReviewNoise() async throws {
        let analysis = AIAnalysis(claims: [], contextMissing: true)
        for text in ["We are still cooking.", "People are asking me for resets on the street now.", "Day 15/ We shipped cache improvements."] {
            let item = post("20", text)
            let rules = AnnouncementClassifier().classifyAll(item, source: FeedSource.defaults.first { $0.id == "codex-reset-json" }!, fetchedAt: Date())
            XCTAssertEqual(AIReviewCoordinator.compare(analysis, rules: rules), .agreement, text)
        }
    }

    func testUnchangedLegacyHistoryAndUnrelatedSuccessAreReusedWithoutCloudCalls() async throws {
        let old = try XCTUnwrap(AIOriginalPost(post("19", "Previous unrelated update", date: Date().addingTimeInterval(-90_000))))
        let fresh = try XCTUnwrap(AIOriginalPost(post("20", "New unrelated update")))
        var state = AIReviewState(); state.posts = [old, fresh]
        for original in [old, fresh] {
            let input = AIReviewInput(post: original, parent: nil)
            var record = AIReviewRecord(fingerprint: input.legacyFingerprint, postID: original.id)
            record.status = .success; record.analysis = AIAnalysis(claims: [], contextMissing: true); record.comparison = .agreement
            state.records.append(record)
        }
        let (reviewer, client, _, _) = try await setup(saved: state)
        await reviewer.ingest([old.feedItem, fresh.feedItem]); _ = await authorize(reviewer); await finish(reviewer)
        XCTAssertEqual(reviewer.recentRecords.count, 2)
        let count = await inputCount(client); XCTAssertEqual(count, 0)
    }

    func testEnabledCacheLoadsWithoutKeychainAndReadsOffMainThreadOnlyForAnalysis() async throws {
        var state = AIReviewState(); state.enabled = true; state.keyConfigured = true
        let (reviewer, _, keys, _) = try await setup(key: "test-key", saved: state)
        XCTAssertEqual(keys.reads, 0)
        await reviewer.ingest([post()]); reviewer.kick(); await finish(reviewer)
        XCTAssertGreaterThan(keys.reads, 0)
        XCTAssertFalse(keys.lastReadWasOnMainThread)
    }

    func testActiveCampaignAnchorSurvivesBusyFeedRetentionWithoutAnyModelCall() async throws {
        let (reviewer, client, keys, _) = try await setup()
        let anchor = post("1", "Over the next 28 days, each day we’ll either ship one thing that is a clear improvement and relevant for most codex/work users or ship a full reset.", date: Date().addingTimeInterval(-15 * 86_400))
        let current = post("2", "Day 15/ and reset. Enjoy.")
        let others = (100..<265).map { post(String($0), "Other public update", date: Date().addingTimeInterval(-1000 - Double($0))) }
        await reviewer.ingest([anchor, current] + others)
        XCTAssertEqual(reviewer.state.posts.count, 150)
        XCTAssertNotNil(reviewer.campaignContext(for: current.id))
        let count = await inputCount(client); XCTAssertEqual(count, 0)
        XCTAssertEqual(keys.reads, 0)
    }

    func testStartupQueuesFreshLegacyCampaignReviewWithoutWaitingForFeedCheck() async throws {
        let anchor = try XCTUnwrap(AIOriginalPost(post("1", "Over the next 28 days, each day we’ll either ship one thing that is a clear improvement and relevant for most codex/work users or ship a full reset.", date: Date().addingTimeInterval(-15 * 86_400))))
        let current = try XCTUnwrap(AIOriginalPost(post("20", "Day 15/ and reset. Enjoy.")))
        let legacyInput = AIReviewInput(post: current, parent: nil)
        var legacy = AIReviewRecord(fingerprint: legacyInput.legacyFingerprint, postID: current.id)
        legacy.status = .success; legacy.analysis = AIAnalysis(claims: [], contextMissing: true); legacy.comparison = .agreement
        var state = AIReviewState(); state.enabled = true; state.keyConfigured = true
        state.posts = [anchor, current]; state.records = [legacy]
        let client = ReviewStub(); await client.setAnalysis(AIAnalysis(claims: [], contextMissing: true))
        let (reviewer, _, keys, _) = try await setup(client: client, key: "test-key", saved: state)
        XCTAssertEqual(reviewer.recentRecords.first?.status, .pending)
        XCTAssertEqual(keys.reads, 0)
        reviewer.kick(); await finish(reviewer)
        XCTAssertEqual(reviewer.recentRecords.first?.comparison, .inconclusive)
        XCTAssertTrue(reviewer.needsAttention)
        let count = await inputCount(client); XCTAssertEqual(count, 1)
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

    func testPostEditedDuringKeychainWaitDoesNotSendStaleInput() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rr-ai-" + UUID().uuidString)
        directories.append(dir)
        let store = LocalStore(directory: dir)
        var state = AIReviewState(); state.enabled = true; state.keyConfigured = true
        state.posts = [try XCTUnwrap(AIOriginalPost(post()))]
        try await store.saveAIReview(state)
        let started = expectation(description: "Background key read started")
        let keys = WaitingAIKeys(started: started)
        defer { keys.release.signal() }
        let client = ReviewStub()
        let reviewer = AIReviewCoordinator(store: store, client: client, keys: keys)
        await reviewer.load(); reviewer.kick()
        let wait = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(wait, .completed)
        await reviewer.ingest([post("10", "New product release, no quota announcement.")])
        keys.release.signal()
        await finish(reviewer)
        let inputs = await client.inputs
        XCTAssertEqual(inputs.map(\.post.text), ["New product release, no quota announcement."])
        reviewer.stop()
    }

    func testRequestIsIndependentFreeOnlyStructuredAndNoKeyInBody() throws {
        let input = AIReviewInput(post: try XCTUnwrap(AIOriginalPost(post())), parent: nil)
        let body = try OpenRouterReviewClient.requestBody(input)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["models"] as? [String], ["xingchen-agi/xing4.0-29b-a4b:free", "dots-studio/dots-3-note-preview:free"])
        XCTAssertNil(json["model"]); XCTAssertNil(json["tools"]); XCTAssertNil(json["plugins"])
        XCTAssertEqual((json["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains("test-key"))
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertFalse(messages[1]["content"]!.contains("rule"))
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["enabled"] as? Bool, false)
        let provider = try XCTUnwrap(json["provider"] as? [String: Any])
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
        let prices = try XCTUnwrap(provider["max_price"] as? [String: Int])
        XCTAssertEqual(prices, ["prompt": 0, "completion": 0])
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
    var lastReadWasOnMainThread = false
    init(_ key: String?) { self.key = key }
    func read() throws -> String? { reads += 1; lastReadWasOnMainThread = Thread.isMainThread; return key }
    func save(_ key: String) throws { self.key = key }
    func remove() throws { key = nil }
}

private final class WaitingAIKeys: AIKeyStoring, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let started: XCTestExpectation
    private var firstRead = true
    init(started: XCTestExpectation) { self.started = started }
    func read() throws -> String? {
        if firstRead {
            firstRead = false; started.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else { throw AIReviewFailure.keychain }
        }
        return "test-key"
    }
    func save(_ key: String) throws {}
    func remove() throws {}
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
        catch { XCTAssertEqual((error as? AIReviewError)?.failure, .malformedResponse) }
    }

    func testServiceRequestAndQuotaFailuresAreDistinctAndSanitized() async throws {
        for (status, failure) in [(404, AIReviewFailure.serviceUnavailable), (503, .serviceUnavailable), (502, .serviceUnavailable), (400, .requestRejected), (402, .quotaUnavailable)] {
            let client = client(); AIHTTPStub.status = status
            AIHTTPStub.data = Data(#"{"error":{"message":"do not echo test-key"}}"#.utf8)
            do { try await client.validateKey("test-key"); XCTFail("Should fail") }
            catch {
                let typed = try XCTUnwrap(error as? AIReviewError)
                XCTAssertEqual(typed.failure, failure)
                XCTAssertEqual(typed.diagnostic.httpStatus, status)
                XCTAssertFalse(String(describing: typed).contains("test-key"))
            }
        }
    }

    func testHistoricalEndpoint404DoesNotDisplayAsMalformedAnswer() {
        var record = AIReviewRecord(fingerprint: "old", postID: "10", status: .failed, failure: .malformedResponse,
                                    diagnostic: AIReviewDiagnostic(httpStatus: 404))
        XCTAssertEqual(record.displayedFailure, .serviceUnavailable)
        record.diagnostic = AIReviewDiagnostic(httpStatus: 200)
        XCTAssertEqual(record.displayedFailure, .malformedResponse)
    }

    func testDecodeDifferentiatesTruncationEmptyFormatAndEvidence() throws {
        let item = FeedItem(id: "10", title: "", body: "Global reset by EOD.", url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: Date())
        let input = AIReviewInput(post: try XCTUnwrap(AIOriginalPost(item)), parent: nil)
        for (finish, content, reason) in [("length", "", AIReviewFailure.truncatedResponse), ("stop", "", .emptyResponse), ("stop", "not JSON", .malformedResponse), ("error", "", .serviceUnavailable), ("content_filter", "", .refusedResponse)] {
            let data = try JSONSerialization.data(withJSONObject: ["model": "test:free", "choices": [["finish_reason": finish, "message": ["content": content]]], "usage": ["completion_tokens": 1200, "completion_tokens_details": ["reasoning_tokens": 1198]]])
            XCTAssertThrowsError(try OpenRouterReviewClient.decode(data, input: input)) { error in
                let typed = error as? AIReviewError
                XCTAssertEqual(typed?.failure, reason)
                XCTAssertEqual(typed?.diagnostic.finishReason, finish)
                XCTAssertEqual(typed?.diagnostic.reasoningTokens, 1198)
            }
        }
        let bad = AIAnalysis(claims: [AIClaim(type: .automatic, phase: .preview, explicit: true, quote: "Invented quote", noteZH: "预告", noteEN: "Preview")], contextMissing: false)
        let data = try JSONSerialization.data(withJSONObject: ["model": "test:free", "choices": [["finish_reason": "stop", "message": ["content": String(data: try JSONEncoder().encode(bad), encoding: .utf8)!]]]])
        XCTAssertThrowsError(try OpenRouterReviewClient.decode(data, input: input)) { error in XCTAssertEqual((error as? AIReviewError)?.failure, .evidenceMismatch) }
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
