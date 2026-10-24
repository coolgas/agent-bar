import Foundation
import Darwin

/// Safety net: polls the process table for watchlisted programs and logs an
/// event when one exits. Catches commands run outside zsh (or in other
/// shells/terminal apps) that the zsh hook can't see.
///
/// `opencode` is deliberately excluded here — its interactive TUI never
/// "finishes" and its background service is long-lived; task completion for
/// opencode is tracked by OpencodeMonitor instead. One-shot `opencode run`
/// commands are covered by the zsh hook.
final class ProcessWatcher {
    private let store: EventStore
    private var timer: Timer?
    // pid -> (command line, first word, elapsed seconds at last sighting)
    private var tracked: [pid_t: (cmd: String, base: String, elapsed: Int)] = [:]
    private var lastRunningCount = -1

    /// Called on the main thread whenever the number of live watchlisted
    /// processes changes (drives the "running" counter in the UI).
    var onRunningChanged: ((Int) -> Void)?

    init(store: EventStore) {
        self.store = store
    }

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tracked.removeAll()
        if lastRunningCount != 0 {
            lastRunningCount = 0
            onRunningChanged?(0)
        }
    }

    private func scan() {
        let config = ConfigStore.shared.get()
        let patterns = config.watchlist.filter { pattern in
            let first = pattern.split(separator: " ").first.map(String.init) ?? pattern
            return first != "opencode"
        }
        guard !patterns.isEmpty else { return }

        let me = getpid()
        var seen = Set<pid_t>()

        for line in runPS() {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]),
                  Int(pid) != me,
                  let elapsed = Self.parseEtime(String(parts[1])) else { continue }

            let args = String(parts[2]).trimmingCharacters(in: .whitespaces)
            let firstEnd = args.firstIndex(of: " ") ?? args.endIndex
            let rawFirst = String(args[args.startIndex..<firstEnd])
            let base = (rawFirst as NSString).lastPathComponent
            let rest = firstEnd < args.endIndex ? String(args[args.index(after: firstEnd)...]) : ""
            let normalized = rest.isEmpty ? base : base + " " + rest

            guard Self.matches(normalized: normalized, base: base, patterns: patterns) else { continue }
            seen.insert(pid)
            if var old = tracked[pid] {
                old.elapsed = elapsed
                tracked[pid] = old
            } else {
                tracked[pid] = (cmd: normalized, base: base, elapsed: elapsed)
            }
        }

        for (pid, info) in tracked where !seen.contains(pid) {
            tracked.removeValue(forKey: pid)
            finish(info)
        }

        if tracked.count != lastRunningCount {
            lastRunningCount = tracked.count
            onRunningChanged?(tracked.count)
        }
    }

    private func finish(_ info: (cmd: String, base: String, elapsed: Int)) {
        guard info.elapsed >= ConfigStore.shared.get().minDurationSec else { return }
        // The zsh hook usually logs the same command with an exit code first;
        // don't double-count it.
        guard !store.hasRecentZshEvent(firstWord: info.base, within: 10) else { return }
        EventStore.append(AgentEvent(
            id: UUID().uuidString,
            source: "process",
            cmd: info.cmd,
            exit: nil,
            dur: info.elapsed,
            cwd: nil,
            tty: nil,
            ts: Date().timeIntervalSince1970
        ))
    }

    /// Prefix matching, mirroring the zsh hook semantics: "grok" matches
    /// anything starting with the `grok` program; "npm run" only matches
    /// commands starting with "npm run".
    static func matches(normalized: String, base: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            let pfirst = pattern.split(separator: " ").first.map(String.init) ?? pattern
            guard base == pfirst else { continue }
            if pattern.contains(" ") {
                if normalized == pattern || normalized.hasPrefix(pattern + " ") { return true }
            } else {
                return true
            }
        }
        return false
    }

    /// `ps` etime format: MM:SS | HH:MM:SS | DD-HH:MM:SS
    static func parseEtime(_ s: String) -> Int? {
        var total = 0
        var timePart = s
        if let dash = s.firstIndex(of: "-") {
            guard let days = Int(s[s.startIndex..<dash]) else { return nil }
            total += days * 86400
            timePart = String(s[s.index(after: dash)...])
        }
        var secs = 0
        for part in timePart.split(separator: ":") {
            guard let v = Int(part) else { return nil }
            secs = secs * 60 + v
        }
        return total + secs
    }

    private func runPS() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["ax", "-o", "pid=,etime=,args="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }
}
