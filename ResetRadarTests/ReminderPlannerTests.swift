import XCTest
@testable import ResetRadar

final class ReminderPlannerTests: XCTestCase {
    func testOnlyFutureThresholdsAreScheduled() {
        let now = Date(timeIntervalSince1970: 10_000)
        let target = now.addingTimeInterval(180)
        let reminders = ReminderPlanner.plan(target: target, offsets: [1800, 300, 60], now: now)
        XCTAssertEqual(reminders.map(\.offset), [60, 0])
        XCTAssertEqual(reminders.last?.fireDate, target)
    }

    func testDueTargetProducesNoFutureRequest() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(ReminderPlanner.plan(target: now, offsets: [300], now: now).isEmpty)
    }

    func testDeadlineReminderDescribesACutoffNotAnExactReset() throws {
        let source = try XCTUnwrap(FeedSource.defaults.first { $0.id == "codex-reset-json" })
        let now = Date()
        let item = FeedItem(id: "10", title: "", body: "Global reset by EOD PST", url: URL(string: "https://x.com/thsottiaux/status/10"), publishedAt: now)
        let event = try XCTUnwrap(AnnouncementClassifier().classify(item, source: source, fetchedAt: now))
        XCTAssertEqual(ReminderScheduler.body(event: event, offset: 300, locale: .zhHans), "距公告预计截止还有 5 分钟，可能提前完成。")
        XCTAssertEqual(ReminderScheduler.body(event: event, offset: 0, locale: .zhHans), "已到公告预计截止时间，重置完成仍待确认。")
        XCTAssertEqual(ReminderScheduler.body(event: event, offset: 300, locale: .en), "Estimated deadline in 5 minutes; the reset may finish earlier.")
        XCTAssertTrue(ReminderScheduler.body(event: event, offset: 0, locale: .en).contains("unconfirmed"))
    }
}
