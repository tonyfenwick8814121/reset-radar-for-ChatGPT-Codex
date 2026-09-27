import Foundation
import UserNotifications

protocol ReminderScheduling: Sendable {
    func reconcile(events: [ResetEvent], preferences: UserPreferences, now: Date) async
    func cancelAll() async
}

actor ReminderScheduler: ReminderScheduling {
    static let shared = ReminderScheduler()
    private let identifierPrefix = "reset-radar."

    func reconcile(events: [ResetEvent], preferences: UserPreferences, now: Date = Date()) async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let desired = desiredReminders(events: events, preferences: preferences, now: now)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let desiredIDs = Set(desired.map(\.identifier))
        let staleIDs = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) && !desiredIDs.contains($0) }
        if !staleIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: staleIDs) }
        guard !desired.isEmpty else { return }

        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let pendingIDs = Set(pending.map(\.identifier)).subtracting(staleIDs)
        for reminder in desired where !pendingIDs.contains(reminder.identifier) {
            let content = UNMutableNotificationContent()
            content.title = preferences.locale == .zhHans ? "归零 · Reset Radar" : "Reset Radar"
            content.body = body(event: reminder.event, offset: reminder.offset, locale: preferences.locale)
            // Threshold and due notifications are visual only; discovery owns the chime.
            content.sound = nil
            let interval = max(1, reminder.fireDate.timeIntervalSince(now))
            let request = UNNotificationRequest(
                identifier: reminder.identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            )
            try? await center.add(request)
        }
    }

    func cancelAll() async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func desiredReminders(events: [ResetEvent], preferences: UserPreferences, now: Date) -> [ScheduledReminder] {
        events.flatMap { event -> [ScheduledReminder] in
            guard event.isConfirmedOpportunity else { return [] }
            let fireTarget: Date?
            if event.kind == .automaticReset && event.state == .scheduled { fireTarget = event.targetAt }
            else if event.kind == .bankedResetGrant && (event.state == .available || event.state == .unresolved) { fireTarget = event.expiresAt }
            else { fireTarget = nil }
            guard let target = fireTarget, target > now else { return [] }
            return ReminderPlanner.plan(target: target, offsets: preferences.reminderOffsets, now: now).map { reminder in
                ScheduledReminder(
                    identifier: "\(identifierPrefix)\(event.id).r\(event.revision).\(Int(reminder.offset)).\(preferences.locale.rawValue).silent-v2",
                    event: event,
                    offset: reminder.offset,
                    fireDate: reminder.fireDate
                )
            }
        }
    }

    private func body(event: ResetEvent, offset: TimeInterval, locale: AppLocale) -> String {
        let isGrant = event.kind == .bankedResetGrant
        if offset == 0 {
            if isGrant { return locale == .zhHans ? "手动重置机会已到失效时间。" : "The manual reset opportunity has reached its expiry time." }
            return locale == .zhHans ? "已到预计重置时间，等待确认。" : "The estimated reset time has arrived. Awaiting confirmation."
        }
        let minutes = Int(offset / 60)
        if isGrant { return locale == .zhHans ? "手动重置机会将在 \(minutes) 分钟后失效。" : "Manual reset opportunity expires in \(minutes) minutes." }
        return locale == .zhHans ? "预计 \(minutes) 分钟后重置。" : "Estimated reset in \(minutes) minutes."
    }
}

private struct ScheduledReminder {
    let identifier: String
    let event: ResetEvent
    let offset: TimeInterval
    let fireDate: Date
}

struct PlannedReminder: Equatable {
    let offset: TimeInterval
    let fireDate: Date
}

enum ReminderPlanner {
    static func plan(target: Date, offsets: [TimeInterval], now: Date) -> [PlannedReminder] {
        (offsets + [0])
            .map { PlannedReminder(offset: $0, fireDate: target.addingTimeInterval(-$0)) }
            .filter { $0.fireDate > now }
            .sorted { $0.fireDate < $1.fireDate }
    }
}
