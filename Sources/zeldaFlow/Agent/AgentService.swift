import Foundation

/// Bridge to the Claude Code CLI (`claude -p`) — zeldaFlow's heavy-duty brain
/// for work the local models can't do: seeing the screen, multi-step
/// GitHub/dev tasks, real analysis. Design rules:
/// - one agent process at a time, always cancellable;
/// - the CLI is only ever launched from an explicit user command — and
///   background tasks additionally require the user's Fn-tap confirmation;
/// - everything the agent prints is logged to agent.log for audit.
final class AgentService {
    static let shared = AgentService()

    struct AgentResult {
        let ok: Bool
        let text: String
        let durationSeconds: Int
    }

    /// Label of the running background task, for the menu bar. Main-thread.
    private(set) var runningTaskLabel: String?

    /// Guards `process` and `busy` — the run blocks its own GCD thread, and
    /// cancel()/isRunning must never wait on it.
    private let lock = NSLock()
    /// runBlocking's home: GCD overcommits, so parking here for the length
    /// of an agent run never starves the Swift cooperative pool.
    private static let runQueue = DispatchQueue(label: "zeldaflow.agent", qos: .userInitiated)
    private var process: Process?
    private var busy = false
    /// Set when cancel() lands before the Process is published — the launch
    /// path re-checks it so an early "stop the agent" is never lost.
    private var cancelRequested = false

    private init() {}

    /// The Claude Code CLI, wherever the user's installer put it — fixed
    /// locations first, then the login shell's PATH (covers nvm/volta/asdf
    /// installs that a GUI app's bare PATH misses).
    static var claudeBinary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Paths.findExecutable("claude", candidates: [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ])
    }

    static var isAvailable: Bool { claudeBinary != nil }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return busy
    }

    /// Synchronous lock helpers — NSLock must not be taken directly inside
    /// async functions (Swift 6 rule); these keep the critical sections tiny.
    private func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy { return false }
        busy = true
        cancelRequested = false
        return true
    }

    private func releaseBusy() {
        lock.lock(); busy = false; lock.unlock()
    }

    /// Run one headless agent invocation and return its final answer.
    /// `allowedTools` is the whole safety story: screen analysis gets [Read],
    /// background tasks get the full kit only after the user's Fn confirmation.
    func run(prompt: String, allowedTools: [String], model: String,
             timeout: TimeInterval, label: String? = nil,
             workingDirectory: String? = nil) async -> AgentResult {
        guard let binary = Self.claudeBinary else {
            return AgentResult(ok: false,
                               text: "Claude Code CLI not found — install it from claude.com/claude-code",
                               durationSeconds: 0)
        }
        guard tryAcquire() else {
            return AgentResult(ok: false, text: "An agent task is already running", durationSeconds: 0)
        }

        await MainActor.run { self.runningTaskLabel = label }
        defer {
            releaseBusy()
            Task { @MainActor in self.runningTaskLabel = nil }
        }

        let started = Date()
        // A dedicated GCD queue, not Task.detached: runBlocking sits in
        // blocking pipe reads for up to the full task timeout, which would
        // pin a Swift cooperative-pool thread the whole time.
        let result: (ok: Bool, text: String) = await withCheckedContinuation { cont in
            Self.runQueue.async {
                cont.resume(returning: self.runBlocking(
                    binary: binary, prompt: prompt, allowedTools: allowedTools,
                    model: model, timeout: timeout,
                    workingDirectory: workingDirectory))
            }
        }
        return AgentResult(ok: result.ok, text: result.text,
                           durationSeconds: Int(Date().timeIntervalSince(started)))
    }

    /// Terminate the running agent, if any.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelRequested = true
        if let p = process {
            Log.info("AgentService: cancelled by user")
            p.terminate()
        }
    }

    // MARK: - Blocking implementation (runs on runQueue)

    private func runBlocking(binary: String, prompt: String, allowedTools: [String],
                             model: String, timeout: TimeInterval,
                             workingDirectory: String?) -> (ok: Bool, text: String) {
        let runStarted = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--allowedTools", allowedTools.joined(separator: ","),
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        p.currentDirectoryURL = URL(fileURLWithPath: workingDirectory ?? home)

        // GUI apps get a bare PATH; the agent's Bash tool needs brew + the
        // user's own bins to be useful. The login shell's PATH covers
        // whatever manager installed their tools.
        var env = ProcessInfo.processInfo.environment
        var extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
                     URL(fileURLWithPath: binary).deletingLastPathComponent().path]
        if let shellPath = Paths.loginShellPATH { extra.append(shellPath) }
        let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extra + [base]).joined(separator: ":")
        p.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        p.standardInput = FileHandle.nullDevice

        let agentLog = openAgentLog()
        defer { try? agentLog?.close() }
        func log(_ line: String) {
            if let data = (line + "\n").data(using: .utf8) {
                try? agentLog?.write(contentsOf: data)
            }
        }
        log("=== \(Date()) model=\(model) tools=\(allowedTools.joined(separator: ",")) ===")
        log("prompt: \(prompt.prefix(500))")

        // Drain stderr concurrently — a full pipe would stall the CLI.
        var errData = Data()
        let errLock = NSLock()
        stderr.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            errLock.lock(); errData.append(chunk); errLock.unlock()
        }

        do {
            try p.run()
        } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            return (false, "Couldn't launch the agent: \(error.localizedDescription)")
        }
        lock.lock()
        process = p
        let cancelledEarly = cancelRequested
        lock.unlock()
        if cancelledEarly { p.terminate() }

        // Watchdog on an independent queue: SIGTERM at the deadline unblocks
        // the reader below via EOF.
        let watchdog = DispatchWorkItem { [weak p] in
            Log.error("AgentService: timeout after \(Int(timeout)) s — terminating")
            p?.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                       execute: watchdog)

        // Read stream-json line by line, keeping the final "result" event.
        var finalText: String?
        var isError = false
        let reader = stdout.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }   // EOF
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: nl)
                buffer.removeSubrange(...nl)
                guard let line = String(data: lineData, encoding: .utf8),
                      !line.isEmpty else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any] else { continue }
                let type = obj["type"] as? String
                // Audit log keeps the narrative, never raw payloads: tool
                // results can embed the base64 screenshot or command output
                // with secrets — those must not be persisted to disk.
                switch type {
                case "user":
                    log("[tool result omitted]")
                case "result":
                    finalText = obj["result"] as? String
                    isError = (obj["is_error"] as? Bool) ?? false
                    log("result: is_error=\(isError) \(String((finalText ?? "").prefix(1000)))")
                default:
                    log(String(line.prefix(1500)))
                }
            }
        }
        p.waitUntilExit()
        watchdog.cancel()
        lock.lock(); process = nil; lock.unlock()
        stderr.fileHandleForReading.readabilityHandler = nil

        errLock.lock()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        errLock.unlock()
        if !errText.isEmpty { log("stderr: \(errText.prefix(2000))") }

        if let finalText, !finalText.isEmpty {
            log("=== done ok=\(!isError) in \(Int(Date().timeIntervalSince(runStarted))) s " +
                "(budget \(Int(timeout)) s) ===")
            return (!isError, finalText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if p.terminationReason == .uncaughtSignal {
            return (false, "Agent stopped (timeout or cancelled)")
        }
        let hint = errText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, hint.isEmpty
                ? "Agent produced no result (exit \(p.terminationStatus)) — see agent.log"
                : String(hint.prefix(200)))
    }

    private func openAgentLog() -> FileHandle? {
        let url = Paths.agentLogFile
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }
}
