import XCTest
@testable import ResetRadar

final class TimeResolverTests: XCTestCase {
    private let resolver = TimeResolver()
    private let iso = ISO8601DateFormatter()

    func testSummerPT() {
        assertExact("Reset on September 9, 2026 at 14:00 PT.", equals: "2026-09-09T21:00:00Z")
    }

    func testOctoberEODPSTHasADeadline() {
        let published = iso.date(from: "2026-10-13T01:03:59Z")!
        let result = resolver.resolve("Global reset landing by EOD PST time. Enjoy", publishedAt: published)
        XCTAssertEqual(result, .deadline(iso.date(from: "2026-10-13T08:00:00Z")!, zone: "PST"))
    }

    func testEndOfDayVariantsUsePublicationDayAndStatedZone() {
        let published = iso.date(from: "2026-10-13T01:03:59Z")!
        for (zone, target, canonical) in [("PST", "2026-10-13T08:00:00Z", "PST"), ("PDT", "2026-10-13T07:00:00Z", "PDT"), ("PT", "2026-10-13T07:00:00Z", "PT"), ("Pacific Standard Time", "2026-10-13T08:00:00Z", "PST"), ("Pacific Time", "2026-10-13T07:00:00Z", "PT")] {
            for phrase in ["by EOD", "before the end of the day", "by end of day today"] {
                XCTAssertEqual(resolver.resolve("Global reset landing \(phrase) \(zone)", publishedAt: published),
                               .deadline(iso.date(from: target)!, zone: canonical))
            }
        }
    }

    func testTomorrowEODAndWinterSeasonalPacific() {
        let published = iso.date(from: "2026-12-13T01:03:59Z")!
        for zone in ["PST", "PT"] {
            XCTAssertEqual(resolver.resolve("Global reset by EOD tomorrow \(zone)", publishedAt: published),
                           .deadline(iso.date(from: "2026-12-14T08:00:00Z")!, zone: zone))
        }
    }

    func testEODAcrossDaylightSavingTransitionsUsesCalendarDays() {
        for (published, deadline) in [("2026-03-08T09:00:00Z", "2026-03-09T07:00:00Z"), ("2026-11-01T08:00:00Z", "2026-11-02T08:00:00Z")] {
            XCTAssertEqual(resolver.resolve("Reset by EOD PT", publishedAt: iso.date(from: published)),
                           .deadline(iso.date(from: deadline)!, zone: "PT"))
        }
    }

    func testEODWithoutRequiredContextOrWithUnsupportedDatesRemainsUnresolved() {
        let published = iso.date(from: "2026-10-13T01:03:59Z")!
        for text in ["Reset by EOD", "Reset by end of day", "Reset by EOD Monday PST", "Monday reset by EOD PST", "Reset next week by EOD PST", "Reset by EOD PST on October 20", "Reset by EOD PST on 10/20", "Reset tomorrow by EOD today PST", "Reset by EOD 5pm PST"] {
            guard case .unresolved = resolver.resolve(text, publishedAt: published, verifiedContextZone: "America/Los_Angeles") else {
                XCTFail("Do not guess a deadline for \(text)"); continue
            }
        }
        guard case .unresolved = resolver.resolve("Reset by EOD PST") else { return XCTFail("Publication date is required") }
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
