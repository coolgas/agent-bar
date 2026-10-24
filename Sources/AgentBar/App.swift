import SwiftUI
import Combine

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
    private var cancellables = Set<AnyCancellable>()
    private var dayTimer: Timer?

    private init() {
        usage = Usage.load()
        store = EventStore()
        watcher = ProcessWatcher(store: store)
        monitor = OpencodeMonitor(store: store)
        // Views observe AppModel, not EventStore. SwiftUI doesn't see changes
        // inside a nested ObservableObject, so forward them; otherwise the
        // badge, list and Clear button wouldn't refresh when events change.
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
            self.rolloverUsageIfNeeded()
            self.usage.add(delta)
            self.usage.save()
        }
    }

    /// The daily counter must reset at midnight even if the app keeps running.
    private func rolloverUsageIfNeeded() {
        if usage.date != Usage.today { usage = Usage(date: Usage.today) }
    }

    func start() {
        watcher.start()
        monitor.start()
        dayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.rolloverUsageIfNeeded()
        }
    }

    func stop() {
        dayTimer?.invalidate()
        dayTimer = nil
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
        Image(nsImage: Self.image(count: model.store.unackedCount))
            .help(helpText)
            .accessibilityLabel(model.store.unackedCount > 0
                                ? "AgentBar, \(model.store.unackedCount) unread"
                                : "AgentBar")
    }

    // MenuBarExtra drops the Text half of a Label and shows only the icon, so
    // the unread count is drawn into the image. Template = follows menu bar tint.
    static func image(count: Int) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let name = count > 0 ? "tray.full.fill" : "tray"
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        guard count > 0 else {
            symbol.isTemplate = true
            return symbol
        }

        let text = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.black,
        ])
        let gap: CGFloat = 3
        let textSize = text.size()
        let size = NSSize(width: ceil(symbol.size.width + gap + textSize.width),
                          height: max(ceil(symbol.size.height), ceil(textSize.height)))
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: (size.height - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            text.draw(at: NSPoint(x: symbol.size.width + gap, y: (size.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
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
