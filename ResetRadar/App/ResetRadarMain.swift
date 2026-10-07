import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
struct ResetRadarMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var model: MonitorModel!
    private var panelController: FloatingPanelController!
    private let manualEntryController = ManualEntryWindowController()
    private var statusItem: NSStatusItem!
    private var stateObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = MonitorModel()
        panelController = FloatingPanelController(model: model) { [weak self] in
            guard let self else { return }
            self.manualEntryController.show(locale: self.model.preferences.locale, timeZoneID: self.model.preferences.displayTimeZone) { [weak self] draft in
                self?.model.addManualEvent(draft)
            }
        }
        model.onNewActionableEvent = { [weak self] _ in
            self?.panelController.showMain(center: true)
            if self?.model.preferences.audioEnabled == true { SoundService.preview(volume: self?.model.preferences.volume ?? 0.65) }
        }
        model.onNewCompletedReset = { [weak self] event in
            guard let self else { return }
            self.panelController.showMain(center: true)
            if self.model.preferences.audioEnabled { SoundService.preview(volume: self.model.preferences.volume) }
            let preferences = self.model.preferences
            Task { await ReminderScheduler.shared.notifyCompletion(event: event, preferences: preferences) }
        }
        model.onPreferencesChanged = { [weak self] _ in
            self?.panelController.applyPinPreference()
            self?.setupMenuBar()
        }
        stateObservation = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatusIcon() }
        }
        setupMenuBar()
        UNUserNotificationCenter.current().delegate = self
        let startTask = model.start(loadPreview: ProcessInfo.processInfo.arguments.contains("--preview"))
        Task { [weak self] in
            await startTask.value
            self?.panelController.restoreSavedMode()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: NSNotification.Name.NSSystemClockDidChange, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func setupMenuBar() {
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        updateStatusIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        let zh = model?.preferences.locale != .en
        let menu = NSMenu()
        menu.addItem(withTitle: zh ? "显示" : "Show", action: #selector(showPanel), keyEquivalent: "")
        let pin = menu.addItem(withTitle: zh ? "置顶窗口" : "Keep on top", action: #selector(togglePin), keyEquivalent: "")
        pin.state = model.preferences.alwaysOnTop ? .on : .off
        menu.addItem(withTitle: zh ? "立即查询" : "Check now", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: zh ? "手动添加公告…" : "Add announcement…", action: #selector(manualEntry), keyEquivalent: "n")
        menu.addItem(withTitle: zh ? "载入演示预告" : "Load preview", action: #selector(loadPreview), keyEquivalent: "")
        menu.addItem(withTitle: zh ? "清除演示预告" : "Clear preview", action: #selector(clearPreview), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: zh ? "退出 Reset Radar" : "Quit Reset Radar", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        guard statusItem != nil else { return }
        let zh = model.preferences.locale == .zhHans
        let badge: String?
        let label: String
        if let event = model.activeEvent {
            badge = event.state == .announcedComplete ? "✓" : (event.kind == .bankedResetGrant ? "+" : (event.kind == .lead ? "?" : "•"))
            label = event.state == .announcedComplete ? (zh ? "重置已完成" : "Reset completed") : (zh ? "发现重置公告" : "Reset announcement found")
        } else if model.failedSourceCount > 0 {
            badge = model.failedSourceCount == model.statuses.count ? "!" : "–"
            label = zh ? "来源检测异常" : "Source checks need attention"
        } else {
            badge = nil
            label = zh ? "暂无重置预告" : "No reset announcement"
        }
        let icon = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { rect in
            NSImage(systemSymbolName: "scope", accessibilityDescription: nil)?.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
            if let badge {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: NSColor.black]
                (badge as NSString).draw(at: NSPoint(x: 15, y: 7), withAttributes: attributes)
            }
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = label
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "Reset Radar · " + label
    }

    @objc private func togglePin() { model.setAlwaysOnTop(!model.preferences.alwaysOnTop) }
    @objc private func togglePanel() { panelController.toggleVisible() }
    @objc private func showPanel() { panelController.showMain() }
    @objc private func refresh() { Task { await model.refresh() } }
    @objc private func manualEntry() {
        manualEntryController.show(locale: model.preferences.locale, timeZoneID: model.preferences.displayTimeZone) { [weak self] draft in self?.model.addManualEvent(draft) }
    }
    @objc private func loadPreview() { model.addPreviewEvent(); panelController.showMain(center: true) }
    @objc private func clearPreview() { model.clearPreviewEvent(); panelController.showMain() }
    @objc private func didWake() { Task { await model.handleWake() } }
    @objc private func clockChanged() { Task { await model.handleWake() } }
    @objc private func quit() {
        Task {
            await model.cancelPendingReminders()
            NSApplication.shared.terminate(nil)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
