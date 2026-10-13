import XCTest
@testable import ResetRadar

final class ClassifierTests: XCTestCase {
    private let classifier = AnnouncementClassifier()
    private let fetched = ISO8601DateFormatter().date(from: "2026-09-09T08:00:00Z")!

    @MainActor
    func testOctober13EODPSTPreviewHasApproximateCountdown() throws {
        let published = ISO8601DateFormatter().date(from: "2026-10-13T01:03:59Z")!
        let item = FeedItem(id: "2109812360596865224", title: "",
            body: "Global reset landing by EOD PST time. Enjoy",
            url: URL(string: "https://x.com/thsottiaux/status/2109812360596865224"), publishedAt: published)
        let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: published.addingTimeInterval(192)))
        XCTAssertEqual(event.kind, .automaticReset)
        XCTAssertEqual(event.state, .scheduled)
        XCTAssertEqual(event.precision, .approximate)
        XCTAssertEqual(event.countdownAt, ISO8601DateFormatter().date(from: "2026-10-13T08:00:00Z"))
        XCTAssertEqual(event.resetDeadlineZone, "PST")
        XCTAssertTrue(event.isResetDeadline)
        XCTAssertTrue(MonitorModel().isActionable(event, now: published.addingTimeInterval(192)))
    }

    func testEndOfDayDeadlineDoesNotPromoteSpeculationOrManualGrants() throws {
        for text in ["Maybe a global reset by EOD PST.", "Global reset by EOD PST?", "No global reset by EOD PST."] {
            let item = FeedItem(id: "10", title: "", body: text, url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: fetched)
            let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: fetched))
            XCTAssertTrue(!event.confirmedAnnouncement || event.state == .cancelled, text)
            XCTAssertNil(event.countdownAt, text)
            XCTAssertFalse(event.isResetDeadline, text)
        }
        let item = FeedItem(id: "10", title: "", body: "Codex users will receive a banked reset by EOD PST.", url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: fetched)
        let grant = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: fetched))
        XCTAssertEqual(grant.kind, .bankedResetGrant)
        XCTAssertEqual(grant.state, .unresolved)
        XCTAssertNil(grant.countdownAt)
        XCTAssertFalse(grant.isResetDeadline)
    }

    func testEODDateQualifiersBeforeResetAreNotDropped() throws {
        let published = ISO8601DateFormatter().date(from: "2026-10-13T01:03:59Z")!
        for prefix in ["Monday", "Next week", "On October 20"] {
            let item = FeedItem(id: "10", title: "", body: "\(prefix) global reset landing by EOD PST.", url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: published)
            let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: published))
            XCTAssertTrue(event.confirmedAnnouncement)
            XCTAssertNil(event.countdownAt, prefix)
        }
        let item = FeedItem(id: "10", title: "", body: "Tomorrow global reset landing by EOD PST.", url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: published)
        let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: published))
        XCTAssertEqual(event.countdownAt, ISO8601DateFormatter().date(from: "2026-10-14T08:00:00Z"))
    }

    @MainActor
    func testOctoberEODCommitmentAlertsWithoutInventingATime() throws {
        let published = ISO8601DateFormatter().date(from: "2026-10-10T22:16:20Z")!
        let item = FeedItem(id: "2109045392684032299", title: "",
            body: "Global reset by EOD. May the tokens do good things for you.",
            url: URL(string: "https://x.com/thsottiaux/status/2109045392684032299"), publishedAt: published)
        let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: published.addingTimeInterval(439)))
        XCTAssertTrue(event.confirmedAnnouncement)
        XCTAssertEqual(event.announcementStage, "preview")
        XCTAssertTrue(MonitorModel().isActionable(event, now: published.addingTimeInterval(439)))
        XCTAssertNil(event.countdownAt, "EOD without a timezone is not an exact reset time")
    }

    func testOctoberSplitPropagationIsACompletion() throws {
        let published = ISO8601DateFormatter().date(from: "2026-10-11T04:01:09Z")!
        let item = FeedItem(id: "2109132167112782291", title: "",
            body: "Put the reset in the bag. All propagated. https://t.co/HGxaD3Zdcj",
            url: URL(string: "https://x.com/thsottiaux/status/2109132167112782291"), publishedAt: published)
        let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: published.addingTimeInterval(449)))
        XCTAssertTrue(event.confirmedAnnouncement)
        XCTAssertEqual(event.state, .announcedComplete)
        XCTAssertEqual(event.completedAt, published)
        XCTAssertNil(event.countdownAt)
        XCTAssertTrue(event.matchedText?.contains("reset") == true)
    }

    func testConciseEODPromisesStillRequireAffirmativeTrustedClaims() throws {
        for text in ["Global reset by EOD.", "Codex reset by end of day.", "Reset before the end of the day."] {
            let item = FeedItem(id: text, title: "", body: text, url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: fetched)
            XCTAssertEqual(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: fetched)?.announcementStage, "preview", text)
        }
        for text in ["Maybe a global reset by EOD.", "Global reset by EOD?", "No global reset by EOD.", "Do not expect a global reset by EOD.", "We hope for a reset by EOD.", "The day we reach perfection it will be resets from there onwards.", "Day 6/ Reset", "Codex reset by design."] {
            let item = FeedItem(id: text, title: "", body: text, url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: fetched)
            XCTAssertNotEqual(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: fetched)?.announcementStage, "preview", text)
        }
        let stranger = FeedItem(id: "stranger", title: "", body: "Global Codex reset by EOD.", url: URL(string: "https://x.com/stranger/status/10"), publishedAt: fetched)
        XCTAssertFalse(classifier.classify(stranger, source: source("codex-reset-json"), fetchedAt: fetched)?.confirmedAnnouncement == true)
    }

    func testSplitPropagationRequiresUnambiguousNearbyAutomaticResetContext() throws {
        for text in ["Codex reset. All propagated.", "The reset.\nFully propagated."] {
            let item = FeedItem(id: text, title: "", body: text, url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: fetched)
            XCTAssertEqual(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: fetched)?.state, .announcedComplete, text)
        }
        for text in ["Maybe a reset. All propagated.", "No reset. All propagated.", "A reset? All propagated.", "Reset your password. All propagated.", "Codex reset tomorrow. All propagated.", "Codex reset. Composer updates. All propagated.", "Banked resets are now available. All propagated.", "Codex reset. All will be propagated tomorrow.", "Codex reset. Not all propagated."] {
            let item = FeedItem(id: text, title: "", body: text, url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: fetched)
            XCTAssertNotEqual(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: fetched)?.state, .announcedComplete, text)
        }
    }

    func testOctoberProcessedResetIsCompletionNotPreview() throws {
        let item = FeedItem(id: "2107676072871600470", title: "",
            body: "We shipped four things that were deemed good to great and some math proofs, but the vote is clear and the community demands a reset. I did calibrate it and it *seems* that the game is rigged in reset's favor, but such are the rules at the moment.\n\nTherefore ... the reset has been processed. Enjoy!",
            url: URL(string: "https://x.com/thsottiaux/status/2107676072871600470"), publishedAt: fetched)
        let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: fetched))
        XCTAssertTrue(event.confirmedAnnouncement)
        XCTAssertEqual(event.kind, .automaticReset)
        XCTAssertEqual(event.state, .announcedComplete)
        XCTAssertEqual(event.announcementStage, "completed")
        XCTAssertEqual(event.audience, "unknown", "Some math proofs must not imply a reset for only some users")
        XCTAssertNil(event.countdownAt)
    }

    func testProcessedCompletionRequiresAnAffirmativeCompletedAction() throws {
        for text in ["The Codex reset has been processed today.", "We have completed the Codex reset.", "The Codex reset has been applied."] {
            let item = FeedItem(id: text, title: "", body: text, url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: fetched)
            XCTAssertEqual(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: fetched)?.state, .announcedComplete, text)
        }
        for text in ["The Codex reset has not been processed.", "Has the Codex reset been processed?", "Maybe the Codex reset has been processed.", "The Codex reset will be processed tomorrow.", "The Codex reset is being processed.", "Four updates or a reset. Or both. How was day 2."] {
            let item = FeedItem(id: text, title: "", body: text, url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: fetched)
            XCTAssertNotEqual(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: fetched)?.state, .announcedComplete, text)
        }
    }

    func testOctoberGlobalResetHasBeijingCountdown() throws {
        let published = ISO8601DateFormatter().date(from: "2026-10-02T02:14:51Z")!
        let item = FeedItem(id: "2105843926221660585", title: "",
            body: "Global reset landing tomorrow 10am PST for all paid ChatGPT accounts. Apologies for the slow start with GPT-6.1 Sol, it's now back to running at expected speeds after the massive load spike in the first two days.",
            url: URL(string: "https://x.com/thsottiaux/status/2105843926221660585"), publishedAt: published)
        let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: published.addingTimeInterval(60)))
        XCTAssertTrue(event.confirmedAnnouncement)
        XCTAssertEqual(event.kind, .automaticReset)
        XCTAssertEqual(event.state, .scheduled)
        XCTAssertEqual(event.precision, .exact)
        let target = try XCTUnwrap(event.countdownAt)
        XCTAssertEqual(target, ISO8601DateFormatter().date(from: "2026-10-02T18:00:00Z"))
        var beijing = Calendar(identifier: .gregorian)
        beijing.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = beijing.dateComponents([.year, .month, .day, .hour, .minute], from: target)
        XCTAssertEqual([components.year, components.month, components.day, components.hour, components.minute], [2026, 10, 3, 2, 0])
        let replay = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: published.addingTimeInterval(86_400)))
        XCTAssertEqual(replay.targetAt, event.targetAt, "Tomorrow stays anchored to the post, not the check date")
    }

    func testBankedResetIsNotAutomaticReset() throws {
        let item = FeedItem(id: "1", title: "Codex usage reset", body: "Some Plus users get a banked reset. Lands by end of day. Source: https://x.com/thsottiaux/status/12345", url: nil, publishedAt: fetched)
        let event = try XCTUnwrap(classifier.classify(item, source: source("modelyard"), fetchedAt: fetched))
        XCTAssertEqual(event.kind, .bankedResetGrant)
        XCTAssertEqual(event.timeMeaning, .grantAvailability)
        XCTAssertNil(event.targetAt)
        XCTAssertEqual(event.audience, "partial")
        XCTAssertEqual(event.id, "status-12345")
        XCTAssertEqual(event.bestEvidence?.url?.host, "x.com")
    }

    func testGrantExpiryUsesExpiresAtInsteadOfAutomaticTarget() throws {
        let item = FeedItem(id: "expiry", title: "Codex usage reset", body: "Your banked reset expires on September 9, 2026 at 14:00 PT.", url: nil, publishedAt: fetched)
        let event = try XCTUnwrap(classifier.classify(item, source: source("modelyard"), fetchedAt: fetched))
        XCTAssertEqual(event.kind, .bankedResetGrant)
        XCTAssertEqual(event.timeMeaning, .grantExpiry)
        XCTAssertNil(event.targetAt)
        XCTAssertEqual(event.expiresAt, ISO8601DateFormatter().date(from: "2026-09-09T21:00:00Z"))
        XCTAssertEqual(event.state, .available)
    }

    func testGrantAvailabilityDateDoesNotBecomeCountdown() throws {
        let item = FeedItem(id: "arrival", title: "Codex usage reset", body: "A banked reset will arrive on September 9, 2026 at 14:00 PT.", url: nil, publishedAt: fetched)
        let event = try XCTUnwrap(classifier.classify(item, source: source("modelyard"), fetchedAt: fetched))
        XCTAssertEqual(event.timeMeaning, .grantAvailability)
        XCTAssertNil(event.targetAt)
        XCTAssertNil(event.expiresAt)
    }

    func testCancelledAndSpeculativeAnnouncementsDoNotSchedule() throws {
        for body in [
            "CANCELLED: Codex reset on September 9, 2026 at 14:00 PT will not happen.",
            "71% probability: Codex reset on September 9, 2026 at 14:00 PT.",
            "A reset on September 9, 2026 at 14:00 PT. Source text: No reset is planned."
        ] {
            let event = try XCTUnwrap(classifier.classify(FeedItem(id: body, title: "Codex usage news", body: body, url: nil, publishedAt: fetched), source: source("modelyard"), fetchedAt: fetched))
            XCTAssertNil(event.targetAt)
            XCTAssertTrue(event.state == .cancelled || event.state == .unresolved)
        }
    }

    func testFeedIdentityAloneDoesNotProveCompletion() throws {
        let item = FeedItem(id: "joke", title: "Codex reset news", body: "This reset post is a joke. Never gonna give you up. Thanks.", url: nil, publishedAt: fetched)
        let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset"), fetchedAt: fetched))
        XCTAssertNotEqual(event.state, .announcedComplete)
    }

    func testCompletedFeedEntryDoesNotBecomeFutureLead() throws {
        let item = FeedItem(id: "2", title: "Official Codex reset announcement", body: "Usage limits reset for all paid ChatGPT users.", url: URL(string: "https://x.com/a/status/9"), publishedAt: fetched)
        let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset"), fetchedAt: fetched))
        XCTAssertEqual(event.state, .announcedComplete)
        XCTAssertEqual(event.kind, .automaticReset)
    }

    func testSeptemberCompletionPostAndSummaryAreNotNewLeads() throws {
        let url = URL(string: "https://x.com/thsottiaux/status/2103911959544610829")!
        let original = FeedItem(id: "2103911959544610829", title: "", body: "Resets all propagated. That will be all. Have a fantastic weekend.", url: url, publishedAt: fetched)
        let summary = FeedItem(id: "summary", title: "Official Codex reset announcement — Sep 26, 2026", body: "Reset for every paid Codex and ChatGPT Work user, promised after a brief disruption and confirmed fully propagated that evening: ‘Resets all propagated. That will be all.’", url: url, publishedAt: fetched)
        for (item, feed) in [(original, "codex-reset-json"), (summary, "codex-reset")] {
            let event = try XCTUnwrap(classifier.classify(item, source: source(feed), fetchedAt: fetched))
            XCTAssertEqual(event.state, .announcedComplete, feed)
            XCTAssertEqual(event.kind, .automaticReset, feed)
        }
    }

    @MainActor
    func testUnconfirmedSavedLeadDoesNotAppearAsNewReset() throws {
        let item = FeedItem(id: "old", title: "Codex reset announcement", body: "That will be all.", url: nil, publishedAt: fetched)
        var legacy = try XCTUnwrap(classifier.classify(item, source: source("codex-reset"), fetchedAt: fetched))
        legacy.kind = .lead
        legacy.state = .unresolved
        XCTAssertFalse(legacy.confirmedAnnouncement)
        XCTAssertNil(MonitorModel.selectActiveEvent([legacy], now: fetched))
    }

    func testUnrelatedStatusIncidentIsIgnored() {
        let item = FeedItem(id: "3", title: "Login incident resolved", body: "ChatGPT service restored", url: nil, publishedAt: fetched)
        XCTAssertNil(classifier.classify(item, source: source("openai-status"), fetchedAt: fetched))
    }

    @MainActor
    func testConfirmedAstraAnnouncementAlertsWithoutInventingTime() throws {
        let body = "Hi Astra users. A reset and a quick update on quality issues. And of course, a reset is also landing by midnight today."
        let item = FeedItem(id: "today", title: "", body: body, url: URL(string: "https://x.com/thsottiaux/status/2098612714704891959"), publishedAt: fetched)
        let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: fetched))
        XCTAssertEqual(event.kind, .lead)
        XCTAssertTrue(event.confirmedAnnouncement)
        XCTAssertNil(event.targetAt)
        XCTAssertTrue(MonitorModel().isActionable(event, now: fetched))
        for text in ["Maybe a reset is landing for Astra users", "Astra users wish a reset is landing", "Astra users: no reset is planned", "Astra users reset password tomorrow"] {
            let uncertain = FeedItem(id: text, title: "", body: text, url: item.url, publishedAt: fetched)
            if let candidate = classifier.classify(uncertain, source: source("codex-reset-json"), fetchedAt: fetched) {
                XCTAssertFalse(MonitorModel().isActionable(candidate, now: fetched), text)
            }
        }
        let stranger = FeedItem(id: "stranger", title: "", body: body, url: URL(string: "https://x.com/stranger/status/123"), publishedAt: fetched)
        let unverified = try XCTUnwrap(classifier.classify(stranger, source: source("modelyard"), fetchedAt: fetched))
        XCTAssertFalse(unverified.confirmedAnnouncement)
        XCTAssertFalse(MonitorModel().isActionable(unverified, now: fetched))
    }

    @MainActor
    func testCompensationStillAlertsWithEligibility() throws {
        let item = FeedItem(id: "compensation", title: "", body: "Some banked resets not fully applying when used in ChatGPT Work and Codex. Everyone who used one in the affected time window is getting another one.", url: nil, publishedAt: fetched)
        let event = try XCTUnwrap(classifier.classify(item, source: source("modelyard"), fetchedAt: fetched))
        XCTAssertEqual(event.audience, "affected-reset-users")
        XCTAssertTrue(MonitorModel().isActionable(event, now: fetched))
    }

    func testPublicFeedUsesOriginalTextAndRejectsStaleData() throws {
        let json = #"{"stale":false,"tweets":[{"id":"1","url":"https://x.com/thsottiaux/status/1","text":"Reset all propagated. Sweet dreams.","at":"2026-09-12T08:09:17.000Z"}],"events":[{"summary":"Ignore generated classification"}]}"#
        let items = try FeedClient.parsePublicFeed(Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        let event = try XCTUnwrap(classifier.classify(items[0], source: source("codex-reset-json"), fetchedAt: fetched))
        XCTAssertEqual(event.state, .announcedComplete)
        XCTAssertThrowsError(try FeedClient.parsePublicFeed(Data(json.replacingOccurrences(of: "false", with: "true").utf8)))
        XCTAssertThrowsError(try FeedClient.parsePublicFeed(Data("{}".utf8)))
    }

    @MainActor
    func testSolLaunchBankedResetIsAQualifiedRolloutAlert() throws {
        let published = ISO8601DateFormatter().date(from: "2026-09-22T18:23:37Z")!
        let body = "GPT-6 Sol and Luna are out. We are loading a banked reset into all accounts of our Plus, Pro and Business users."
        let item = FeedItem(id: "2102463847714247142", title: "", body: body,
                            url: URL(string: "https://x.com/thsottiaux/status/2102463847714247142"), publishedAt: published)
        let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: published.addingTimeInterval(60)))
        XCTAssertEqual(event.kind, .bankedResetGrant)
        XCTAssertEqual(event.state, .unresolved)
        XCTAssertEqual(event.audience, "paid-plans")
        XCTAssertNil(event.targetAt)
        XCTAssertTrue(MonitorModel().isActionable(event, now: published.addingTimeInterval(60)))
    }

    @MainActor
    func testTrustedTuesdayPromiseAlertsWithoutPretendingItIsAGrant() throws {
        let published = ISO8601DateFormatter().date(from: "2026-09-22T04:31:32Z")!
        let item = FeedItem(id: "2102254445082116335", title: "",
                            body: "We are almost Tuesday and I promised a reset for Tuesday. Among some other things. See you soon.",
                            url: URL(string: "https://x.com/thsottiaux/status/2102254445082116335"), publishedAt: published)
        let event = try XCTUnwrap(classifier.classify(item, source: source("codex-reset-json"), fetchedAt: published.addingTimeInterval(60)))
        XCTAssertEqual(event.kind, .lead)
        XCTAssertEqual(event.state, .unresolved)
        XCTAssertNil(event.targetAt)
        XCTAssertTrue(MonitorModel().isActionable(event, now: published.addingTimeInterval(60)))

        let stranger = FeedItem(id: "stranger", title: "", body: item.body,
                                url: URL(string: "https://x.com/someone-else/status/123"), publishedAt: published)
        XCTAssertNil(classifier.classify(stranger, source: source("codex-reset-json"), fetchedAt: published.addingTimeInterval(60)))
    }

    private func source(_ id: String) -> FeedSource {
        FeedSource(id: id, name: id, url: URL(string: "https://example.com/feed")!, kind: .communityFeed, interval: 300)
    }
}
