import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon; menu bar only
        AppModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }
}

/// Owns the long-lived components and the state the UI observes.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// Watchlisted processes + opencode tasks currently running.
    @Published private(set) var runningCount = 0
    /// Tokens/cost burned today via opencode.
    @Published private(set) var usage: Usage

    let store: EventStore
    private let watcher: ProcessWatcher
    private let monitor: OpencodeMonitor
    private var runningProcesses = 0
    private var runningOpencode = 0

    private init() {
        usage = Usage.load()
        store = EventStore()
        watcher = ProcessWatcher(store: store)
        monitor = OpencodeMonitor(store: store)
        watcher.onRunningChanged = { [weak self] count in
            guard let self else { return }
            self.runningProcesses = count
            self.runningCount = self.runningProcesses + self.runningOpencode
        }
        monitor.onBusyChanged = { [weak self] count in
            guard let self else { return }
            self.runningOpencode = count
            self.runningCount = self.runningProcesses + self.runningOpencode
        }
        monitor.onUsageDelta = { [weak self] delta in
            guard let self else { return }
            self.usage.add(delta)
            self.usage.save()
        }
    }

    func start() {
        watcher.start()
        monitor.start()
    }

    func stop() {
        watcher.stop()
        monitor.stop()
    }
}

@main
struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Label {
            Text(labelText)
        } icon: {
            Image(systemName: iconName)
        }
        .help(helpText)
    }

    // Finished-but-unseen tasks take priority, then running tasks.
    private var labelText: String {
        if model.store.unackedCount > 0 { return "\(model.store.unackedCount)" }
        if model.runningCount > 0 { return "\(model.runningCount)" }
        return ""
    }

    private var iconName: String {
        if model.store.unackedCount > 0 { return "tray.full.fill" }
        if model.runningCount > 0 { return "gearshape" }
        return "tray"
    }

    private var helpText: String {
        var parts: [String] = []
        if model.runningCount > 0 { parts.append("\(model.runningCount) running") }
        if model.store.unackedCount > 0 { parts.append("\(model.store.unackedCount) finished") }
        parts.append("\(model.usage.totalTokens.tokensFormatted) today")
        return "AgentBar — " + parts.joined(separator: " · ")
    }
}

extension Int {
    var tokensFormatted: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fk", Double(self) / 1_000) }
        return "\(self)"
    }
}
