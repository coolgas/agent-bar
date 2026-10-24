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

/// Owns the long-lived components.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store: EventStore
    private let watcher: ProcessWatcher
    private let monitor: OpencodeMonitor

    private init() {
        store = EventStore()
        watcher = ProcessWatcher(store: store)
        monitor = OpencodeMonitor(store: store)
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
            MenuView(store: model.store)
        } label: {
            MenuBarLabel(store: model.store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: EventStore

    var body: some View {
        Label {
            Text(store.unackedCount > 0 ? "\(store.unackedCount)" : "")
        } icon: {
            Image(systemName: store.unackedCount > 0 ? "tray.full.fill" : "tray")
        }
        .help("AgentBar — finished agent tasks")
    }
}
