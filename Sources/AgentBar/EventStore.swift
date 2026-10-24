import Foundation

/// Tails ~/.agentbar/events.jsonl once a second and exposes menu bar state.
///
/// Producers (zsh hook, ProcessWatcher, OpencodeMonitor) all append JSON lines
/// to the same file, so events recorded while the app was closed are picked up
/// on launch. Acknowledged event ids are persisted to acked.json.
final class EventStore: ObservableObject {
    @Published private(set) var events: [AgentEvent] = []
    @Published private(set) var acked: Set<String> = []

    /// The data directory: $AGENTBAR_HOME if set, else ~/.agentbar. The env
    /// override makes it possible to test against a sandbox (and to keep
    /// state somewhere else); Foundation ignores $HOME here, so it must be
    /// explicit.
    let dir = EventStore.dataDir

    static var dataDir: URL {
        if let custom = ProcessInfo.processInfo.environment["AGENTBAR_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentbar", isDirectory: true)
    }

    private var eventsURL: URL { dir.appendingPathComponent("events.jsonl") }
    private var ackedURL: URL { dir.appendingPathComponent("acked.json") }

    private var fileOffset: UInt64 = 0
    private var pending = Data()   // partial line (raw bytes) carried between polls
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
        // Truncate in place rather than delete+recreate so a producer holding
        // the file open keeps appending to the same inode.
        if FileManager.default.fileExists(atPath: eventsURL.path),
           let fh = try? FileHandle(forWritingTo: eventsURL) {
            try? fh.truncate(atOffset: 0)
            try? fh.close()
        } else {
            FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        }
        fileOffset = 0
        pending = Data()
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
        pending = Data()
        guard let data = try? Data(contentsOf: eventsURL) else {
            events = []
            fileOffset = 0
            return
        }
        // Only consume complete lines. A trailing partial line (a producer
        // mid-write) stays unread so the next poll picks it up whole.
        let end = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        fileOffset = UInt64(end)
        events = Self.parse(data.prefix(end))
        trim()
    }

    /// Reads any newly appended events immediately (used when the panel opens
    /// so it never shows data up to a second stale).
    func pollNow() { poll() }

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
        consumeChunk(data)
    }

    /// Splits on raw newline bytes *before* decoding, so a multi-byte UTF-8
    /// character straddling two reads is never torn in half.
    private func consumeChunk(_ chunk: Data) {
        pending.append(chunk)
        guard let lastNL = pending.lastIndex(of: 0x0A) else { return }
        let complete = pending[pending.startIndex...lastNL]
        pending = Data(pending[pending.index(after: lastNL)...])
        let parsed = Self.parse(complete)
        guard !parsed.isEmpty else { return }
        // Ignore ids we already hold (e.g. a re-read after a truncation race).
        let known = Set(events.map(\.id))
        let fresh = parsed.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        events.append(contentsOf: fresh)
        trim()
    }

    private static func parse(_ data: Data) -> [AgentEvent] {
        data.split(separator: 0x0A).compactMap { parseLine(Data($0)) }
    }

    private static func parseLine(_ data: Data) -> AgentEvent? {
        try? JSONDecoder().decode(AgentEvent.self, from: data)
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
            guard event.source == "zsh", (now - event.ts) <= seconds,
                  let first = event.cmd.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            else { return false }
            return (String(first) as NSString).lastPathComponent == word
        }
    }

    /// Appends one event to the shared JSONL log. Thread-safe; producers may
    /// call this from any queue. The EventStore instance picks it up on its
    /// next 1-second poll.
    static func append(_ event: AgentEvent) {
        let dir = dataDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("events.jsonl")
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)
        // O_APPEND makes each write() land atomically at end-of-file, so it
        // can't interleave with the zsh hook (or another producer) appending
        // at the same moment, unlike a separate seekToEnd() + write().
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                if n < 0 { if errno == EINTR { continue }; return }
                offset += n
            }
        }
    }
}
