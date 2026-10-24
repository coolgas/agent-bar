import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel

    private var store: EventStore { model.store }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("AgentBar")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(headerCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    store.clearAll()
                } label: {
                    Text("Clear")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.events.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.events.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No finished tasks yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(store.events.reversed())) { event in
                            EventRow(event: event, acked: store.acked.contains(event.id)) {
                                store.ack(event.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 380)
            }

            Divider()

            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(usageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .help("opencode token usage today (all providers tracked by opencode)")

            Divider()

            HStack {
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit AgentBar")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onAppear { store.pollNow() }
    }

    private var headerCountText: String {
        if store.unackedCount > 0 { return "\(store.unackedCount) new" }
        if model.runningCount == 0 { return "all clear" }
        return ""
    }

    private var usageText: String {
        var text = "Today: \(model.usage.totalTokens.tokensFormatted) tokens"
        if model.usage.cost > 0 {
            text += String(format: " · $%.2f", model.usage.cost)
        }
        return text
    }
}

struct EventRow: View {
    let event: AgentEvent
    let acked: Bool
    let onAck: () -> Void

    var body: some View {
        Button(action: onAck) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 13))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(harness)
                            .font(.system(size: 12, weight: acked ? .regular : .semibold))
                        if let folder {
                            Text(folder)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(event.cwd ?? "")
                        }
                    }
                    if let preview {
                        Text(preview)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(acked ? 0.4 : 1.0)
    }

    private var iconName: String {
        switch event.exit {
        case .some(0): return "checkmark.circle.fill"
        case .some: return "xmark.circle.fill"
        case .none: return "questionmark.circle"
        }
    }

    private var iconColor: Color {
        switch event.exit {
        case .some(0): return .green
        case .some: return .red
        case .none: return .gray
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let model = event.model { parts.append(model) }
        if let d = durationText { parts.append(d) }
        parts.append(timeText)
        return parts.joined(separator: "  ·  ")
    }

    // Shell events keep the raw command: first word is the tool, the rest is
    // what it was asked to do. opencode events carry these fields directly.
    private var commandWords: [Substring] {
        var words = event.cmd.split(separator: " ", omittingEmptySubsequences: true)
        while let first = words.first, first.contains("="), !first.hasPrefix("/") { words.removeFirst() }
        return words
    }

    private var harness: String {
        if let h = event.harness { return h }
        if event.cmd.hasPrefix("opencode · ") { return "opencode" }
        guard let first = commandWords.first else { return event.cmd }
        return (String(first) as NSString).lastPathComponent
    }

    private var folder: String? {
        guard let cwd = event.cwd, !cwd.isEmpty else { return nil }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    private var preview: String? {
        let text: String
        if let p = event.preview {
            text = p
        } else if event.cmd.hasPrefix("opencode · ") {
            text = String(event.cmd.dropFirst("opencode · ".count))
        } else {
            text = commandWords.dropFirst().joined(separator: " ")
        }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        let limit = 6
        let head = words.prefix(limit).joined(separator: " ")
        return words.count > limit ? head + "…" : head
    }

    private var durationText: String? {
        guard let s = event.dur, s >= 0 else { return nil }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02ds", s % 60))" }
        return "\(s / 3600)h \(String(format: "%02dm", (s % 3600) / 60))"
    }

    private var timeText: String {
        Self.timeFormatter.string(from: Date(timeIntervalSince1970: event.ts))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
