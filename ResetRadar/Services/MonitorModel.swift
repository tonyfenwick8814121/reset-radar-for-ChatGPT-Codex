import AppKit
import Foundation

@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var events: [ResetEvent] = []
    @Published private(set) var statuses: [SourceStatus] = []
    @Published private(set) var isRefreshing = false
    @Published var preferences: UserPreferences = .defaults
    @Published private(set) var launchAtLoginMessage: String?
    @Published private(set) var storageMessage: String?

    private let store: LocalStore
    private let client: FeedClient
    private let scheduler: any ReminderScheduling
    private let classifier = AnnouncementClassifier()
    private let reconciler = EventReconciler()
    private var pollTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    var onNewActionableEvent: ((ResetEvent) -> Void)?
    var onPreferencesChanged: ((UserPreferences) -> Void)?

    init(store: LocalStore = LocalStore(), client: FeedClient = FeedClient(), scheduler: any ReminderScheduling = ReminderScheduler.shared) {
        self.store = store
        self.client = client
        self.scheduler = scheduler
    }

    var activeEvent: ResetEvent? {
        Self.selectActiveEvent(events, now: Date())
    }

    static func selectActiveEvent(_ events: [ResetEvent], now: Date) -> ResetEvent? {
        let events = events.filter { $0.isConfirmedOpportunity }
        let future = events.filter { event in
            event.kind == .automaticReset && event.state == .scheduled && event.targetAt.map { $0 > now } == true
        }.sorted { ($0.targetAt ?? .distantFuture) < ($1.targetAt ?? .distantFuture) }
        if let next = future.first { return next }
        let recentlyDue = events.filter { event in
            guard let target = event.targetAt else { return false }
            return event.kind == .automaticReset && (event.state == .dueUnconfirmed || event.state == .scheduled) && target <= now && target >= now.addingTimeInterval(-86_400)
        }.sorted { ($0.targetAt ?? .distantPast) > ($1.targetAt ?? .distantPast) }
        if let due = recentlyDue.first { return due }
        let validGrants = events.filter {
            $0.kind == .bankedResetGrant &&
            ($0.state == .available || $0.state == .unresolved) &&
            ($0.expiresAt.map { $0 > now } ??
             Self.isFreshUndated($0, now: now))
        }
            .sorted { $0.updatedAt > $1.updatedAt }
        if let grant = validGrants.first { return grant }
        return events.filter {
            $0.kind == .lead &&
            $0.confirmedAnnouncement &&
            $0.state == .unresolved &&
            Self.isFreshUndated($0, now: now)
        }.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    static func isFreshUndated(_ event: ResetEvent, now: Date) -> Bool {
        guard let published = event.bestEvidence?.publishedAt else { return false }
        return published >= event.firstSeenAt.addingTimeInterval(-86_400) &&
            published <= now.addingTimeInterval(300) && event.firstSeenAt.addingTimeInterval(86_400) > now
    }

    @discardableResult
    static func advanceLifecycle(_ events: inout [ResetEvent], now: Date) -> Bool {
        var changed = false
        for index in events.indices {
            if events[index].countdownAt == nil,
               [.available, .unresolved].contains(events[index].state),
               !Self.isFreshUndated(events[index], now: now),
               !(events[index].reviewUntil.map { $0 > now } ?? false) {
                events[index].state = .archived
                events[index].updatedAt = now
                changed = true
            }
            if events[index].kind == .automaticReset,
               let target = events[index].targetAt {
                if events[index].state == .scheduled && target <= now {
                    events[index].state = .dueUnconfirmed
                    events[index].updatedAt = now
                    changed = true
                }
                if events[index].state == .dueUnconfirmed && target < now.addingTimeInterval(-86_400) {
                    events[index].state = .archived
                    events[index].updatedAt = now
                    changed = true
                }
            }
            if events[index].kind == .bankedResetGrant,
               (events[index].state == .available || events[index].state == .unresolved),
               let expiry = events[index].expiresAt,
               expiry <= now {
                events[index].state = .expired
                events[index].updatedAt = now
                changed = true
            }
        }
        return changed
    }

    var mostRecentAttempt: Date? { statuses.compactMap(\.lastAttemptAt).max() }
    var mostRecentSuccess: Date? { statuses.compactMap(\.lastTransportSuccessAt).max() }
    var failedSourceCount: Int { statuses.filter { $0.result == .failed }.count }

    @discardableResult
    func start(loadPreview: Bool = false) -> Task<Void, Never> {
        Task {
            async let savedEvents = store.loadEventsResult()
            async let savedStatuses = store.loadStatusesResult()
            async let savedPreferences = store.loadPreferencesResult()
            let loadedEvents = await savedEvents
            let loadedStatuses = await savedStatuses
            let loadedPreferences = await savedPreferences
            events = reclassifySavedEvents(loadedEvents.value)
            statuses = loadedStatuses.value
            preferences = loadedPreferences.value
            storageMessage = [loadedEvents.issue, loadedStatuses.issue, loadedPreferences.issue].compactMap { $0 }.joined(separator: " · ")
            if storageMessage?.isEmpty == true { storageMessage = nil }
            preferences.launchAtLogin = LaunchAtLoginService.isEnabled
            _ = Self.advanceLifecycle(&events, now: Date())
            if loadPreview { addPreviewEvent() }
            await refresh(force: false)
            await scheduler.reconcile(events: events, preferences: preferences, now: Date())
            beginPolling()
            beginLifecycleMonitoring()
            onPreferencesChanged?(preferences)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }

    func refresh(force: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let eventsBeforeCheck = events

        for source in FeedSource.defaults {
            let previous = status(for: source)
            if let cooldown = previous.cooldownUntil, cooldown > Date() { continue }
            if !force, let next = previous.nextCheckAt, next > Date() { continue }
            updateStatus(source) { status in
                status.result = .checking
                status.lastAttemptAt = Date()
                status.message = nil
            }
            do {
                let batch = try await client.fetch(source, previous: previous)
                updateStatus(source) { status in
                    status.result = .success
                    status.lastTransportSuccessAt = batch.fetchedAt
                    status.latestCoveredPublicationAt = batch.items.compactMap(\.freshnessDate).max() ?? status.latestCoveredPublicationAt
                    status.nextCheckAt = batch.fetchedAt.addingTimeInterval(checkInterval(for: source))
                    status.consecutiveFailures = 0
                    status.etag = batch.etag ?? status.etag
                    status.lastModified = batch.lastModified ?? status.lastModified
                    status.message = batch.notModified ? "304 · cached" : "\(batch.items.count) items"
                    status.itemCount = batch.notModified ? status.itemCount : batch.items.count
                    status.cooldownUntil = nil
                }
                guard !batch.notModified else { continue }
                for item in batch.items.sorted(by: { ($0.freshnessDate ?? .distantPast) < ($1.freshnessDate ?? .distantPast) }) {
                    for var candidate in classifier.classifyAll(item, source: source, fetchedAt: batch.fetchedAt).reversed() {
                        if candidate.confirmedAnnouncement && (candidate.state == .announcedComplete || candidate.state == .cancelled) {
                            _ = associateTerminalAnnouncement(candidate)
                        } else if let relatedID = relatedAnnouncementID(candidate) {
                            candidate.relatedPostIDs = [candidate.id]
                            candidate.id = relatedID
                        }
                        _ = reconciler.merge(candidate, into: &events)
                    }
                }
            } catch {
                updateStatus(source) { status in
                    status.result = .failed
                    status.consecutiveFailures += 1
                    let now = Date()
                    let normalBackoff = backoff(for: status.consecutiveFailures, base: checkInterval(for: source))
                    if case FeedError.http(let code, let retryAfter) = error, code == 429 || code == 403 {
                        let delay = max(normalBackoff, retryAfter ?? (code == 403 ? 86_400 : normalBackoff))
                        status.cooldownUntil = now.addingTimeInterval(delay)
                        status.nextCheckAt = status.cooldownUntil
                    } else {
                        status.cooldownUntil = nil
                        status.nextCheckAt = now.addingTimeInterval(normalBackoff)
                    }
                    status.message = error.localizedDescription
                }
            }
        }
        _ = Self.advanceLifecycle(&events, now: Date())
        events = events.sorted { $0.updatedAt > $1.updatedAt }
        // Decide only after every source is merged: a later item may cancel an earlier one.
        let newOpportunities = events.filter { event in
            guard isActionable(event, now: Date()) else { return false }
            guard let previous = eventsBeforeCheck.first(where: { $0.id == event.id }) else { return true }
            return !isActionable(previous, now: Date()) ||
                previous.kind != event.kind || previous.timeMeaning != event.timeMeaning ||
                previous.announcementStage != event.announcementStage ||
                previous.targetAt != event.targetAt || previous.expiresAt != event.expiresAt ||
                previous.audience != event.audience || Set(previous.products) != Set(event.products)
        }
        if let opportunity = Self.selectActiveEvent(newOpportunities, now: Date()) {
            onNewActionableEvent?(opportunity)
        }
        do {
            try await store.saveEvents(events)
            try await store.saveStatuses(statuses)
        } catch {
            storageMessage = error.localizedDescription
        }
        await scheduler.reconcile(events: events, preferences: preferences, now: Date())
    }

    func checkInterval(for source: FeedSource) -> TimeInterval {
        TimeInterval(preferences.checkIntervalMinutes * 60)
    }

    func setCheckInterval(_ minutes: Int) {
        guard UserPreferences.checkIntervals.contains(minutes) else { return }
        preferences.checkIntervalMinutes = minutes
        for index in statuses.indices {
            // Changing cadence never bypasses a server cooldown.
            if statuses[index].cooldownUntil == nil {
                statuses[index].nextCheckAt = statuses[index].lastAttemptAt?.addingTimeInterval(TimeInterval(minutes * 60))
            }
        }
        preferencesDidChange()
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        preferences.alwaysOnTop = enabled
        preferencesDidChange()
        onPreferencesChanged?(preferences)
    }

    func setLocale(_ locale: AppLocale) {
        preferences.locale = locale
        preferencesDidChange(reschedule: true)
        onPreferencesChanged?(preferences)
    }

    func setTimeZone(_ identifier: String) {
        preferences.displayTimeZone = identifier
        preferencesDidChange()
    }

    func setExpanded(_ expanded: Bool) {
        preferences.detailsExpanded = expanded
        preferencesDidChange()
    }

    func setAudioEnabled(_ enabled: Bool) {
        preferences.audioEnabled = enabled
        preferencesDidChange(reschedule: true)
    }

    func setVolume(_ volume: Double) {
        preferences.volume = min(max(volume, 0), 1)
        preferencesDidChange()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            preferences.launchAtLogin = LaunchAtLoginService.isEnabled
            launchAtLoginMessage = nil
            preferencesDidChange()
        } catch {
            preferences.launchAtLogin = LaunchAtLoginService.isEnabled
            launchAtLoginMessage = error.localizedDescription
        }
    }

    func setWindowMode(_ mode: String) {
        preferences.windowMode = mode
        preferencesDidChange()
    }

    func setWindowFrame(_ frame: WindowFrame, mode: String) {
        if mode == "mini" { preferences.miniWindowFrame = frame }
        else { preferences.mainWindowFrame = frame }
        persistPreferences()
    }

    func markEvent(_ id: String, as state: EventState) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].revision += 1
        events[index].state = state
        events[index].updatedAt = Date()
        let snapshot = events
        let currentPreferences = preferences
        Task {
            await persistEvents(snapshot)
            await scheduler.reconcile(events: snapshot, preferences: currentPreferences, now: Date())
        }
    }

    func addManualEvent(_ draft: ManualEntryDraft) {
        let now = Date()
        let isGrant = draft.kind == .bankedResetGrant
        let event = ResetEvent(
            id: "manual-\(UUID().uuidString.lowercased())",
            revision: 1,
            kind: draft.kind,
            timeMeaning: isGrant ? (draft.date == nil ? .grantAvailability : .grantExpiry) : .automaticReset,
            state: isGrant ? (draft.date.map { $0 <= now } == true ? .expired : .available) : (draft.date.map { $0 > now } == true ? .scheduled : .unresolved),
            precision: draft.date == nil ? .unknown : .exact,
            title: isGrant ? "手动重置机会" : "手动重置预告",
            titleEN: isGrant ? "Manual reset opportunity" : "Manual reset announcement",
            targetAt: isGrant ? nil : draft.date,
            windowStart: nil,
            windowEnd: nil,
            expiresAt: isGrant ? draft.date : nil,
            products: [draft.product],
            audience: draft.audience,
            evidence: [Evidence(sourceID: "manual", itemID: UUID().uuidString, sourceKind: .manual, url: Self.firstWebURL(in: draft.text), publishedAt: now, fetchedAt: now, excerpt: String(draft.text.prefix(500)), contentHash: UUID().uuidString)],
            firstSeenAt: now,
            updatedAt: now
        )
        events.insert(event, at: 0)
        if isActionable(event, now: now) { onNewActionableEvent?(event) }
        let snapshot = events
        let currentPreferences = preferences
        Task {
            await persistEvents(snapshot)
            await scheduler.reconcile(events: snapshot, preferences: currentPreferences, now: now)
        }
    }

    func addPreviewEvent(seconds: TimeInterval = 3672) {
        let now = Date()
        let event = ResetEvent(
            id: "preview-event",
            revision: 1,
            kind: .automaticReset,
            timeMeaning: .automaticReset,
            state: .scheduled,
            precision: .exact,
            title: "额度重置预告",
            titleEN: "Quota reset announced",
            targetAt: now.addingTimeInterval(seconds),
            windowStart: nil,
            windowEnd: nil,
            expiresAt: nil,
            products: ["codex"],
            audience: "all",
            evidence: [Evidence(sourceID: "preview", itemID: "preview", sourceKind: .manual, url: nil, publishedAt: now, fetchedAt: now, excerpt: "Synthetic preview event", contentHash: "preview")],
            firstSeenAt: now,
            updatedAt: now
        )
        _ = reconciler.merge(event, into: &events)
        let snapshot = events
        Task { await persistEvents(snapshot) }
    }


    func clearPreviewEvent() {
        events.removeAll { $0.id == "preview-event" }
        let snapshot = events
        Task { await persistEvents(snapshot) }
    }

    func handleWake() async {
        await refresh(force: true)
        _ = Self.advanceLifecycle(&events, now: Date())
        await scheduler.reconcile(events: events, preferences: preferences, now: Date())
    }

    func cancelPendingReminders() async {
        await scheduler.cancelAll()
    }

    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.refresh(force: false)
            }
        }
    }

    private func beginLifecycleMonitoring() {
        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if Self.advanceLifecycle(&self.events, now: Date()) {
                    let snapshot = self.events
                    let currentPreferences = self.preferences
                    await self.persistEvents(snapshot)
                    await self.scheduler.reconcile(events: snapshot, preferences: currentPreferences, now: Date())
                }
            }
        }
    }

    private func status(for source: FeedSource) -> SourceStatus {
        statuses.first(where: { $0.sourceID == source.id }) ?? SourceStatus(
            sourceID: source.id,
            enabled: true,
            result: .notConnected,
            consecutiveFailures: 0
        )
    }

    private func updateStatus(_ source: FeedSource, mutate: (inout SourceStatus) -> Void) {
        var value = status(for: source)
        mutate(&value)
        if let index = statuses.firstIndex(where: { $0.sourceID == source.id }) { statuses[index] = value }
        else { statuses.append(value) }
    }

    private func persistPreferences() {
        let value = preferences
        Task {
            do {
                try await store.savePreferences(value)
            } catch {
                storageMessage = error.localizedDescription
            }
        }
    }

    private func persistEvents(_ snapshot: [ResetEvent]) async {
        do {
            try await store.saveEvents(snapshot)
        } catch {
            storageMessage = error.localizedDescription
        }
    }

    private func preferencesDidChange(reschedule: Bool = false) {
        persistPreferences()
        if reschedule {
            let snapshot = events
            let currentPreferences = preferences
            Task { await scheduler.reconcile(events: snapshot, preferences: currentPreferences, now: Date()) }
        }
    }

    func isActionable(_ event: ResetEvent, now: Date) -> Bool {
        guard event.isConfirmedOpportunity else { return false }
        if event.kind == .lead && event.confirmedAnnouncement && event.state == .unresolved {
            return Self.isFreshUndated(event, now: now)
        }
        if event.kind == .automaticReset {
            return event.state == .scheduled && event.precision == .exact &&
                event.targetAt.map { $0 > now } == true
        }
        if event.kind == .bankedResetGrant {
            guard event.state == .available || (event.state == .unresolved && event.confirmedAnnouncement) else { return false }
            if let expiry = event.expiresAt { return expiry > now }
            return Self.isFreshUndated(event, now: now)
        }
        return false
    }

    private func associateTerminalAnnouncement(_ announcement: ResetEvent) -> ResetEvent? {
        let matching = events.indices.filter { index in
            let event = events[index]
            // Different clauses of the same post are distinct claims, not a completion update.
            if event.id != announcement.id && event.evidence.contains(where: { first in
                announcement.evidence.contains { second in first.url != nil && first.url == second.url }
            }) { return false }
            if announcement.state == .announcedComplete && event.targetAt == nil && (event.matchedText?.contains("next week") == true) { return false }
            let matchingType = announcement.kind == .bankedResetGrant
                ? event.kind == .bankedResetGrant
                : (event.kind == .automaticReset || event.kind == .lead)
            return matchingType &&
                (event.state == .scheduled || event.state == .dueUnconfirmed || event.state == .unresolved || event.state == .available) &&
                event.bestEvidence?.publishedAt.map { date in
                    guard let terminalDate = announcement.bestEvidence?.publishedAt else { return false }
                    return terminalDate >= date && terminalDate.timeIntervalSince(date) <= 86_400
                } == true &&
                event.confirmedAnnouncement &&
                (announcement.state == .cancelled || event.targetAt.map { $0 <= (announcement.bestEvidence?.publishedAt ?? .distantPast) } != false) &&
                compatibleProducts(event, announcement) && samePublisher(event, announcement)
        }
        guard matching.count == 1, let index = matching.first, events[index].id != announcement.id else { return nil }
        events[index].revision += 1
        events[index].state = announcement.state
        events[index].updatedAt = announcement.updatedAt
        for evidence in announcement.evidence where !events[index].evidence.contains(evidence) {
            events[index].evidence.append(evidence)
        }
        return events[index]
    }

    // Re-evaluate old evidence silently on upgrade; never undo a user's used/dismissed choice.
    private func reclassifySavedEvents(_ saved: [ResetEvent]) -> [ResetEvent] {
        saved.map { old in
            guard old.classifierVersion != AnnouncementClassifier.version,
                  !old.evidence.contains(where: { $0.sourceKind == .manual }),
                  ![.used, .dismissed, .archived].contains(old.state) else { return old }
            let candidates = old.evidence.compactMap { evidence -> ResetEvent? in
                guard let source = FeedSource.defaults.first(where: { $0.id == evidence.sourceID }) else { return nil }
                return classifier.classify(FeedItem(id: evidence.itemID, title: "", body: evidence.excerpt,
                    url: evidence.url, publishedAt: evidence.publishedAt), source: source, fetchedAt: old.firstSeenAt)
            }.sorted { ($0.evidenceRank ?? 0) > ($1.evidenceRank ?? 0) }
            guard var revised = candidates.first else {
                var hidden = old
                hidden.confirmedAnnouncement = false
                hidden.classifierVersion = AnnouncementClassifier.version
                return hidden
            }
            revised.id = old.id
            revised.firstSeenAt = old.firstSeenAt
            revised.updatedAt = old.updatedAt
            revised.revision = old.revision
            revised.evidence = old.evidence
            if old.state == .cancelled || (old.state == .announcedComplete && old.kind != .bankedResetGrant) { revised.state = old.state }
            return revised
        }
    }

    private func compatibleProducts(_ a: ResetEvent, _ b: ResetEvent) -> Bool {
        !Set(a.products).isDisjoint(with: b.products) || a.products == ["unspecified"] || b.products == ["unspecified"]
    }

    private func samePublisher(_ a: ResetEvent, _ b: ResetEvent) -> Bool {
        func author(_ event: ResetEvent) -> String? {
            event.evidence.compactMap { evidence -> String? in
                guard let url = evidence.url, ["x.com", "twitter.com"].contains(url.host?.lowercased() ?? ""),
                      url.pathComponents.count > 2, url.pathComponents[2] == "status" else { return nil }
                return url.pathComponents[1].lowercased()
            }.first
        }
        guard let first = author(a), let second = author(b) else { return false }
        return first == second
    }

    private func relatedAnnouncementID(_ incoming: ResetEvent) -> String? {
        if let known = events.first(where: { ($0.relatedPostIDs ?? []).contains(incoming.id) }) { return known.id }
        guard incoming.confirmedAnnouncement, !events.contains(where: { $0.id == incoming.id }) else { return nil }
        let text = incoming.matchedText ?? ""
        // Explicit additional resets are independent opportunities, not updates.
        guard text.range(of: #"\b(?:another|again|more resets)\b"#, options: .regularExpression) == nil else { return nil }
        let candidates = events.filter { prior in
            guard prior.confirmedAnnouncement, samePublisher(prior, incoming), compatibleProducts(prior, incoming),
                  let published = incoming.bestEvidence?.publishedAt, let previous = prior.bestEvidence?.publishedAt,
                  published >= previous, published.timeIntervalSince(previous) <= 86_400,
                  ![.used, .dismissed, .cancelled, .announcedComplete, .archived].contains(prior.state) else { return false }
            if prior.kind == incoming.kind && prior.matchedText == incoming.matchedText { return true }
            if let target = prior.targetAt, target == incoming.targetAt { return true }
            let advancesGrant = incoming.kind == .bankedResetGrant &&
                (prior.kind == .lead || (prior.kind == .bankedResetGrant && prior.state == .unresolved)) &&
                ["rollingOut", "available"].contains(incoming.announcementStage ?? "")
            return advancesGrant
        }
        return candidates.count == 1 ? candidates.first?.id : nil
    }

    private func backoff(for failures: Int, base _: TimeInterval) -> TimeInterval {
        let schedule: [TimeInterval] = [60, 120, 300, 600, 900]
        return schedule[min(max(1, failures), schedule.count) - 1]
    }

    private static func firstWebURL(in text: String) -> URL? {
        guard let range = text.range(of: #"https?://[^\s]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)")))
    }
}

private extension SourceStatus {
    init(sourceID: String, enabled: Bool, result: SourceResult, consecutiveFailures: Int) {
        self.init(
            sourceID: sourceID,
            enabled: enabled,
            lastAttemptAt: nil,
            lastTransportSuccessAt: nil,
            latestCoveredPublicationAt: nil,
            nextCheckAt: nil,
            result: result,
            message: nil,
            consecutiveFailures: consecutiveFailures,
            etag: nil,
            lastModified: nil
        )
    }
}
