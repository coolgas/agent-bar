import Foundation

/// One finished task. Producers append these as single-line JSON objects to
/// ~/.agentbar/events.jsonl; EventStore tails that file.
struct AgentEvent: Codable, Identifiable, Equatable {
    var id: String
    var source: String      // "zsh" | "process" | "opencode"
    var cmd: String         // human-readable description
    var exit: Int?          // nil = unknown (process watcher can't see exit codes)
    var dur: Int?           // runtime in seconds, nil = unknown
    var cwd: String?
    var tty: String?
    var ts: Double          // epoch seconds
}

struct Config {
    var watchlist: [String] = Config.defaultWatchlist
    var minDurationSec = 5
    var maxEvents = 200

    static let defaultWatchlist = [
        "grok", "claude", "codex", "gemini", "make", "cargo",
        "npm run", "pnpm", "yarn", "pytest", "opencode run",
    ]

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentbar/config.txt")
    }

    /// Parses the simple line-based config format:
    ///   watch <command prefix>
    ///   minDurationSec <n>
    ///   maxEvents <n>
    /// Blank lines and # comments are ignored. If the file defines any
    /// "watch" lines they replace the built-in defaults entirely.
    static func load() -> Config {
        var config = Config()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return config }
        var watches: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard !tokens.isEmpty else { continue }
            switch tokens[0] {
            case "watch" where tokens.count >= 2:
                watches.append(tokens.dropFirst().joined(separator: " "))
            case "minDurationSec" where tokens.count >= 2:
                if let n = Int(tokens[1]) { config.minDurationSec = n }
            case "maxEvents" where tokens.count >= 2:
                if let n = Int(tokens[1]) { config.maxEvents = n }
            default:
                break
            }
        }
        if !watches.isEmpty { config.watchlist = watches }
        return config
    }
}

/// Token usage accumulated for the current day, persisted to
/// ~/.agentbar/usage.json. Fed by opencode's session.usage.updated events
/// (each event carries the tokens/cost of one model request).
struct Usage: Codable, Equatable {
    var date = ""
    var input = 0
    var output = 0
    var reasoning = 0
    var cacheRead = 0
    var cost = 0.0

    static var today: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    var totalTokens: Int { input + output + reasoning + cacheRead }

    static func load() -> Usage {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentbar/usage.json")
        if let data = try? Data(contentsOf: url),
           let usage = try? JSONDecoder().decode(Usage.self, from: data),
           usage.date == today {
            return usage
        }
        return Usage(date: today)   // fresh day (or no/corrupt file)
    }

    func save() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: dir.appendingPathComponent("usage.json"), options: .atomic)
        }
    }

    mutating func add(_ other: Usage) {
        input += other.input
        output += other.output
        reasoning += other.reasoning
        cacheRead += other.cacheRead
        cost += other.cost
    }
}

/// Thread-safe config cache that re-reads ~/.agentbar/config.txt whenever its
/// modification date changes, so edits apply without restarting the app.
final class ConfigStore {
    static let shared = ConfigStore()

    private let lock = NSLock()
    private var cached = Config.load()
    private var cachedMtime: Date?

    func get() -> Config {
        lock.lock()
        defer { lock.unlock() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: Config.url.path)
        let mtime = attrs?[.modificationDate] as? Date
        if mtime != cachedMtime {
            cachedMtime = mtime
            cached = Config.load()
        }
        return cached
    }
}
