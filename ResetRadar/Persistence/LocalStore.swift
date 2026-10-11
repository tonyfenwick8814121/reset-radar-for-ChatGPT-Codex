import Foundation

struct StoreLoadResult<Value: Sendable>: Sendable {
    let value: Value
    let issue: String?
}

actor LocalStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = support.appendingPathComponent("ResetRadar", isDirectory: true)
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadEvents() -> [ResetEvent] { loadEventsResult().value }
    func loadStatuses() -> [SourceStatus] { loadStatusesResult().value }
    func loadPreferences() -> UserPreferences { loadPreferencesResult().value }
    func loadEventsResult() -> StoreLoadResult<[ResetEvent]> { loadResult([ResetEvent].self, from: "events.json", fallback: []) }
    func loadStatusesResult() -> StoreLoadResult<[SourceStatus]> { loadResult([SourceStatus].self, from: "source-status.json", fallback: []) }
    func loadPreferencesResult() -> StoreLoadResult<UserPreferences> { loadResult(UserPreferences.self, from: "preferences.json", fallback: .defaults) }

    func saveEvents(_ events: [ResetEvent]) throws { try save(events, to: "events.json") }
    func saveStatuses(_ statuses: [SourceStatus]) throws { try save(statuses, to: "source-status.json") }
    func savePreferences(_ preferences: UserPreferences) throws { try save(preferences, to: "preferences.json") }
    func loadAIReviewResult() -> StoreLoadResult<AIReviewState> { loadResult(AIReviewState.self, from: "ai-review.json", fallback: AIReviewState()) }
    func saveAIReview(_ state: AIReviewState) throws { try save(state, to: "ai-review.json") }

    private func loadResult<T: Decodable & Sendable>(_ type: T.Type, from name: String, fallback: T) -> StoreLoadResult<T> {
        let url = directory.appendingPathComponent(name)
        let backup = directory.appendingPathComponent(name + ".backup")
        let primaryExists = FileManager.default.fileExists(atPath: url.path)
        if let data = try? Data(contentsOf: url), let value = try? decoder.decode(type, from: data) {
            return StoreLoadResult(value: value, issue: nil)
        }
        if let data = try? Data(contentsOf: backup), let value = try? decoder.decode(type, from: data) {
            return StoreLoadResult(value: value, issue: "Recovered \(name) from the last valid backup")
        }
        return StoreLoadResult(value: fallback, issue: primaryExists ? "Could not read \(name); using safe defaults" : nil)
    }

    private func save<T: Codable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let backup = directory.appendingPathComponent(name + ".backup")
        let data = try encoder.encode(value)
        if let existing = try? Data(contentsOf: url), (try? decoder.decode(T.self, from: existing)) != nil {
            try existing.write(to: backup, options: [.atomic])
        }
        try data.write(to: url, options: [.atomic])
    }
}
