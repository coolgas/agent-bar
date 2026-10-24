import Foundation

/// Watches opencode's event stream and fires an event each time a session
/// finishes executing a task — the useful "come back, it's done" signal for
/// interactive agent sessions.
///
/// Discovery: `opencode api get /api/info` returns the local service URL (the
/// CLI handles finding or starting the background service). The service's
/// Basic-auth password lives in ~/.config/opencode/service.json. The SSE
/// stream at /api/event is then consumed directly with curl (`opencode api`
/// buffers and won't stream).
final class OpencodeMonitor {
    private let store: EventStore
    private var process: Process?        // the curl subprocess
    private var resolvedPath: String?    // opencode binary

    private let queue = DispatchQueue(label: "agentbar.opencode")
    private var buffer: [UInt8] = []
    // queue-protected session state
    private var busy: [String: Date] = [:]           // sessionID -> execution started
    private var cwdCache: [String: String] = [:]     // sessionID -> directory (from session.created)
    private var titleCache: [String: String] = [:]   // sessionID -> title (from session.renamed)

    private var retryWorkItem: DispatchWorkItem?

    /// Ignore tasks shorter than this — quick Q&A shouldn't page you.
    private let minTaskSeconds = 2

    init(store: EventStore) {
        self.store = store
    }

    func start() {
        scheduleRetry(0.5)
    }

    func stop() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    private func scheduleRetry(_ delay: TimeInterval) {
        retryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.connect() }
        retryWorkItem = item
        if delay <= 0 {
            DispatchQueue.main.async(execute: item)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    // MARK: - Connection & discovery

    private func connect() {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            guard let exe = self.opencodePath() else {
                Self.log("opencode binary not found; retrying in 30s")
                self.scheduleRetry(30)   // opencode not installed (yet); keep trying
                return
            }
            self.resolvedPath = exe
            guard let (baseURL, password) = self.discoverService(exe: exe) else {
                Self.log("service discovery failed; retrying in 15s")
                self.scheduleRetry(15)   // service not reachable; it may appear later
                return
            }
            Self.log("opening stream at \(baseURL)")
            self.openStream(baseURLString: baseURL, password: password)
        }
    }

    private func opencodePath() -> String? {
        resolvedPath ?? Self.resolveOpencodePath()
    }

    /// Resolve the opencode binary through a login shell so the app works
    /// even when launched with a minimal PATH.
    private static func resolveOpencodePath() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v opencode"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Asks the CLI where the background service is and reads the local
    /// service password. Returns the base URL string and password.
    private func discoverService(exe: String) -> (String, String)? {
        guard let info = Self.runJSON(exe, ["api", "get", "/api/info"]),
              let urls = info["urls"] as? [String],
              let baseURL = urls.first else { return nil }

        let configDir = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config").path
        let serviceJSON = URL(fileURLWithPath: configDir)
            .appendingPathComponent("opencode/service.json")
        guard let data = try? Data(contentsOf: serviceJSON),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let password = obj["password"] as? String else { return nil }
        return (baseURL, password)
    }

    private func openStream(baseURLString: String, password: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = [
            "-sN",                       // silent, unbuffered
            "-u", "opencode:\(password)",
            baseURLString + "/api/event",
        ]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()

        let startedAt = Date()
        p.terminationHandler = { [weak self] _ in
            guard let self, self.process === p else { return }
            self.process = nil
            self.queue.async { self.busy.removeAll() }
            // Fast exit means something is wrong (bad URL, service down):
            // back off. Slow exit means the service restarted: reconnect fast.
            let delay: TimeInterval = Date().timeIntervalSince(startedAt) < 2 ? 30 : 5
            self.scheduleRetry(delay)
        }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }
        do {
            try p.run()
            process = p
            Self.log("stream running (pid \(p.processIdentifier))")
        } catch {
            Self.log("failed to launch curl: \(error)")
            scheduleRetry(30)
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[agentbar/opencode] \(message)\n".utf8))
    }

    // MARK: - Stream parsing

    private func consume(_ data: Data) {
        buffer.append(contentsOf: data)
        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[0..<idx], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(0...idx)
            handleLine(line)
        }
    }

    private func handleLine(_ raw: String) {
        var line = raw
        if line.hasPrefix("data:") {
            line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        let type = obj["type"] as? String ?? ""
        let payload = (obj["data"] as? [String: Any]) ?? [:]
        guard let sessionID = payload["sessionID"] as? String else {
            if type.hasPrefix("session.execution") {
                Self.log("execution event without sessionID: \(line.prefix(200))")
            }
            return
        }

        let now = Date()
        if type == "session.execution.started" {
            busy[sessionID] = now
            Self.log("execution started: \(sessionID)")
        } else if type.hasPrefix("session.execution.") {
            // succeeded / failed / interrupted: the task is done
            guard let started = busy[sessionID] else {
                Self.log("execution ended but no start recorded: \(type) \(sessionID)")
                return
            }
            busy.removeValue(forKey: sessionID)
            let dur = Int(now.timeIntervalSince(started))
            guard dur >= minTaskSeconds else { return }
            let exit = type == "session.execution.succeeded" ? 0 : 1
            let cwd = cwdCache[sessionID]
            let knownTitle = titleCache[sessionID]
            let exe = resolvedPath
            let sid = sessionID
            queue.async {
                var title = knownTitle
                if title == nil, let exe {
                    title = Self.fetchTitle(executable: exe, sessionID: sid)
                }
                let cmd = "opencode · \(title ?? "session …\(sid.suffix(6))")"
                Self.log("emitting task event: \(cmd) (dur \(dur)s, exit \(exit))")
                EventStore.append(AgentEvent(
                    id: UUID().uuidString,
                    source: "opencode",
                    cmd: cmd,
                    exit: exit,
                    dur: dur,
                    cwd: cwd,
                    tty: nil,
                    ts: Date().timeIntervalSince1970
                ))
            }
        } else if type == "session.created" {
            if cwdCache.count > 200 { cwdCache.removeAll(); titleCache.removeAll() }
            if let loc = payload["location"] as? [String: Any],
               let dir = loc["directory"] as? String {
                cwdCache[sessionID] = dir
            }
        } else if type == "session.renamed" {
            if let title = payload["title"] as? String, !title.isEmpty {
                titleCache[sessionID] = title
            }
        }
    }

    private static func fetchTitle(executable: String, sessionID: String) -> String? {
        guard let obj = runJSON(executable, ["api", "get", "/api/session/\(sessionID)"]) else { return nil }
        let session = (obj["data"] as? [String: Any]) ?? obj
        guard let title = session["title"] as? String, !title.isEmpty else { return nil }
        return title
    }

    private static func runJSON(_ executable: String, _ args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj
    }
}
