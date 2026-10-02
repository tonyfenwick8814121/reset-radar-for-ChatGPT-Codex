import XCTest
@testable import ResetRadar

final class TimeResolverTests: XCTestCase {
    private let resolver = TimeResolver()
    private let iso = ISO8601DateFormatter()

    func testSummerPT() {
        assertExact("Reset on September 9, 2026 at 14:00 PT.", equals: "2026-09-09T21:00:00Z")
    }

    func testWinterPT() {
        assertExact("Reset on December 9, 2026 at 14:00 PT.", equals: "2026-12-09T22:00:00Z")
    }

    func testTomorrowUsesPublishedDateInSourceZone() {
        let published = iso.date(from: "2026-09-09T06:30:00Z")!
        let result = resolver.resolve("Reset tomorrow at 2pm PT.", publishedAt: published, verifiedContextZone: "America/Los_Angeles")
        XCTAssertEqual(result, .exact(iso.date(from: "2026-09-09T21:00:00Z")!))
    }

    func testExplicitPSTKeepsItsFixedOffsetInSummer() {
        let result = resolver.resolve("Reset on September 9, 2026 at 14:00 PST.", verifiedContextZone: "America/Los_Angeles")
        XCTAssertEqual(result, .exact(iso.date(from: "2026-09-09T22:00:00Z")!))
    }

    func testTomorrowPacificZonesWithAndWithoutAt() {
        let published = iso.date(from: "2026-10-02T02:14:51Z")!
        for (abbreviation, target) in [("PST", "2026-10-02T18:00:00Z"), ("PDT", "2026-10-02T17:00:00Z"), ("PT", "2026-10-02T17:00:00Z")] {
            for connector in ["", "at "] {
                let text = "Global reset landing tomorrow \(connector)10am \(abbreviation) for all paid ChatGPT accounts."
                for context in [nil, "America/Los_Angeles"] as [String?] {
                    XCTAssertEqual(resolver.resolve(text, publishedAt: published, verifiedContextZone: context),
                                   .exact(iso.date(from: target)!), text)
                }
            }
        }
    }

    func testTomorrowFixedOffsetsAndSeasonalPTInWinter() {
        let published = iso.date(from: "2026-12-02T02:14:51Z")!
        for (zone, target) in [("PST", "2026-12-02T18:00:00Z"), ("PDT", "2026-12-02T17:00:00Z"), ("PT", "2026-12-02T18:00:00Z")] {
            XCTAssertEqual(resolver.resolve("Reset tomorrow at 10am \(zone)", publishedAt: published),
                           .exact(iso.date(from: target)!))
        }
    }

    func testTomorrowWithoutPublicationDateIsUnresolved() {
        guard case .unresolved = resolver.resolve("Reset tomorrow 10am PST") else { return XCTFail("Publication date is required") }
    }

    func testRelativeDateWithoutZoneIsUnresolved() {
        let result = resolver.resolve("Reset tomorrow at 2pm.", publishedAt: iso.date(from: "2026-09-09T06:30:00Z"))
        guard case .unresolved = result else { return XCTFail("Expected unresolved") }
    }

    func testDSTGapAndRepeatAreUnresolved() {
        for value in ["2026-03-08 02:30 America/Los_Angeles", "2026-11-01 01:30 America/Los_Angeles"] {
            guard case .unresolved = resolver.resolve(value) else { return XCTFail("Expected unresolved for \(value)") }
        }
    }

    func testISO8601OffsetTimestampIsExact() {
        XCTAssertEqual(resolver.resolve("Codex reset 2026-09-09T14:00:00-07:00"), .exact(iso.date(from: "2026-09-09T21:00:00Z")!))
    }

    func testInvalidMeridiemHourIsUnresolved() {
        let result = resolver.resolve("Reset tomorrow at 14pm PT", publishedAt: iso.date(from: "2026-09-09T12:00:00Z"), verifiedContextZone: "America/Los_Angeles")
        guard case .unresolved = result else { return XCTFail("Expected invalid 14pm to remain unresolved") }
    }

    private func assertExact(_ input: String, equals expected: String) {
        XCTAssertEqual(resolver.resolve(input), .exact(iso.date(from: expected)!))
    }
}
