import SwiftUI

struct MiniView: View {
    @ObservedObject var model: MonitorModel
    let onExpand: () -> Void
    let onHide: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                HStack {
                    Circle().fill(accent).frame(width: 8, height: 8)
                    Text("Reset Radar").font(.system(size: 11, weight: .bold, design: .rounded))
                    if model.activeEvent?.evidence.contains(where: { $0.sourceID == "preview" }) == true {
                        Text("DEMO").font(.system(size: 7, weight: .bold)).foregroundStyle(.purple)
                    }
                    Spacer()
                    localeButton("中", .zhHans)
                    localeButton("EN", .en)
                    Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.plain).accessibilityLabel(model.preferences.locale == .zhHans ? "展开主窗口" : "Expand main window")
                    Button(action: onHide) { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .accessibilityLabel(model.preferences.locale == .zhHans ? "隐藏" : "Hide")
                }.foregroundStyle(.secondary)
                Text(statusText).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(accent).lineLimit(1)
                Text(countdown(now: context.date))
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.7).lineLimit(1)
                Text(targetText).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(16)
            .frame(width: 260, height: 145)
            .background(miniBackground)
            .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(.white.opacity(0.18)))
            .shadow(color: accent.opacity(0.18), radius: 24, y: 10)
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onExpand)
        }
    }

    @ViewBuilder private var miniBackground: some View {
        if #available(macOS 26.0, *) { Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 23)) }
        else { Rectangle().fill(.ultraThinMaterial) }
    }

    private func localeButton(_ title: String, _ value: AppLocale) -> some View {
        Button(title) { model.setLocale(value) }.buttonStyle(.plain)
            .font(.system(size: 9, weight: model.preferences.locale == value ? .bold : .regular))
            .foregroundStyle(model.preferences.locale == value ? accent : .secondary)
    }

    private func countdown(now: Date) -> String {
        if model.activeEvent?.state == .announcedComplete { return model.preferences.locale == .zhHans ? "✓ 已重置" : "✓ Reset done" }
        guard let target = model.activeEvent?.countdownAt else { return "––:––:––" }
        return CountdownView.remaining(target.timeIntervalSince(now))
    }

    private var targetText: String {
        if let event = model.activeEvent, event.state == .announcedComplete, let published = event.completedAt {
            return "\(model.preferences.locale == .zhHans ? "公告发布" : "Announced") · \(CountdownView.format(published, zoneID: model.preferences.displayTimeZone, locale: model.preferences.locale))"
        }
        guard let target = model.activeEvent?.countdownAt else {
            if model.activeEvent?.kind == .bankedResetGrant {
                return model.preferences.locale == .zhHans ? "请在账号内核对" : "Check your account"
            }
            if model.activeEvent?.kind == .lead {
                return model.preferences.locale == .zhHans ? "时间与类型待确认" : "Time and type pending"
            }
            return Copy.text(.monitoring, model.preferences.locale)
        }
        let prefix = model.activeEvent?.kind == .bankedResetGrant
            ? (model.preferences.locale == .zhHans ? "失效" : "Expires")
            : (model.preferences.locale == .zhHans ? "预计重置" : "Expected")
        return "\(prefix) · \(CountdownView.format(target, zoneID: model.preferences.displayTimeZone, locale: model.preferences.locale))"
    }

    private var statusText: String {
        guard let event = model.activeEvent else { return Copy.text(.noAnnouncement, model.preferences.locale) }
        if event.state == .announcedComplete { return model.preferences.locale == .zhHans ? "重置已完成 · 请核对账号" : "Reset completed · Check your account" }
        if event.kind == .bankedResetGrant {
            if event.audience == "affected-reset-users" { return model.preferences.locale == .zhHans ? "重置补偿 · 请核对资格" : "Compensation · Check eligibility" }
            if event.state == .unresolved { return model.preferences.locale == .zhHans ? "手动重置机会发放中" : "Banked reset rolling out" }
            return model.preferences.locale == .zhHans ? "手动重置机会" : "Manual reset opportunity"
        }
        if event.state == .dueUnconfirmed || event.targetAt.map({ $0 <= Date() }) == true {
            return model.preferences.locale == .zhHans ? "到点 · 等待确认" : "Due · Awaiting confirmation"
        }
        return Copy.text(.announced, model.preferences.locale)
    }

    private var accent: Color {
        if model.activeEvent?.state == .announcedComplete { return .teal }
        if model.activeEvent?.kind == .bankedResetGrant { return .green }
        if let date = model.activeEvent?.targetAt, date.timeIntervalSinceNow < 300 { return .red }
        return model.activeEvent == nil ? .gray : .orange
    }
}
