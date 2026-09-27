import SwiftUI

struct CountdownView: View {
    @ObservedObject var model: MonitorModel
    let onMiniimize: () -> Void
    let onHide: () -> Void
    let onManualEntry: () -> Void
    let onExpansionChange: (Bool) -> Void

    private var locale: AppLocale { model.preferences.locale }
    private var event: ResetEvent? { model.activeEvent }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            card(now: timeline.date)
        }
        .frame(width: 412, height: model.preferences.detailsExpanded ? 610 : 294)
        .environment(\.locale, Locale(identifier: locale.rawValue))
    }

    private func card(now: Date) -> some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 12)
            statusHeader
            countdown(now: now)
            targetLine
            queryLine
            Spacer(minLength: 8)
            if model.preferences.detailsExpanded { detailsPanel }
            detailsToggle
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: accent.opacity(0.2), radius: 28, y: 12)
        .padding(12)
    }

    @ViewBuilder private var cardBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 28))
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Label("Reset Radar", systemImage: "scope")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            if isPreview {
                Text(Copy.text(.preview, locale)).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3).background(.purple, in: Capsule())
            }
            Spacer()
            localeControl
            iconButton(model.preferences.alwaysOnTop ? "pin.fill" : "pin.slash", help: locale == .zhHans ? (model.preferences.alwaysOnTop ? "取消置顶" : "置顶") : (model.preferences.alwaysOnTop ? "Unpin" : "Pin")) { model.setAlwaysOnTop(!model.preferences.alwaysOnTop) }
            iconButton("arrow.down.right.and.arrow.up.left", help: Copy.text(.minimize, locale), action: onMiniimize)
            iconButton("xmark", help: Copy.text(.hide, locale), action: onHide)
        }
    }

    private var localeControl: some View {
        HStack(spacing: 2) {
            localeButton("中", locale: .zhHans)
            localeButton("EN", locale: .en)
        }
        .padding(2)
        .background(.black.opacity(0.08), in: Capsule())
    }

    private func localeButton(_ title: String, locale value: AppLocale) -> some View {
        Button(title) { model.setLocale(value) }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: locale == value ? .bold : .medium))
            .foregroundStyle(locale == value ? .white : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(locale == value ? accent : .clear, in: Capsule())
            .accessibilityLabel(value == .zhHans ? "中文" : "English")
    }

    private var statusHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: statusIcon).font(.system(size: 15, weight: .bold))
            Text(statusTitle).font(.system(size: 15, weight: .bold, design: .rounded))
        }
        .foregroundStyle(accent)
    }

    @ViewBuilder private func countdown(now: Date) -> some View {
        if let target = event?.countdownAt {
            Text(Self.remaining(target.timeIntervalSince(now)))
                .font(.system(size: 67, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.58)
                .lineLimit(1)
                .contentTransition(.numericText())
        } else {
            Text("––:––:––")
                .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var targetLine: some View {
        Group {
            if let target = event?.countdownAt {
                let prefix = event?.kind == .bankedResetGrant
                    ? (locale == .zhHans ? "距失效" : "Expires in")
                    : (locale == .zhHans ? "预计重置" : "Expected reset")
                Text("\(prefix) · \(Self.format(target, zoneID: model.preferences.displayTimeZone, locale: locale)) · \(timeZoneLabel(for: target))")
            } else if event?.kind == .bankedResetGrant {
                Text(event?.state == .unresolved
                     ? (event?.announcementStage == "preview"
                        ? (locale == .zhHans ? "已宣布 · 等待发放，请核对适用范围" : "Announced · Awaiting distribution; check eligibility")
                        : (locale == .zhHans ? "正在发放 · 请在账号内核对适用范围" : "Rolling out · Check eligibility in your account"))
                     : (event?.audience == "affected-reset-users" ? (locale == .zhHans ? "曾在故障期间使用重置的用户 · 请核对账号" : "For affected reset users · Check your account") : (locale == .zhHans ? "请核对账号是否可用 · 有效期未知" : "Check eligibility in your account · Expiry unknown")))
            } else if event?.kind == .lead {
                Text(locale == .zhHans ? "重置时间或时区待确认" : "Reset time or time zone pending")
            } else {
                Text(Copy.text(.monitoring, locale))
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var queryLine: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(healthColor).frame(width: 6, height: 6)
                Text("\(Copy.text(.lastCheck, locale)) · \(relativeDate(model.mostRecentAttempt))")
                Text("· \(healthText)")
                if model.isRefreshing { ProgressView().controlSize(.mini) }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(model.isRefreshing)
                    .help(Copy.text(.refresh, locale)).accessibilityLabel(Copy.text(.refresh, locale))
            }
            if let message = model.storageMessage {
                Text(locale == .zhHans ? "本地数据：\(message)" : "Local data: \(message)")
                    .foregroundStyle(.red).lineLimit(1)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.top, 7)
    }

    private var detailsPanel: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5)
            HStack {
                Text(Copy.text(.sources, locale)).font(.system(size: 11, weight: .bold))
                Spacer()
                Button(locale == .zhHans ? "手动录入" : "Add manually", action: onManualEntry)
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                Button(Copy.text(.refresh, locale)) { Task { await model.refresh() } }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
            }
            if let event { eventDetails(event) }
            HStack {
                Toggle(Copy.text(.sound, locale), isOn: Binding(
                    get: { model.preferences.audioEnabled },
                    set: { model.setAudioEnabled($0) }
                )).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10, weight: .semibold))
                Slider(value: Binding(
                    get: { model.preferences.volume },
                    set: { model.setVolume($0) }
                ), in: 0...1)
                    .frame(width: 64)
                    .controlSize(.mini)
                Spacer()
                Button(Copy.text(.testSound, locale)) { SoundService.preview(volume: model.preferences.volume) }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
            }
            HStack {
                Toggle(Copy.text(.launchAtLogin, locale), isOn: Binding(
                    get: { model.preferences.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                )).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10, weight: .semibold))
                Spacer()
                if let message = model.launchAtLoginMessage {
                    Text(message).font(.system(size: 8)).foregroundStyle(.red).lineLimit(1)
                }
            }
            Picker(locale == .zhHans ? "检测间隔" : "Check interval", selection: Binding(
                get: { model.preferences.checkIntervalMinutes }, set: { model.setCheckInterval($0) }
            )) {
                ForEach(UserPreferences.checkIntervals, id: \.self) { minutes in
                    Text(locale == .zhHans ? "\(minutes) 分钟" : "\(minutes) min").tag(minutes)
                }
            }.font(.system(size: 10)).controlSize(.small)
            ForEach(FeedSource.defaults) { source in
                let status = model.statuses.first { $0.sourceID == source.id }
                HStack(spacing: 8) {
                    Circle().fill(status?.result == .success ? Color.green : (status?.result == .failed ? Color.red : Color.gray)).frame(width: 7, height: 7)
                    Text(source.name).font(.system(size: 10, weight: .medium))
                    Spacer()
                    Text(sourceStatusText(status)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack {
                Text(locale == .zhHans ? "显示时区" : "Display time zone").font(.system(size: 10, weight: .semibold))
                Spacer()
                Menu(timeZoneLabel) {
                    ForEach(Self.favoriteZones, id: \.self) { zone in
                        Button(zone) { model.setTimeZone(zone) }
                    }
                    Divider()
                    ForEach(TimeZone.knownTimeZoneIdentifiers.filter { !Self.favoriteZones.contains($0) }, id: \.self) { zone in
                        Button(zone) { model.setTimeZone(zone) }
                    }
                }.menuStyle(.borderlessButton).frame(width: 170)
            }
            Text(Copy.text(.communityRelay, locale) + " · " + Copy.text(.statusUnknown, locale))
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            if !historyEvents.isEmpty {
                Divider().opacity(0.4)
                Text(locale == .zhHans ? "最近记录" : "Recent history").font(.system(size: 10, weight: .bold))
                ForEach(historyEvents.prefix(3)) { item in
                    HStack {
                        Text(historyTitle(item)).font(.system(size: 9, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(Self.format(item.bestEvidence?.publishedAt ?? item.updatedAt, zoneID: model.preferences.displayTimeZone, locale: locale))
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        }
        .frame(maxHeight: 395)
    }

    private var detailsToggle: some View {
        Button {
            let expanded = !model.preferences.detailsExpanded
            withAnimation(.snappy(duration: 0.28)) { model.setExpanded(expanded) }
            onExpansionChange(expanded)
        } label: {
            Image(systemName: model.preferences.detailsExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.plain)
        .help(Copy.text(model.preferences.detailsExpanded ? .collapse : .details, locale))
        .accessibilityLabel(Copy.text(model.preferences.detailsExpanded ? .collapse : .details, locale))
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 22, height: 22) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }

    private func eventDetails(_ event: ResetEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(productText(event.products)).font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3).background(accent.opacity(0.12), in: Capsule())
                Text(audienceText(event.audience)).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let url = event.bestEvidence?.url {
                    Link(locale == .zhHans ? "查看原文" : "View source", destination: url)
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            if let excerpt = event.bestEvidence?.excerpt, !excerpt.isEmpty {
                Text(excerpt).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack {
                if event.kind == .bankedResetGrant && event.state == .available {
                    Button(locale == .zhHans ? "标记已使用" : "Mark used") { model.markEvent(event.id, as: .used) }
                } else if event.state == .dueUnconfirmed {
                    Button(locale == .zhHans ? "确认已重置" : "Confirm reset") { model.markEvent(event.id, as: .announcedComplete) }
                }
                Button(locale == .zhHans ? "不再显示" : "Dismiss") { model.markEvent(event.id, as: .dismissed) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9, weight: .semibold))
        }
        .padding(8)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var historyEvents: [ResetEvent] {
        model.events.filter { item in
            item.id != event?.id && [.announcedComplete, .expired, .used, .dismissed, .cancelled, .archived].contains(item.state)
        }.sorted { ($0.bestEvidence?.publishedAt ?? $0.updatedAt) > ($1.bestEvidence?.publishedAt ?? $1.updatedAt) }
    }

    private func historyTitle(_ event: ResetEvent) -> String {
        let type: String
        switch event.kind {
        case .bankedResetGrant: type = locale == .zhHans ? "手动机会" : "Manual opportunity"
        case .lead: type = locale == .zhHans ? "重置预告" : "Reset preview"
        case .automaticReset: type = locale == .zhHans ? "自动重置" : "Automatic reset"
        case .limitChange: type = locale == .zhHans ? "额度变更" : "Limit change"
        }
        let state: String
        switch event.state {
        case .announcedComplete: state = locale == .zhHans ? "已确认" : "confirmed"
        case .expired: state = locale == .zhHans ? "已失效" : "expired"
        case .used: state = locale == .zhHans ? "已使用" : "used"
        case .dismissed: state = locale == .zhHans ? "已忽略" : "dismissed"
        case .cancelled: state = locale == .zhHans ? "已取消" : "cancelled"
        case .archived: state = locale == .zhHans ? "已归档" : "archived"
        default: state = event.state.rawValue
        }
        return "\(type) · \(state)"
    }

    private func sourceStatusText(_ status: SourceStatus?) -> String {
        guard let status else { return Copy.text(.statusUnknown, locale) }
        if status.result == .failed { return status.message ?? Copy.text(.sourceFailed, locale) }
        if let count = status.itemCount { return locale == .zhHans ? "已连接 · \(count) 条" : "Connected · \(count) items" }
        return status.result == .success ? Copy.text(.sourceReachable, locale) : Copy.text(.statusUnknown, locale)
    }

    private func productText(_ products: [String]) -> String {
        products.map {
            switch $0 { case "unspecified": return locale == .zhHans ? "产品待确认" : "Product pending"; case "astra": return "Astra"; case "chatgpt-work": return "ChatGPT Work"; case "chatgpt": return "ChatGPT"; default: return "Codex" }
        }.joined(separator: " + ")
    }

    private func audienceText(_ audience: String) -> String {
        switch audience {
        case "all": return locale == .zhHans ? "全部用户" : "All users"
        case "paid-plans": return "Plus / Pro / Business"
        case "affected-reset-users": return locale == .zhHans ? "仅补偿故障期间使用重置的用户" : "Only users who used a reset during the incident"
        case "partial": return locale == .zhHans ? "部分用户" : "Some users"
        default: return locale == .zhHans ? "适用人群未知" : "Audience unknown"
        }
    }

    private var accent: Color {
        guard let event else { return Color(red: 0.43, green: 0.47, blue: 0.53) }
        if event.kind == .bankedResetGrant { return Color(red: 0.12, green: 0.68, blue: 0.45) }
        if event.targetAt.map({ $0 <= Date() }) == true { return Color(red: 0.78, green: 0.58, blue: 0.18) }
        if event.kind == .lead { return Color(red: 0.55, green: 0.40, blue: 0.86) }
        if let target = event.targetAt, target.timeIntervalSinceNow <= 300 { return Color(red: 0.96, green: 0.28, blue: 0.26) }
        return Color(red: 0.95, green: 0.58, blue: 0.12)
    }

    private var statusIcon: String {
        if event?.kind == .bankedResetGrant { return "sparkles" }
        if event?.kind == .lead { return "questionmark.bubble.fill" }
        if event?.targetAt != nil { return "alarm.fill" }
        return "moon.stars.fill"
    }

    private var statusTitle: String {
        guard let event else { return Copy.text(.noAnnouncement, locale) }
        if event.kind == .bankedResetGrant {
            if event.audience == "affected-reset-users" { return locale == .zhHans ? "手动重置补偿 · 请核对资格" : "Reset compensation · Check eligibility" }
            if event.state == .unresolved {
                return event.announcementStage == "preview"
                    ? (locale == .zhHans ? "手动重置机会预告" : "Banked reset announced")
                    : (locale == .zhHans ? "手动重置机会发放中" : "Banked reset rolling out")
            }
            return event.expiresAt == nil
                ? (locale == .zhHans ? "手动重置机会 · 有效期未知" : "Manual reset opportunity · Expiry unknown")
                : (locale == .zhHans ? "手动重置机会 · 距失效" : "Manual reset opportunity · Expires in")
        }
        if event.kind == .lead { return Copy.text(.vagueLead, locale) }
        if event.targetAt.map({ $0 <= Date() }) == true {
            return locale == .zhHans ? "到达预计时间 · 等待确认" : "Estimated time reached · Awaiting confirmation"
        }
        return Copy.text(.announced, locale)
    }

    private var healthColor: Color {
        if model.isRefreshing { return .yellow }
        if model.statuses.isEmpty { return .gray }
        if model.failedSourceCount == model.statuses.count { return .red }
        if model.failedSourceCount > 0 { return .orange }
        return .green
    }

    private var healthText: String {
        if model.statuses.isEmpty { return Copy.text(.statusUnknown, locale) }
        if model.failedSourceCount == model.statuses.count { return Copy.text(.queryFailed, locale) }
        if model.failedSourceCount > 0 { return Copy.text(.queryPartial, locale) }
        return Copy.text(.querySuccess, locale)
    }

    private var isPreview: Bool { event?.evidence.contains { $0.sourceID == "preview" } == true }

    private var timeZoneLabel: String {
        timeZoneLabel(for: event?.countdownAt ?? Date())
    }

    private func timeZoneLabel(for date: Date) -> String {
        guard let zone = TimeZone(identifier: model.preferences.displayTimeZone) else { return model.preferences.displayTimeZone }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale.rawValue)
        formatter.timeZone = zone
        formatter.dateFormat = "zzz"
        return "\(formatter.string(from: date)) · \(model.preferences.displayTimeZone)"
    }

    private func relativeDate(_ date: Date?) -> String {
        guard let date else { return Copy.text(.never, locale) }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: locale.rawValue)
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func remaining(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(interval)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let rest = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, rest)
    }

    static func format(_ date: Date, zoneID: String, locale: AppLocale) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale.rawValue)
        formatter.timeZone = TimeZone(identifier: zoneID) ?? .current
        formatter.dateFormat = locale == .zhHans ? "M月d日 EEE HH:mm" : "EEE, MMM d · HH:mm"
        return formatter.string(from: date)
    }

    static let favoriteZones = ["Asia/Shanghai", "America/Los_Angeles", "America/New_York", "Europe/London", "Europe/Paris", "Asia/Tokyo", "Australia/Sydney"]
}
