import Foundation

enum ResetKind: String, Codable, Sendable {
    case automaticReset
    case bankedResetGrant
    case limitChange
    case lead
}

enum EventState: String, Codable, Sendable {
    case unresolved
    case scheduled
    case dueUnconfirmed
    case announcedComplete
    case available
    case expired
    case used
    case dismissed
    case cancelled
    case archived
}

enum TimeMeaning: String, Codable, Sendable {
    case automaticReset
    case grantAvailability
    case grantExpiry
    case unknown
}

enum TimePrecision: String, Codable, Sendable {
    case exact
    case approximate
    case range
    case dateOnly
    case unknown
}

enum SourceKind: String, Codable, Sendable {
    case communityFeed
    case officialFeed
    case manual
}

struct Evidence: Codable, Hashable, Sendable {
    let sourceID: String
    let itemID: String
    let sourceKind: SourceKind
    let url: URL?
    let publishedAt: Date?
    let fetchedAt: Date
    let excerpt: String
    let contentHash: String
}

struct ResetEvent: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var revision: Int
    var kind: ResetKind
    var timeMeaning: TimeMeaning = .unknown
    var confirmedAnnouncement: Bool = false
    var state: EventState
    var precision: TimePrecision
    var title: String
    var titleEN: String
    var targetAt: Date?
    var windowStart: Date?
    var windowEnd: Date?
    var expiresAt: Date?
    var products: [String]
    var audience: String
    var evidence: [Evidence]
    var firstSeenAt: Date
    var updatedAt: Date

    var relatedPostIDs: [String]? = nil
    var classifierVersion: Int? = nil
    var evidenceRank: Int? = nil
    var announcementStage: String? = nil
    var matchedText: String? = nil
    var reviewUntil: Date? = nil

    var isConfirmedOpportunity: Bool {
        confirmedAnnouncement || evidence.contains { $0.sourceKind == .manual }
    }

    var bestEvidence: Evidence? {
        evidence.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }.first
    }

    var countdownAt: Date? {
        kind == .bankedResetGrant ? expiresAt : targetAt
    }
}

