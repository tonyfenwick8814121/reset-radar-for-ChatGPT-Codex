import XCTest
@testable import ResetRadar

final class ResetCampaignContextTests: XCTestCase {
    private let iso = ISO8601DateFormatter()
    private let classifier = AnnouncementClassifier()
    private let pledge = "Over the next 28 days, each day we’ll either ship one thing that is a clear improvement and relevant for most codex/work users or ship a full reset. Let the improvements begin."
    private var source: FeedSource { FeedSource.defaults.first { $0.id == "codex-reset-json" }! }
    private var published: Date { iso.date(from: "2026-10-20T06:33:48Z")! }
    private func post(_ id: String, _ text: String, at date: Date? = nil, parent: String? = nil) -> AIOriginalPost {
        AIOriginalPost(FeedItem(id: id, title: "", body: text, url: URL(string: "https://x.com/thsottiaux/status/\(id)"), publishedAt: date ?? published, replyParentID: parent))!
    }
    private var anchor: AIOriginalPost { post("2106845241357824205", pledge, at: iso.date(from: "2026-10-04T20:33:43Z")) }

    func testActualDeliveryUsesPledgeButDoesNotInventAccountScopeOrResetTime() throws {
        let current = post("2112432076767289678", "Day 15/ Nevermind, we're still cooking... and reset. Enjoy.")
        let context = try XCTUnwrap(ResetCampaignContext(post: current, originals: [anchor, current]))
        let event = try XCTUnwrap(classifier.classify(current.feedItem, source: source, fetchedAt: published, campaign: context))
        XCTAssertEqual(event.state, .announcedComplete)
        XCTAssertEqual(event.completedAt, published)
        XCTAssertEqual(event.audience, "unknown")
        XCTAssertEqual(Set(event.products), ["codex", "chatgpt-work"])
        XCTAssertNil(event.countdownAt)
        XCTAssertNotEqual(classifier.classify(current.feedItem, source: source, fetchedAt: published)?.state, .announcedComplete)
    }

    func testDeliveryIsNotSpecificToOneDayOrCookingPhrase() throws {
        let current = post("20", "Day 16/ Improvements need more work... and a full reset. Enjoy!")
        let context = try XCTUnwrap(ResetCampaignContext(post: current, originals: [anchor, current]))
        XCTAssertEqual(classifier.classify(current.feedItem, source: source, fetchedAt: published, campaign: context)?.state, .announcedComplete)
    }

    func testMissingExpiredFutureAndOutOfRangePledgesCannotConfirm() {
        let current = post("20", "Day 15/ and reset. Enjoy.")
        XCTAssertNil(ResetCampaignContext(post: current, originals: [current]))
        for invalid in [post("1", pledge, at: published.addingTimeInterval(1)), post("2", pledge, at: published.addingTimeInterval(-29 * 86_400))] {
            XCTAssertNil(ResetCampaignContext(post: current, originals: [invalid, current]))
        }
        for day in [0, 29] {
            let invalid = post("20", "Day \(day)/ and reset. Enjoy.")
            XCTAssertNil(ResetCampaignContext(post: invalid, originals: [anchor, invalid]))
        }
    }

    func testNegationRequestsSpeculationHistoryAndOtherResetTypesNeverBecomeCompletion() {
        for text in ["Day 15/ No reset. Enjoy.", "Day 15/ Maybe ... and reset. Enjoy.", "Day 15/ Please give us a reset. Enjoy.", "Day 15/ Will there be a reset? Enjoy.", "Day 15/ Tomorrow ... and reset. Enjoy.", "Day 15/ Yesterday ... and reset. Enjoy.", "Day 15/ Reset your password. Enjoy.", "Day 15/ A banked reset is available. Enjoy.", "Day 15/ We shipped a feature. Enjoy."] {
            let current = post("20", text)
            let context = ResetCampaignContext(post: current, originals: [anchor, current])
            XCTAssertNotEqual(classifier.classify(current.feedItem, source: source, fetchedAt: published, campaign: context)?.state, .announcedComplete, text)
        }
        let marker = post("20", "Day 15/ Reset")
        let context = ResetCampaignContext(post: marker, originals: [anchor, marker])
        XCTAssertNotNil(context)
        XCTAssertNotEqual(classifier.classify(marker.feedItem, source: source, fetchedAt: published, campaign: context)?.state, .announcedComplete)
    }

    func testDirectReplyHasTopicAndDeadlineWithoutTreatingMarkerAsCompletion() throws {
        let marker = post("2111492673890824348", "Day 13/ Le limit reset", at: iso.date(from: "2026-10-17T16:20:57Z"))
        let reply = post("2111492738025959922", "Landing sometime today by EOD PST", at: iso.date(from: "2026-10-17T16:21:13Z"), parent: marker.id)
        let context = try XCTUnwrap(ResetCampaignContext(post: reply, originals: [anchor, marker, reply]))
        let event = try XCTUnwrap(classifier.classify(reply.feedItem, source: source, fetchedAt: reply.publishedAt, campaign: context))
        XCTAssertTrue(event.confirmedAnnouncement)
        XCTAssertEqual(event.announcementStage, "preview")
        XCTAssertEqual(event.countdownAt, iso.date(from: "2026-10-18T08:00:00Z"))
        XCTAssertTrue(event.isResetDeadline)
        XCTAssertNil(ResetCampaignContext(post: reply, originals: [anchor, reply]))
        let unrelated = post("21", "Landing at JFK tomorrow", parent: marker.id)
        XCTAssertNil(ResetCampaignContext(post: unrelated, originals: [anchor, marker, unrelated]))
    }

    func testCampaignPromptCarriesOnlyOriginalEvidenceAndChangesCacheIdentity() throws {
        let current = post("20", "Day 15/ and reset. Enjoy.")
        let context = try XCTUnwrap(ResetCampaignContext(post: current, originals: [anchor, current]))
        let plain = AIReviewInput(post: current, parent: nil)
        let contextual = AIReviewInput(post: current, parent: nil, campaign: context)
        XCTAssertNotEqual(plain.fingerprint, contextual.fingerprint)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenRouterReviewClient.requestBody(contextual)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as? [String: Any])
        XCTAssertEqual((input["campaign_context"] as? [String: Any])?["text"] as? String, pledge)
        XCTAssertNil(input["rule_result"])
    }
}
