import Foundation

enum Resolution: Equatable {
    case exact(Date)
    case unresolved(String)
}

struct TimeResolver {
    private let locale = Locale(identifier: "en_US_POSIX")
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    func resolve(_ text: String, publishedAt: Date? = nil, verifiedContextZone: String? = nil) -> Resolution {
        if let result = resolveISO8601(text) { return result }
        if let result = resolveNamedDate(text, verifiedContextZone: verifiedContextZone) { return result }
        if let result = resolveTomorrow(text, publishedAt: publishedAt, verifiedContextZone: verifiedContextZone) { return result }
        if let result = resolveIANADate(text) { return result }
        return .unresolved("No unambiguous date, time, and zone")
    }

    private func resolveISO8601(_ text: String) -> Resolution? {
        let pattern = #"(?i)\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})"#
        guard let match = captures(pattern, in: text)?.first else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        if let date = fractional.date(from: match.uppercased()) ?? standard.date(from: match.uppercased()) { return .exact(date) }
        return .unresolved("Invalid ISO 8601 timestamp")
    }

    private func resolveNamedDate(_ text: String, verifiedContextZone: String?) -> Resolution? {
        let pattern = #"(?i)(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2}),\s*(\d{4})\s+at\s+(\d{1,2}):(\d{2})\s+(PT|PST|PDT)"#
        guard let values = captures(pattern, in: text), values.count == 7,
              let month = monthNumber(values[1]), let day = Int(values[2]), let year = Int(values[3]),
              let hour = Int(values[4]), let minute = Int(values[5]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let abbreviation = values[6].uppercased()
        if abbreviation == "PST", verifiedContextZone == losAngeles.identifier {
            let candidates = matchingInstants(year: year, month: month, day: day, hour: hour, minute: minute, zone: losAngeles)
            if let date = candidates.first, losAngeles.secondsFromGMT(for: date) != -28_800 {
                return .unresolved("PST conflicts with daylight time in America/Los_Angeles")
            }
        }
        let zone: TimeZone
        if abbreviation == "PST" { zone = TimeZone(secondsFromGMT: -28_800)! }
        else if abbreviation == "PDT" { zone = TimeZone(secondsFromGMT: -25_200)! }
        else { zone = losAngeles }
        let candidates = matchingInstants(year: year, month: month, day: day, hour: hour, minute: minute, zone: zone)
        return candidates.count == 1 ? .exact(candidates[0]) : .unresolved("Local time is missing or repeated")
    }

    private func resolveTomorrow(_ text: String, publishedAt: Date?, verifiedContextZone: String?) -> Resolution? {
        let pattern = #"(?i)tomorrow\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*(PT|PST|PDT)?"#
        guard let values = captures(pattern, in: text), values.count >= 4 else { return nil }
        guard let publishedAt, let verifiedContextZone, let zone = TimeZone(identifier: verifiedContextZone) else {
            return .unresolved("Relative date lacks a verified source time zone")
        }
        guard var hour = Int(values[1]), (1...12).contains(hour) else { return .unresolved("Invalid hour") }
        let minute = values.count > 2 ? (Int(values[2]) ?? 0) : 0
        guard (0...59).contains(minute) else { return .unresolved("Invalid minute") }
        let meridiem = values[3].lowercased()
        if meridiem == "pm" && hour < 12 { hour += 12 }
        if meridiem == "am" && hour == 12 { hour = 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let published = calendar.dateComponents([.year, .month, .day], from: publishedAt)
        guard let anchor = calendar.date(from: published), let tomorrow = calendar.date(byAdding: .day, value: 1, to: anchor) else {
            return .unresolved("Cannot resolve relative date")
        }
        let target = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        let candidates = matchingInstants(year: target.year!, month: target.month!, day: target.day!, hour: hour, minute: minute, zone: zone)
        return candidates.count == 1 ? .exact(candidates[0]) : .unresolved("Local time is missing or repeated")
    }

    private func resolveIANADate(_ text: String) -> Resolution? {
        let pattern = #"(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})\s+([A-Za-z_]+/[A-Za-z_]+)"#
        guard let values = captures(pattern, in: text), values.count == 7,
              let year = Int(values[1]), let month = Int(values[2]), let day = Int(values[3]),
              let hour = Int(values[4]), let minute = Int(values[5]),
              (0...23).contains(hour), (0...59).contains(minute),
              let zoneName = TimeZone.knownTimeZoneIdentifiers.first(where: { $0.caseInsensitiveCompare(values[6]) == .orderedSame }),
              let zone = TimeZone(identifier: zoneName) else { return nil }
        let candidates = matchingInstants(year: year, month: month, day: day, hour: hour, minute: minute, zone: zone)
        return candidates.count == 1 ? .exact(candidates[0]) : .unresolved("Local time is missing or repeated")
    }

    private func matchingInstants(year: Int, month: Int, day: Int, hour: Int, minute: Int, zone: TimeZone) -> [Date] {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = utc
        guard let nominalUTC = utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) else { return [] }
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = zone
        return stride(from: -16 * 60, through: 16 * 60, by: 15).compactMap { offset in
            let candidate = nominalUTC.addingTimeInterval(TimeInterval(offset * 60))
            let parts = localCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: candidate)
            return parts.year == year && parts.month == month && parts.day == day && parts.hour == hour && parts.minute == minute ? candidate : nil
        }
    }

    private func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }

    private func monthNumber(_ name: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = locale
        return formatter.monthSymbols.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }.map { $0 + 1 }
    }
}
