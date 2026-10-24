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
                if model.runningCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "gearshape")
                            .font(.caption2)
                        Text("\(model.runningCount)")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .help("running tasks")
                }
                Text(headerCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") { store.clearAll() }
                    .buttonStyle(.borderless)
                    .font(.caption)
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
                Button("Quit AgentBar") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
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
                    Text(event.cmd)
                        .font(.system(size: 12, weight: acked ? .regular : .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(sourceTag)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
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
        if let d = durationText { parts.append(d) }
        parts.append(timeText)
        if let cwd = event.cwd {
            parts.append((cwd as NSString).lastPathComponent)
        }
        return parts.joined(separator: "  ·  ")
    }

    private var durationText: String? {
        guard let s = event.dur, s >= 0 else { return nil }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02ds", s % 60))" }
        return "\(s / 3600)h \(String(format: "%02dm", (s % 3600) / 60))"
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: event.ts))
    }

    private var sourceTag: String {
        switch event.source {
        case "zsh": return "zsh"
        case "process": return "proc"
        case "opencode": return "oc"
        default: return event.source
        }
    }
}
