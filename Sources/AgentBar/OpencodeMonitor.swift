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
    // Main-thread state
    private var process: Process?        // the curl subprocess
    private var retryWorkItem: DispatchWorkItem?

    private let queue = DispatchQueue(label: "agentbar.opencode")
    // queue-protected state
    private var resolvedPath: String?    // opencode binary
    private var buffer: [UInt8] = []
    private var busy: [String: Date] = [:]           // sessionID -> execution started
    private var cwdCache: [String: String] = [:]     // sessionID -> directory (event envelope location)
    private var titleCache: [String: String] = [:]   // sessionID -> title (from session.renamed)

    /// Ignore tasks shorter than this — quick Q&A shouldn't page you.
    private let minTaskSeconds = 2

    /// Called on the main thread when the number of executing opencode
    /// sessions changes (drives the "running" counter).
    var onBusyChanged: ((Int) -> Void)?
    /// Called on the main thread for each usage event (tokens/cost delta).
    var onUsageDelta: ((Usage) -> Void)?

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

    /// Always hops to the main thread so `retryWorkItem` has a single owner.
    private func scheduleRetry(_ delay: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.retryWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.connect() }
            self.retryWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: item)
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
            self.queue.sync { self.resolvedPath = exe }
            guard let (baseURL, password) = self.discoverService(exe: exe) else {
                Self.log("service discovery failed; retrying in 15s")
                self.scheduleRetry(15)   // service not reachable; it may appear later
                return
            }
            Self.log("opening stream at \(baseURL)")
            DispatchQueue.main.async { self.openStream(baseURLString: baseURL, password: password) }
        }
    }

    private func opencodePath() -> String? {
        queue.sync { resolvedPath } ?? Self.resolveOpencodePath()
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
        p.arguments = ["-sN", "-K", "-"]   // config (URL + credentials) arrives on stdin
        let outPipe = Pipe()
        let inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        p.standardInput = inPipe

        let startedAt = Date()
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.process = nil
                self.queue.async {
                    self.buffer.removeAll()
                    self.busy.removeAll()
                    self.reportBusy()
                }
                // Fast exit means something is wrong (bad URL, service down):
                // back off. Slow exit means the service restarted: reconnect fast.
                let delay: TimeInterval = Date().timeIntervalSince(startedAt) < 2 ? 30 : 5
                self.scheduleRetry(delay)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }
        // Passing the password as an argv (-u) would expose it in `ps`.
        let config = "user = \"opencode:\(Self.curlEscaped(password))\"\n"
            + "url = \"\(Self.curlEscaped(baseURLString + "/api/event"))\"\n"
            + "silent\nno-buffer\n"
        do {
            // Assign before run so a subprocess that exits immediately finds
            // `process === p` and can reschedule.
            process = p
            try p.run()
            inPipe.fileHandleForWriting.write(Data(config.utf8))
            try? inPipe.fileHandleForWriting.close()
            Self.log("stream running (pid \(p.processIdentifier))")
        } catch {
            Self.log("failed to launch curl: \(error)")
            process = nil
            scheduleRetry(30)
        }
    }

    /// Escapes a value for a curl config file string (backslash and quote).
    private static func curlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
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

        // The working directory travels on the event envelope for every
        // session event, so remember it whenever we see it (not only on
        // session.created, which we miss for sessions started before launch).
        if let loc = obj["location"] as? [String: Any],
           let dir = loc["directory"] as? String, !dir.isEmpty {
            if cwdCache.count > 200 && cwdCache[sessionID] == nil { cwdCache.removeAll() }
            cwdCache[sessionID] = dir
        }

        let now = Date()
        if type == "session.execution.started" {
            busy[sessionID] = now
            reportBusy()
            Self.log("execution started: \(sessionID)")
        } else if type.hasPrefix("session.execution.") {
            // succeeded / failed / interrupted: the task is done
            guard let started = busy[sessionID] else {
                Self.log("execution ended but no start recorded: \(type) \(sessionID)")
                return
            }
            busy.removeValue(forKey: sessionID)
            reportBusy()
            let dur = Int(now.timeIntervalSince(started))
            guard dur >= minTaskSeconds else { return }
            let exit = type == "session.execution.succeeded" ? 0 : 1
            let cwd = cwdCache[sessionID]
            let knownTitle = titleCache[sessionID]
            let exe = resolvedPath
            let sid = sessionID
            // Title lookup shells out to the CLI; keep it off the event queue
            // so it can't stall processing of the live stream.
            DispatchQueue.global(qos: .utility).async {
                let details = exe.map { Self.fetchDetails(executable: $0, sessionID: sid) }
                let title = knownTitle ?? details?.title
                let preview = details?.prompt ?? title ?? "session …\(sid.suffix(6))"
                let cmd = "opencode · \(title ?? preview)"
                Self.log("emitting task event: \(cmd) (dur \(dur)s, exit \(exit))")
                EventStore.append(AgentEvent(
                    id: UUID().uuidString,
                    source: "opencode",
                    cmd: cmd,
                    exit: exit,
                    dur: dur,
                    cwd: cwd ?? details?.directory,
                    tty: nil,
                    ts: Date().timeIntervalSince1970,
                    harness: "opencode",
                    model: details?.model,
                    preview: preview
                ))
            }
        } else if type == "session.renamed" {
            if let title = payload["title"] as? String, !title.isEmpty {
                if titleCache.count > 200 && titleCache[sessionID] == nil { titleCache.removeAll() }
                titleCache[sessionID] = title
            }
        } else if type == "session.usage.updated" {
            if let usage = Self.parseUsage(payload) {
                Self.log("usage +\(usage.totalTokens) tokens (cost \(usage.cost))")
                DispatchQueue.main.async { [weak self] in
                    self?.onUsageDelta?(usage)
                }
            }
        }
    }

    /// Each usage event carries the tokens/cost of one model request — they
    /// accumulate into the daily total.
    private static func parseUsage(_ payload: [String: Any]) -> Usage? {
        var usage = Usage(date: Usage.today)
        usage.cost = payload["cost"] as? Double ?? 0
        guard let tokens = payload["tokens"] as? [String: Any] else { return nil }
        usage.input = tokens["input"] as? Int ?? 0
        usage.output = tokens["output"] as? Int ?? 0
        usage.reasoning = tokens["reasoning"] as? Int ?? 0
        if let cache = tokens["cache"] as? [String: Any] {
            usage.cacheRead = cache["read"] as? Int ?? 0
        }
        guard usage.totalTokens > 0 || usage.cost > 0 else { return nil }
        return usage
    }

    private func reportBusy() {
        let count = busy.count
        DispatchQueue.main.async { [weak self] in
            self?.onBusyChanged?(count)
        }
    }

    private struct SessionDetails {
        var title: String?
        var model: String?
        var prompt: String?     // newest user message
        var directory: String?  // session working directory
    }

    private static func fetchDetails(executable: String, sessionID: String) -> SessionDetails {
        var details = SessionDetails()
        if let obj = runJSON(executable, ["api", "get", "/api/session/\(sessionID)"]) {
            let session = (obj["data"] as? [String: Any]) ?? obj
            if let title = session["title"] as? String, !title.isEmpty { details.title = title }
            if let model = session["model"] as? [String: Any],
               let id = model["id"] as? String, !id.isEmpty { details.model = id }
            if let loc = session["location"] as? [String: Any],
               let dir = loc["directory"] as? String, !dir.isEmpty { details.directory = dir }
        }
        // Messages come newest first, so the first user message is the latest prompt.
        if let obj = runJSON(executable, ["api", "get", "/api/session/\(sessionID)/message"]),
           let messages = obj["data"] as? [[String: Any]],
           let user = messages.first(where: { ($0["type"] as? String) == "user" }),
           let text = user["text"] as? String {
            let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !flat.isEmpty { details.prompt = flat }
        }
        return details
    }

    private static func runJSON(_ executable: String, _ args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        // The CLI truncates large responses when stdout is a pipe (~8 KB), so
        // capture into a file instead.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let out = try? FileHandle(forWritingTo: tmp) else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { try? out.close(); return nil }
        p.waitUntilExit()
        try? out.close()
        guard let data = try? Data(contentsOf: tmp), p.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj
    }
}
