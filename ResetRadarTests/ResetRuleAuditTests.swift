import Foundation
import XCTest
@testable import ResetRadar

// Regression cases from the rule review and additional statement/phase variations.
// Synthetic texts are not claims that these posts actually occurred.
@MainActor
final class ResetRuleAuditTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-09-28T10:00:00Z")!

    func classify(_ text: String, author: String = "thsottiaux", sourceID: String = "codex-reset-json") -> ResetEvent? {
        let source = FeedSource(id: sourceID, name: sourceID, url: URL(string: "https://example.test/feed")!, kind: .communityFeed, interval: 600)
        return AnnouncementClassifier().classify(
            FeedItem(id: "123", title: "", body: text, url: URL(string: "https://x.com/\(author)/status/123"), publishedAt: now),
            source: source, fetchedAt: now)
    }

    func actionable(_ event: ResetEvent?) -> Bool {
        event.map { MonitorModel().isActionable($0, now: now) } ?? false
    }

    func test01WednesdayPromiseShouldHaveSameTreatmentAsTuesday() {
        XCTAssertTrue(actionable(classify("I promised a reset for Wednesday.")))
    }

    func test02ExplicitNextWeekAnnouncementShouldBeAnUndatedLead() {
        let event = classify("More resets coming next week for Codex.")
        XCTAssertTrue(actionable(event))
        XCTAssertNil(event?.targetAt)
    }

    func test03NegatedGrantMustNotAlert() {
        XCTAssertFalse(actionable(classify("No new banked reset for Codex users.")))
    }

    func test04GrantQuestionMustNotAlert() {
        XCTAssertFalse(actionable(classify("Will we get a banked reset for Codex?", author: "someone")))
    }

    func test05GrantHelpTextMustNotAlert() {
        XCTAssertFalse(actionable(classify("How to use a banked reset in Codex.", author: "someone")))
    }

    func test06CompletedOldResetMustNotHideTheNextReset() {
        XCTAssertTrue(actionable(classify("Codex resets all propagated. We will reset Codex again tomorrow.")))
    }

    func test07CompletedGrantDistributionShouldRemainUsable() {
        XCTAssertTrue(actionable(classify("The Codex banked reset has been added to all eligible accounts. It is done.")))
    }

    func test08UncertaintyInUnrelatedSentenceMustNotEraseExplicitPromise() {
        XCTAssertTrue(actionable(classify("We will reset Codex tomorrow. Quality will likely improve.")))
    }

    func test09GrantAvailabilityAndExpiryNeedSeparateDates() throws {
        let event = try XCTUnwrap(classify("Codex banked reset becomes available at 2026-09-28T12:00:00Z and expires at 2026-09-30T12:00:00Z."))
        XCTAssertEqual(event.expiresAt, ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z"))
    }

    func test10TimestampOfIncidentMustNotBecomeResetTime() throws {
        let event = try XCTUnwrap(classify("Incident started at 2026-09-28T08:00:00Z. We will reset Codex at 2026-09-28T14:00:00Z."))
        XCTAssertEqual(event.targetAt, ISO8601DateFormatter().date(from: "2026-09-28T14:00:00Z"))
    }

    func test11UnverifiedDatedClaimMustNotBypassConfirmation() {
        XCTAssertFalse(actionable(classify("Codex limits will reset at 2026-09-28T14:00:00Z.", author: "someone")))
    }

    func test12UncertainGrantMustNotOccupyOpportunityWindow() throws {
        let event = try XCTUnwrap(classify("Maybe Codex users get a banked reset tomorrow."))
        XCTAssertFalse(actionable(event))
        XCTAssertNil(MonitorModel.selectActiveEvent([event], now: now))
    }

    func test13WeakSummaryMustNotDowngradeOriginalPromise() throws {
        let original = try XCTUnwrap(classify("Codex limits will reset tomorrow."))
        let summary = try XCTUnwrap(classify("Codex reset expected tomorrow.", sourceID: "codex-reset"))
        var events = [original]
        _ = EventReconciler().merge(summary, into: &events)
        XCTAssertTrue(events[0].confirmedAnnouncement)
    }

    func test14GenericResetWithFutureTimeMustNotCountAsComplete() {
        XCTAssertNotEqual(classify("Codex limits reset for all users tomorrow at 2pm PT.")?.state, .announcedComplete)
    }

    func test15BothProductsShouldBePreserved() throws {
        let event = try XCTUnwrap(classify("We will reset Codex and ChatGPT Work tomorrow."))
        XCTAssertEqual(Set(event.products), Set(["codex", "chatgpt-work"]))
    }

    func test16CompletedPostControl() throws {
        let event = try XCTUnwrap(classify("Resets all propagated. That will be all. Have a fantastic weekend."))
        XCTAssertEqual(event.state, .announcedComplete)
        XCTAssertFalse(actionable(event))
    }

    func test17KnownTuesdayPromiseControl() {
        XCTAssertTrue(actionable(classify("I promised a reset for Tuesday.")))
    }

    func test18AffectedUsersCompensationControl() throws {
        let event = try XCTUnwrap(classify("Some banked resets not fully applying when used in ChatGPT Work and Codex. Everyone who used one in the affected time window is getting another one."))
        XCTAssertEqual(event.audience, "affected-reset-users")
        XCTAssertTrue(actionable(event))
    }

    func test19FutureGrantShouldNotifyAtAnnouncement() {
        XCTAssertTrue(actionable(classify("We will give Codex users a banked reset at 2026-09-28T14:00:00Z.")))
    }

    func test20ReplyWithoutProductNameStillSurfacesTrustedPromise() {
        XCTAssertTrue(actionable(classify("Sorry Gia. More resets coming next week.")))
    }

    func test21EligibilityConditionDoesNotSuppressCompensation() {
        XCTAssertTrue(actionable(classify("If your Codex reset failed, we are restoring a banked reset to your account.")))
    }

    func test22SamePostKeepsCompletionAndNewPreviewSeparate() {
        let source = FeedSource.defaults[0]
        let item = FeedItem(id: "both", title: "", body: "Codex resets all propagated. We will reset Codex again tomorrow.", url: URL(string: "https://x.com/thsottiaux/status/123"), publishedAt: now)
        let events = AnnouncementClassifier().classifyAll(item, source: source, fetchedAt: now)
        XCTAssertEqual(events.count, 2)
        XCTAssertNotEqual(events[0].id, events[1].id)
        XCTAssertTrue(events.contains { $0.state == .announcedComplete })
        XCTAssertTrue(events.contains { actionable($0) })
    }

    func test23NoResetTodayDoesNotCancelTomorrowsPromise() {
        XCTAssertTrue(actionable(classify("No reset today for Codex. We will reset Codex tomorrow.")))
    }

    func test24NominalGrantMentionIsNotAnAward() {
        XCTAssertFalse(actionable(classify("Codex has a feature called a reset grant.")))
        XCTAssertFalse(actionable(classify("A Codex banked reset allows you to get more quota.")))
    }

    func test25FutureAvailabilityIsNotShownAsAlreadyAvailable() throws {
        let event = try XCTUnwrap(classify("Your Codex banked reset is available tomorrow."))
        XCTAssertEqual(event.state, .unresolved)
        XCTAssertEqual(event.announcementStage, "preview")
        XCTAssertTrue(actionable(event))
    }

    func test26NewlyUsableGrantIsActionable() throws {
        let event = try XCTUnwrap(classify("You can now use your banked reset for Codex."))
        XCTAssertTrue(actionable(event))
        XCTAssertEqual(event.state, .available)
    }

    func test27OneTimeAutomaticResetIsNotBanked() {
        XCTAssertNotEqual(classify("We will do a one-time reset of Codex quotas tomorrow.")?.kind, .bankedResetGrant)
    }

    func test28AllWeekdaysAndCommonCommitments() {
        for day in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] {
            XCTAssertTrue(actionable(classify("I promised a reset for \(day).")), day)
        }
        for phrase in ["Codex limits will reset tomorrow.", "We are resetting Codex tomorrow.", "A Codex reset is coming next week.", "We will be loading a banked reset into Pro accounts tomorrow."] {
            XCTAssertTrue(actionable(classify(phrase)), phrase)
        }
    }

    func test29NegationAndSpeculationVariantsNeverAlert() {
        for phrase in ["I hope Codex gets a banked reset tomorrow.", "If we have time we will reset Codex tomorrow.", "Codex users won't receive a banked reset tomorrow.", "Codex quotas will not reset tomorrow.", "For example, Codex limits will reset tomorrow."] {
            XCTAssertFalse(actionable(classify(phrase)), phrase)
        }
    }

    func test30ExpirySentenceDoesNotMakeFutureGrantAvailable() throws {
        let event = try XCTUnwrap(classify("Codex users will receive a banked reset at 2026-09-29T12:00:00Z. It expires at 2026-09-30T12:00:00Z."))
        XCTAssertEqual(event.state, .unresolved)
        XCTAssertEqual(event.windowStart, ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z"))
        XCTAssertEqual(event.expiresAt, ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z"))
        XCTAssertTrue(actionable(event))
    }

    func test31NextWeekPreviewIsRetainedAfterWindowClears() throws {
        let event = try XCTUnwrap(classify("More resets coming next week."))
        var events = [event]
        _ = MonitorModel.advanceLifecycle(&events, now: now.addingTimeInterval(86_401))
        XCTAssertEqual(events[0].state, .unresolved)
        XCTAssertNil(MonitorModel.selectActiveEvent(events, now: now.addingTimeInterval(86_401)))
    }

    func test32CompletedClauseDoesNotSwallowNextActionInSameSentence() {
        XCTAssertTrue(actionable(classify("Codex resets all propagated and we will reset Codex again tomorrow.")))
    }

    func test33IncidentDateBeforeResetActionIsNotUsed() throws {
        let event = try XCTUnwrap(classify("After the incident at 2026-09-28T08:00:00Z, we will reset Codex at 2026-09-28T14:00:00Z."))
        XCTAssertEqual(event.targetAt, ISO8601DateFormatter().date(from: "2026-09-28T14:00:00Z"))
    }

    func test34RealCompensationSummaryPreservesAffectedAudience() throws {
        let event = try XCTUnwrap(classify("There was an issue where banked resets did not fully apply in Codex and ChatGPT Work. Affected users will receive an additional reset and an email apology."))
        XCTAssertTrue(actionable(event))
        XCTAssertEqual(event.kind, .bankedResetGrant)
        XCTAssertEqual(event.audience, "affected-reset-users")
    }
}
