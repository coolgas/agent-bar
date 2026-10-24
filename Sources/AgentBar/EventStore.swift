import Foundation

/// Tails ~/.agentbar/events.jsonl once a second and exposes menu bar state.
///
/// Producers (zsh hook, ProcessWatcher, OpencodeMonitor) all append JSON lines
/// to the same file, so events recorded while the app was closed are picked up
/// on launch. Acknowledged event ids are persisted to acked.json.
final class EventStore: ObservableObject {
    @Published private(set) var events: [AgentEvent] = []
    @Published private(set) var acked: Set<String> = []

    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentbar", isDirectory: true)

    private var eventsURL: URL { dir.appendingPathComponent("events.jsonl") }
    private var ackedURL: URL { dir.appendingPathComponent("acked.json") }

    private var fileOffset: UInt64 = 0
    private var pending = ""   // partial line carried between polls
    private var timer: Timer?

    var unackedCount: Int { events.lazy.filter { !self.acked.contains($0.id) }.count }

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadAcked()
        reloadAll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    var eventsURLPath: String { eventsURL.path }

    // MARK: - Acknowledgement

    func ack(_ id: String) {
        acked.insert(id)
        persistAcked()
    }

    func ackAll() {
        for event in events { acked.insert(event.id) }
        persistAcked()
    }

    /// Wipes the list entirely: removes every event (acknowledged or not),
    /// resets the count, and truncates the log file so the cleared history
    /// doesn't reappear on the next app launch.
    func clearAll() {
        events = []
        acked = []
        persistAcked()
        try? FileManager.default.removeItem(at: eventsURL)
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        fileOffset = 0
        pending = ""
    }

    private func loadAcked() {
        guard let data = try? Data(contentsOf: ackedURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        acked = Set(list)
    }

    private func persistAcked() {
        guard let data = try? JSONEncoder().encode(Array(acked)) else { return }
        try? data.write(to: ackedURL, options: .atomic)
    }

    // MARK: - File tailing

    private func reloadAll() {
        pending = ""
        guard let data = try? Data(contentsOf: eventsURL) else {
            events = []
            fileOffset = 0
            return
        }
        fileOffset = UInt64(data.count)
        events = Self.parse(data)
        trim()
    }

    private func poll() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: eventsURL.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

        // File truncated or replaced: start over. Missing file: reset state.
        if size < fileOffset {
            reloadAll()
            return
        }
        if size == fileOffset { return }

        guard let fh = try? FileHandle(forReadingFrom: eventsURL) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: fileOffset)
        let data = fh.readDataToEndOfFile()
        fileOffset = UInt64(fh.offsetInFile)
        consumeChunk(String(decoding: data, as: UTF8.self))
    }

    private func consumeChunk(_ text: String) {
        pending += text
        var lines = pending.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if !pending.hasSuffix("\n"), let last = lines.popLast() {
            pending = last   // incomplete line; wait for the rest
        } else {
            pending = ""
        }
        let parsed = lines.compactMap(Self.parseLine)
        guard !parsed.isEmpty else { return }
        events.append(contentsOf: parsed)
        trim()
    }

    private static func parse(_ data: Data) -> [AgentEvent] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ raw: String) -> AgentEvent? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(AgentEvent.self, from: data) else { return nil }
        return event
    }

    private func trim() {
        let max = max(10, ConfigStore.shared.get().maxEvents)
        if events.count > max {
            events.removeFirst(events.count - max)
        }
        let ids = Set(events.map(\.id))
        let pruned = acked.filter { ids.contains($0) }
        if pruned != acked {
            acked = pruned
            persistAcked()
        }
    }

    // MARK: - Helpers for producers

    /// Used by ProcessWatcher to avoid double-counting a command the zsh hook
    /// already logged (both fire within a few seconds of each other).
    func hasRecentZshEvent(firstWord word: String, within seconds: Double) -> Bool {
        let now = Date().timeIntervalSince1970
        return events.contains { event in
            event.source == "zsh"
                && (now - event.ts) <= seconds
                && (event.cmd.split(separator: " ").first.map(String.init) ?? "") == word
        }
    }

    /// Appends one event to the shared JSONL log. Thread-safe; producers may
    /// call this from any queue. The EventStore instance picks it up on its
    /// next 1-second poll.
    static func append(_ event: AgentEvent) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("events.jsonl")
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
    }
}
