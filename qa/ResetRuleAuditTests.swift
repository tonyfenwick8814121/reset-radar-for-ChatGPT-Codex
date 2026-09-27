import Foundation
import XCTest
@testable import ResetRadar

// Synthetic rule-review cases, not claims that these posts actually occurred.
// Run in an isolated checkout as documented in docs/RESET_RULE_REVIEW.md.
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
}