extension ResetEvent {
    enum CodingKeys: String, CodingKey {
        case relatedPostIDs, classifierVersion, evidenceRank, announcementStage, matchedText, reviewUntil
        case id, revision, kind, timeMeaning, state, precision, title, titleEN, targetAt
        case windowStart, windowEnd, expiresAt, products, audience, evidence, firstSeenAt, updatedAt, confirmedAnnouncement
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        confirmedAnnouncement = try values.decodeIfPresent(Bool.self, forKey: .confirmedAnnouncement) ?? false
        relatedPostIDs = try values.decodeIfPresent([String].self, forKey: .relatedPostIDs)
        classifierVersion = try values.decodeIfPresent(Int.self, forKey: .classifierVersion)
        evidenceRank = try values.decodeIfPresent(Int.self, forKey: .evidenceRank)
        announcementStage = try values.decodeIfPresent(String.self, forKey: .announcementStage)
        matchedText = try values.decodeIfPresent(String.self, forKey: .matchedText)
        reviewUntil = try values.decodeIfPresent(Date.self, forKey: .reviewUntil)
        id = try values.decode(String.self, forKey: .id)
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        kind = try values.decode(ResetKind.self, forKey: .kind)
        state = try values.decode(EventState.self, forKey: .state)
        precision = try values.decode(TimePrecision.self, forKey: .precision)
        title = try values.decode(String.self, forKey: .title)
        titleEN = try values.decode(String.self, forKey: .titleEN)
        targetAt = try values.decodeIfPresent(Date.self, forKey: .targetAt)
        windowStart = try values.decodeIfPresent(Date.self, forKey: .windowStart)
        windowEnd = try values.decodeIfPresent(Date.self, forKey: .windowEnd)
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        products = try values.decodeIfPresent([String].self, forKey: .products) ?? []
        audience = try values.decodeIfPresent(String.self, forKey: .audience) ?? "unknown"
        evidence = try values.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
        firstSeenAt = try values.decode(Date.self, forKey: .firstSeenAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        timeMeaning = try values.decodeIfPresent(TimeMeaning.self, forKey: .timeMeaning) ?? {
            if kind == .bankedResetGrant { return expiresAt == nil ? .grantAvailability : .grantExpiry }
            return kind == .automaticReset ? .automaticReset : .unknown
        }()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(confirmedAnnouncement, forKey: .confirmedAnnouncement)
        try values.encodeIfPresent(relatedPostIDs, forKey: .relatedPostIDs)
        try values.encodeIfPresent(classifierVersion, forKey: .classifierVersion)
        try values.encodeIfPresent(evidenceRank, forKey: .evidenceRank)
        try values.encodeIfPresent(announcementStage, forKey: .announcementStage)
        try values.encodeIfPresent(matchedText, forKey: .matchedText)
        try values.encodeIfPresent(reviewUntil, forKey: .reviewUntil)
        try values.encode(id, forKey: .id)
        try values.encode(revision, forKey: .revision)
        try values.encode(kind, forKey: .kind)
        try values.encode(timeMeaning, forKey: .timeMeaning)
        try values.encode(state, forKey: .state)
        try values.encode(precision, forKey: .precision)
        try values.encode(title, forKey: .title)
        try values.encode(titleEN, forKey: .titleEN)
        try values.encodeIfPresent(targetAt, forKey: .targetAt)
        try values.encodeIfPresent(windowStart, forKey: .windowStart)
        try values.encodeIfPresent(windowEnd, forKey: .windowEnd)
        try values.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try values.encode(products, forKey: .products)
        try values.encode(audience, forKey: .audience)
        try values.encode(evidence, forKey: .evidence)
        try values.encode(firstSeenAt, forKey: .firstSeenAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

enum SourceResult: String, Codable, Sendable {
    case notConnected
    case checking
    case success
    case partial
    case failed
    case stale
}

struct SourceStatus: Identifiable, Codable, Hashable, Sendable {
    var id: String { sourceID }
    let sourceID: String
    var enabled: Bool
    var lastAttemptAt: Date?
    var lastTransportSuccessAt: Date?
    var latestCoveredPublicationAt: Date?
    var nextCheckAt: Date?
    var result: SourceResult
    var message: String?
    var consecutiveFailures: Int
    var etag: String?
    var lastModified: String?
    var itemCount: Int? = nil
    var cooldownUntil: Date? = nil
}

enum AppLocale: String, Codable, CaseIterable, Sendable {
    case zhHans = "zh-Hans"
    case en
}

struct WindowFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct UserPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion = currentSchemaVersion
    var locale: AppLocale = .zhHans
    var displayTimeZone = "Asia/Shanghai"
    var audioEnabled = true
    var volume = 0.65
    var launchAtLogin = false
    var reminderOffsets: [TimeInterval] = [1800, 300]
    var detailsExpanded = false
    var windowMode = "main"
    var mainWindowFrame: WindowFrame?
    var miniWindowFrame: WindowFrame?
    var alwaysOnTop = false
    var checkIntervalMinutes = 10
    static let checkIntervals = [1, 5, 10, 15, 20]

    static let defaults = UserPreferences()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, locale, displayTimeZone, audioEnabled, volume, launchAtLogin
        case reminderOffsets, detailsExpanded, windowMode, mainWindowFrame, miniWindowFrame, alwaysOnTop, checkIntervalMinutes
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard storedVersion <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values, debugDescription: "Unsupported preference schema \(storedVersion)")
        }
        locale = try values.decodeIfPresent(AppLocale.self, forKey: .locale) ?? .zhHans
        displayTimeZone = try values.decodeIfPresent(String.self, forKey: .displayTimeZone) ?? "Asia/Shanghai"
        audioEnabled = try values.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? true
        volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? 0.65
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        reminderOffsets = try values.decodeIfPresent([TimeInterval].self, forKey: .reminderOffsets) ?? [1800, 300]
        detailsExpanded = try values.decodeIfPresent(Bool.self, forKey: .detailsExpanded) ?? false
        windowMode = try values.decodeIfPresent(String.self, forKey: .windowMode) ?? "main"
        mainWindowFrame = try values.decodeIfPresent(WindowFrame.self, forKey: .mainWindowFrame)
        miniWindowFrame = try values.decodeIfPresent(WindowFrame.self, forKey: .miniWindowFrame)
        alwaysOnTop = try values.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? false
        let minutes = try values.decodeIfPresent(Int.self, forKey: .checkIntervalMinutes) ?? 10
        checkIntervalMinutes = Self.checkIntervals.contains(minutes) ? minutes : 10
        schemaVersion = Self.currentSchemaVersion
    }
}

struct ManualEntryDraft: Sendable {
    var text: String
    var kind: ResetKind
    var date: Date?
    var product: String
    var audience: String
}

struct FeedItem: Hashable, Sendable {
    let id: String
    let title: String
    let body: String
    let url: URL?
    let publishedAt: Date?
    let updatedAt: Date?

    var freshnessDate: Date? { publishedAt ?? updatedAt }

    init(id: String, title: String, body: String, url: URL?, publishedAt: Date?, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.url = url
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
    }
}

struct FeedBatch: Sendable {
    let items: [FeedItem]
    let fetchedAt: Date
    let etag: String?
    let lastModified: String?
    let notModified: Bool
}

enum FeedError: LocalizedError {
    case invalidResponse
    case http(Int, retryAfter: TimeInterval?)
    case oversized
    case malformedXML

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response"
        case .http(let code, _): return "HTTP \(code)"
        case .oversized: return "Feed is too large"
        case .malformedXML: return "Malformed RSS/Atom"
        }
    }
}
