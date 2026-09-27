import Foundation

actor FeedClient {
    private let session: URLSession
    private let maximumBytes = 2_000_000

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(_ source: FeedSource, previous: SourceStatus?) async throws -> FeedBatch {
        var request = URLRequest(url: source.url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
        request.setValue("ResetRadar/0.3 (+https://github.com/tonyfenwick8814121/reset-radar-for-ChatGPT-Codex)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, application/rss+xml, application/atom+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        if let etag = previous?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = previous?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedError.invalidResponse }
        if http.statusCode == 304 {
            return FeedBatch(items: [], fetchedAt: Date(), etag: previous?.etag, lastModified: previous?.lastModified, notModified: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedError.http(http.statusCode, retryAfter: Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
        }
        guard data.count <= maximumBytes else { throw FeedError.oversized }
        let items = try source.id == "codex-reset-json" ? Self.parsePublicFeed(data) : XMLFeedParser().parse(data)
        return FeedBatch(
            items: items,
            fetchedAt: Date(),
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            notModified: false
        )
    }

    // Read original posts only; relay-generated event classifications are not evidence.
    static func parsePublicFeed(_ data: Data) throws -> [FeedItem] {
        struct PublicFeed: Decodable {
            struct Post: Decodable { let id: String; let url: URL; let text: String; let at: String }
            let stale: Bool
            let tweets: [Post]
        }
        let feed = try JSONDecoder().decode(PublicFeed.self, from: data)
        guard !feed.stale else { throw FeedError.invalidResponse }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return try feed.tweets.map { post in
            guard let date = fractional.date(from: post.at) ?? plain.date(from: post.at) else { throw FeedError.invalidResponse }
            return FeedItem(id: post.id, title: "", body: post.text, url: post.url, publishedAt: date)
        }
    }

    private static func retryDelay(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
