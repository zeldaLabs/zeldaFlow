import Foundation
import Darwin

/// Supervises a resident llama-server (Homebrew llama.cpp) running Gemma 4 E2B
/// and exposes a single `cleanup(text:)` call. Design rules:
/// - cleanup must never block dictation — any failure or slow response falls
///   back to the raw text;
/// - all supervisor state (process, generation, restart counter) is confined
///   to the serial `queue`; the @Published `status` mirror is main-thread-only
///   and exists purely for the UI.
final class CleanupService: ObservableObject {
    enum Status: Equatable {
        case disabled          // mode != .full, or binary/model missing
        case starting
        case ready
        case failed(String)
    }

    /// UI mirror — read/written on the main thread only.
    @Published private(set) var status: Status = .disabled

    // Queue-confined state.
    private var statusQ: Status = .disabled
    private var process: Process?
    private var ownsServer = false
    private var generation = 0
    private var stopped = true
    private var restartCount = 0

    private let port: Int
    private let session: URLSession
    private let commandSession: URLSession
    private let queue = DispatchQueue(label: "zeldaflow.cleanup", qos: .userInitiated)

    /// Hard ceiling; typical Gemma E2B cleanup of a 50-word transcript is ~0.5 s.
    private let requestTimeout: TimeInterval = 8
    /// Command mode generates whole documents — allow much longer.
    private let commandTimeout: TimeInterval = 60

    init(port: Int) {
        self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        session = URLSession(configuration: config)

        let cmdConfig = URLSessionConfiguration.ephemeral
        cmdConfig.timeoutIntervalForRequest = commandTimeout
        cmdConfig.timeoutIntervalForResource = commandTimeout
        commandSession = URLSession(configuration: cmdConfig)
    }

    var endpoint: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Thread-safe snapshot (used by the self-test; UI uses `status`).
    var statusSnapshot: Status { queue.sync { statusQ } }

    // MARK: - Lifecycle

    func start() {
        queue.async { self.startLocked() }
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    /// Synchronous stop for app termination — the async variant may never run.
    func stopSync() {
        queue.sync { self.stopLocked() }
    }

    private func startLocked() {
        guard Paths.llamaServerBinary != nil else {
            setStatus(.failed("llama-server not found — brew install llama.cpp"))
            return
        }
        guard Paths.cleanupModelExists else {
            setStatus(.failed("Gemma model missing at \(Paths.cleanupModel.path)"))
            return
        }
        guard stopped else { return }  // already running or starting
        stopped = false
        generation += 1
        restartCount = 0
        setStatus(.starting)
        launchLocked(generation: generation)
    }

    private func stopLocked() {
        stopped = true
        generation += 1
        if let p = process {
            p.terminationHandler = nil
            p.terminate()
        }
        process = nil
        if ownsServer { removePidFile() }
        ownsServer = false
        setStatus(.disabled)
    }

    private func launchLocked(generation gen: Int) {
        guard gen == generation, !stopped else { return }
        guard let binary = Paths.llamaServerBinary else { return }

        // Reap an orphan from a previous run that crashed before cleanup.
        killStaleServerFromPidFile()

        // If the port is still busy it's someone else's server — adopt it
        // (use, but never kill) rather than fight over the port.
        if healthCheckSync() {
            Log.info("CleanupService: adopting existing llama-server on :\(port)")
            ownsServer = false
            warmUpAndMarkReady(generation: gen)
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = [
            "-m", Paths.cleanupModel.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-ngl", "99",
            "--ctx-size", "4096",
            "--jinja",
            "--no-webui",
        ]
        let logHandle = openLlamaLog()
        p.standardOutput = logHandle
        p.standardError = logHandle
        p.terminationHandler = { [weak self] proc in
            logHandle?.closeFile()
            guard let self else { return }
            self.queue.async {
                self.processDidTerminate(proc, generation: gen)
            }
        }

        do {
            try p.run()
            process = p
            ownsServer = true
            writePidFile(p.processIdentifier)
            Log.info("CleanupService: launched llama-server pid \(p.processIdentifier)")
        } catch {
            setStatus(.failed("Could not launch llama-server: \(error.localizedDescription)"))
            return
        }

        // Poll /health until the model is loaded (first launch compiles Metal
        // shaders and mmaps ~2.9 GB; give it time).
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            guard gen == generation, !stopped else { return }
            if healthCheckSync() {
                restartCount = 0
                warmUpAndMarkReady(generation: gen)
                return
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        setStatus(.failed("llama-server did not become healthy in 120 s"))
    }

    private func processDidTerminate(_ proc: Process, generation gen: Int) {
        guard gen == generation, !stopped else { return }  // stale or intentional
        Log.error("CleanupService: llama-server exited (code \(proc.terminationStatus))")
        process = nil
        removePidFile()
        restartCount += 1
        if restartCount <= 3 {
            let delay = Double(restartCount) * 2
            setStatus(.starting)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, gen == self.generation, !self.stopped else { return }
                self.launchLocked(generation: gen)
            }
        } else {
            setStatus(.failed("llama-server keeps crashing — see llama-server.log"))
        }
    }

    private func warmUpAndMarkReady(generation gen: Int) {
        // First generation after load compiles kernels; do it now, not on the
        // user's first dictation.
        _ = chatSync(system: "Reply with OK.", user: "OK?", maxTokens: 8, session: session)
        guard gen == generation, !stopped else { return }
        setStatus(.ready)
        Log.info("CleanupService: ready on :\(port)")
    }

    // MARK: - Pidfile (orphan reaping across app crashes)

    private var pidFile: URL { Paths.appSupport.appendingPathComponent("llama-server.pid") }

    private func writePidFile(_ pid: Int32) {
        try? String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func killStaleServerFromPidFile() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, kill(pid, 0) == 0 else {
            removePidFile()
            return
        }
        // Verify it's actually a llama-server before killing (pid reuse).
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = n > 0 ? String(cString: buffer) : ""
        if path.contains("llama-server") {
            Log.info("CleanupService: reaping orphaned llama-server pid \(pid)")
            kill(pid, SIGTERM)
            for _ in 0..<20 where kill(pid, 0) == 0 {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        removePidFile()
    }

    private func openLlamaLog() -> FileHandle? {
        let url = Paths.llamaLogFile
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }

    // MARK: - Cleanup call

    /// Returns cleaned text, or nil when the caller should fall back to raw.
    func cleanup(_ text: String, dictionary: [String]) async -> String? {
        // The server runs with a 4096-token context. A transcript past
        // ~4,500 chars (plus prompt and output budget) no longer fits, and
        // the model returns only the first chunk — silently losing the rest
        // of the user's words. Long dictations keep every word and get
        // light cleanup instead. (Found by the 12-minute dictation stress
        // test: a 13k-char transcript came back as 1.4k chars.)
        guard text.count <= 4500 else {
            Log.info("CleanupService: \(text.count) chars exceeds the cleanup " +
                     "context budget — falling back to light cleanup")
            return nil
        }
        let system = Self.systemPrompt(dictionary: dictionary)
        let started = Date()
        let result: String? = await withCheckedContinuation { cont in
            queue.async {
                guard self.statusQ == .ready else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: self.chatSync(system: system, user: text,
                                                     maxTokens: max(128, text.count / 2),
                                                     session: self.session))
            }
        }
        guard var cleaned = result else { return nil }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip wrapping quotes some models add.
        if cleaned.hasPrefix("\""), cleaned.hasSuffix("\""), cleaned.count > 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        // Sanity: reject empty output, runaway rewrites, and truncation —
        // cleanup trims fillers, it never legitimately drops two-thirds of
        // the text. A suspicious shrink means the model ran out of context
        // or gave up mid-output; the raw transcript is the safer result.
        guard !cleaned.isEmpty, cleaned.count <= text.count * 3 + 80,
              cleaned.count * 3 >= text.count else {
            if let c = result?.count, c * 3 < text.count {
                Log.error("CleanupService: output \(cleaned.count) chars for " +
                          "\(text.count)-char input looks truncated — using raw text")
            }
            return nil
        }
        Log.info("CleanupService: cleaned \(text.count)→\(cleaned.count) chars in " +
                 "\(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return cleaned
    }

    // MARK: - Command mode

    private struct CommandReply: Decodable {
        let actions: [ZeldaFlowAction]
    }

    /// Block until the model is serving (starting it if needed) — command
    /// mode depends on the LLM even when cleanup is set to Off/Light.
    func ensureReady(timeoutSeconds: Double) async -> Bool {
        if statusSnapshot == .ready { return true }
        start()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            switch statusSnapshot {
            case .ready: return true
            case .failed: return false
            default: try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return false
    }

    /// One-line offline answer for math, conversions, and stable facts.
    /// Returns nil when the model isn't certain or the question needs live
    /// data — the caller then falls back to a web search.
    func instantAnswer(question: String) async -> String? {
        let system = """
        You answer short factual and mathematical questions. If the question is arithmetic, a unit conversion, a date/time calculation, a definition, or a stable well-known fact you are CERTAIN of, reply with ONE short line containing just the answer (include units). If it needs current or live data (news, sports scores, weather, prices, anything about "today" or "now"), involves a person or event you are not completely sure about, or you have ANY doubt — reply with exactly: SEARCH
        """
        let reply: String? = await withCheckedContinuation { cont in
            queue.async {
                guard self.statusQ == .ready else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: self.chatSync(system: system, user: question,
                                                     maxTokens: 90,
                                                     session: self.session))
            }
        }
        guard var answer = reply?.trimmingCharacters(in: .whitespacesAndNewlines),
              !answer.isEmpty else { return nil }
        if answer.hasPrefix("\""), answer.hasSuffix("\""), answer.count > 2 {
            answer = String(answer.dropFirst().dropLast())
        }
        guard !answer.uppercased().contains("SEARCH"), answer.count <= 220 else { return nil }
        return answer
    }

    /// Follow-up turns in the pill's chat note when the Claude CLI can't take
    /// them. One completion over a rendered transcript — the 4k context is
    /// why the history arrives pre-trimmed and gets a hard suffix cap here.
    func chatReply(conversation: String) async -> String? {
        let system = """
        You are zeldaFlow's chat assistant on the user's Mac. Continue the conversation: answer the user's last message directly, in 1-4 short sentences. Earlier turns describing what was on the user's screen are accurate notes. If you don't know, say so briefly — never invent specifics.
        """
        let trimmed = String(conversation.suffix(3000))
        let reply: String? = await withCheckedContinuation { cont in
            queue.async {
                guard self.statusQ == .ready else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: self.chatSync(system: system, user: trimmed,
                                                     maxTokens: 220,
                                                     session: self.commandSession))
            }
        }
        guard let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// Speak-to-Edit: apply a spoken instruction to selected text.
    func rewrite(text: String, instruction: String) async -> String? {
        let system = """
        You edit text. Apply the instruction to the text and output ONLY the resulting text — no preamble, no explanations, no wrapping quotes or code fences. Preserve the original language and script unless the instruction says to translate. Keep facts, names, numbers and links intact unless the instruction asks to change them.
        """
        let user = "Instruction: \(instruction)\n\nText:\n\(text)"
        let reply: String? = await withCheckedContinuation { cont in
            queue.async {
                guard self.statusQ == .ready else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: self.chatSync(system: system, user: user,
                                                     maxTokens: max(300, text.count),
                                                     session: self.commandSession))
            }
        }
        guard var out = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            return nil
        }
        if out.hasPrefix("```"), out.hasSuffix("```") {
            out = out.dropFirst(3).drop(while: { $0 != "\n" }).dropLast(3)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if out.hasPrefix("\""), out.hasSuffix("\""), out.count > 2 {
            out = String(out.dropFirst().dropLast())
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Meeting notes

    /// One map-reduce step for meeting notes: schema-constrained when `schema`
    /// is given, free text otherwise (the summary/title passes). Runs on the
    /// same serial queue as everything else — MeetingNotesGenerator submits
    /// ONE call at a time and pauses between calls while the user dictates,
    /// so a dictation cleanup only ever waits behind the in-flight call.
    func structured(system: String, user: String, maxTokens: Int,
                    schema: JSONValue? = nil, schemaName: String = "notes",
                    temperature: Double = 0) async -> String? {
        await withCheckedContinuation { cont in
            queue.async {
                guard self.statusQ == .ready else { cont.resume(returning: nil); return }
                cont.resume(returning: self.chatSync(system: system, user: user,
                                                     maxTokens: maxTokens,
                                                     session: self.commandSession,
                                                     schema: schema, schemaName: schemaName,
                                                     temperature: temperature))
            }
        }
    }

    /// Turn a spoken command transcript into one or more structured actions.
    /// `nowString` / `todayString` ground relative dates ("tomorrow at 5").
    func interpretCommand(_ transcript: String, frontApp: String,
                          nowString: String, todayString: String,
                          menuCandidates: [String] = [],
                          controlCandidates: [String] = []) async -> [ZeldaFlowAction]? {
        var system = Self.commandSystemPrompt(frontApp: frontApp,
                                              nowString: nowString, todayString: todayString)

        // Everything below is appended to a ~1750-token base prompt inside a
        // 4096-token context that also has to hold the reply. Handing the model
        // every menu item, every control and all 200-odd installed apps would
        // overflow it — and llama-server doesn't fail loudly when it does, it
        // just truncates. So each block gets a slice of one budget, and what
        // doesn't fit is dropped deliberately rather than silently.
        var remaining = Self.contextExtrasBudget

        func append(_ header: String, _ items: [String], share: Int) {
            guard !items.isEmpty, remaining > 200 else { return }
            var block = ""
            let cap = min(share, remaining - header.count - 8)
            var used = 0
            var kept = 0
            for item in items {
                guard used + item.count + 1 <= cap else { break }
                block += item + "\n"
                used += item.count + 1
                kept += 1
            }
            guard kept > 0 else { return }
            if kept < items.count {
                Log.info("command prompt: kept \(kept)/\(items.count) of \(header.prefix(24))…")
            }
            system += "\n\n" + header + "\n" + block
            remaining -= header.count + used + 3
        }

        // The frontmost app's own commands, as a closed set to choose from.
        // This is what lets "do X in this app" work without a template per app
        // — and because the list comes from the live menu bar, the model can
        // only pick something that genuinely exists.
        append("""
            The frontmost app (\(frontApp)) currently offers these menu commands. If the user \
            is asking for one of them, reply {"actions":[{"action":"ui_command","text":"<exact \
            path from the list>"}]} and copy the path verbatim. If none fits, ignore this list.
            """, menuCandidates, share: 900)

        // The window's own controls, for what a menu can't reach — a search
        // box, a Get button. Same closed-set rule: only what's on screen.
        append("""
            The frontmost window also shows these controls. To click one, reply \
            {"actions":[{"action":"ui_click","text":"<exact label>"}]}. To put text in a field, \
            reply {"actions":[{"action":"ui_type","target":"<exact field label>","text":"<what \
            to type>"}]}. Copy labels verbatim; if none fits, ignore this list.
            """, controlCandidates, share: 700)

        // Installed apps, read from this Mac rather than baked into the build,
        // so iPhone Mirroring and anything else the user has are real options.
        // Filtered to what the sentence could plausibly mean: naming all 200 is
        // both useless to the model and the single biggest budget hog.
        append("Apps installed on this Mac that the user may be naming:",
               Self.relevantApps(to: transcript), share: 400)
        let reply: String? = await withCheckedContinuation { cont in
            queue.async {
                guard self.statusQ == .ready else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: self.chatSync(system: system, user: transcript,
                                                     maxTokens: 2000,
                                                     session: self.commandSession))
            }
        }
        guard let reply else { return nil }
        // Extract the outermost JSON object (models occasionally add prose/fences).
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"), start < end else {
            Log.error("interpretCommand: no JSON in reply: \(reply.prefix(200))")
            return nil
        }
        let json = String(reply[start...end])
        let data = Data(json.utf8)
        if let parsed = try? JSONDecoder().decode(CommandReply.self, from: data) {
            return parsed.actions
        }
        // Small models often drop the {"actions":[…]} wrapper — salvage a
        // bare action object or a bare array before giving up.
        if let single = try? JSONDecoder().decode(ZeldaFlowAction.self, from: data),
           !single.action.isEmpty {
            Log.info("interpretCommand: salvaged bare action \(single.action)")
            return [single]
        }
        if let arrStart = reply.firstIndex(of: "["), let arrEnd = reply.lastIndex(of: "]"),
           arrStart < arrEnd,
           let arr = try? JSONDecoder().decode([ZeldaFlowAction].self,
                                               from: Data(String(reply[arrStart...arrEnd]).utf8)),
           !arr.isEmpty {
            Log.info("interpretCommand: salvaged bare action array (\(arr.count))")
            return arr
        }
        Log.error("interpretCommand: bad JSON: \(json.prefix(300))")
        return nil
    }

    // MARK: - Multi-step task planning

    /// Both planner prompts are constants with nothing interpolated, so the KV
    /// cache hits on every step of a task instead of re-evaluating ~300 tokens
    /// each time.
    private static let selectPrompt = """
        Pick the single best next step to finish the task.
        You are given the goal, what is on screen, and a numbered list of the ONLY steps available.
        Reply with JSON {"n": <number>} and nothing else.
        """

    private static let fieldTextPrompt = """
        Extract the exact text to type into the named field to accomplish the task.
        Reply with JSON {"text": "..."} and nothing else. Keep it short - just the search words.
        """

    /// Choose one of the offered steps, by index.
    ///
    /// The model picks a number and nothing else. Free-form step generation was
    /// measured at 3/6 on realistic screens — it invents labels, and when the
    /// chain-of-thought runs long it returns empty content — while a
    /// schema-constrained index scored 4/6 and never once fell out of range in
    /// 20 trials. What it selects from is built deterministically from live
    /// Accessibility data, so a wrong pick is a wasted step, never a wrong
    /// click on something that wasn't offered.
    func selectStep(observation: String, options: [String]) async -> Int? {
        let menu = options.enumerated().map { "\($0.offset). \($0.element)" }
            .joined(separator: "\n")
        let schema = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["n": .object(["type": .string("integer")])]),
            "required": .array([.string("n")]),
            "additionalProperties": .bool(false),
        ])
        let reply: String? = await withCheckedContinuation { cont in
            queue.async {
                guard self.statusQ == .ready else { cont.resume(returning: nil); return }
                // Generous, because the budget is shared with a chain-of-thought
                // we cannot switch off: measured up to ~470 completion tokens
                // for a choice whose answer is six characters long.
                cont.resume(returning: self.chatSync(
                    system: Self.selectPrompt,
                    user: observation + "\nSTEPS AVAILABLE:\n" + menu,
                    maxTokens: 600, session: self.commandSession,
                    schema: schema, schemaName: "step"))
            }
        }
        guard let reply, let data = reply.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = obj["n"] as? Int, options.indices.contains(n) else { return nil }
        return n
    }

    /// What to type into a named field to serve the goal. Measured 6/6.
    func fieldText(goal: String, field: String, app: String) async -> String? {
        let schema = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["text": .object(["type": .string("string")])]),
            "required": .array([.string("text")]),
            "additionalProperties": .bool(false),
        ])
        let reply: String? = await withCheckedContinuation { cont in
            queue.async {
                guard self.statusQ == .ready else { cont.resume(returning: nil); return }
                cont.resume(returning: self.chatSync(
                    system: Self.fieldTextPrompt,
                    user: "TASK: \(goal)\nAPP: \(app)\nFIELD: \(field)",
                    maxTokens: 500, session: self.commandSession,
                    schema: schema, schemaName: "fieldtext"))
            }
        }
        guard let reply, let data = reply.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Characters available for the live context blocks appended to the command
    /// prompt. The base prompt is ~7000 characters and the reply needs room in
    /// the same 4096-token window, so this is what's left over with margin.
    private static let contextExtrasBudget = 2000

    /// Installed apps whose name shares a word with what the user said.
    ///
    /// "open iPhone Mirroring" returns the one app that matters; "make it bold"
    /// returns nothing and costs nothing. Naming all 200 would crowd out the
    /// menu and control lists, which are far more likely to be what's needed.
    static func relevantApps(to transcript: String) -> [String] {
        let words = Set(transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 })
        guard !words.isEmpty else { return [] }
        return AppResolver.installedApps().filter { app in
            let appWords = app.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            return appWords.contains { words.contains($0) }
        }.prefix(12).map { $0 }
    }

    static func commandSystemPrompt(frontApp: String, nowString: String, todayString: String) -> String {
        """
        You are zeldaFlow, a voice-command interpreter and assistant on the user's Mac. \
        Convert the spoken command into JSON: {"actions":[ ... ]} — an ordered list of one or more action objects. \
        Output ONLY the JSON object, no markdown, no commentary. Each action is one of:

        {"action":"open_app","app":"<App Name>"} — launch/switch to the Mac app the user NAMED: "open safari" -> "Safari", "open chrome" -> "Google Chrome", "open settings" -> "System Settings". NEVER substitute a different app than the one they said.
        {"action":"close_app","app":"<App Name>"} — quit a running app ("close safari", "quit music").
        {"action":"navigate","destination":"<place>","transport":"drive|walk|transit"} — directions in Apple Maps from the user's current location, route starts automatically. Use for ANY "open maps and go to X" / "navigate to X" / "take me to X" / "how do I get to X" request. Default transport: drive.
        {"action":"open_url","url":"https://…"} — open a website the user named ("open youtube" -> https://www.youtube.com). For searches and questions use web_answer instead.
        {"action":"type_text","text":"<full content>"} — WRITE/FILL content at the user's cursor (documents, PRD/BRD, essays, code, replies). Generate the COMPLETE requested content with real newlines. For documents/templates use Markdown structure (# title, ## sections, - bullets, **bold** terms) — zeldaFlow renders it as rich formatted text. Casual text stays plain prose.
        {"action":"edit_text","text":"<the editing instruction>"} — user wants to CHANGE text they have SELECTED on screen: "make this shorter", "fix the grammar", "translate this to French", "turn this into bullet points". Put their instruction in "text" — zeldaFlow grabs the selection itself.
        {"action":"play_music","song":"…","artist":"…","playlist":"…","service":"…"} — play music. zeldaFlow routes to the right music app on this Mac (Apple Music or Spotify); set "service" ONLY when the user names one ("on spotify" -> "spotify"). Include ONLY the fields the user actually named and OMIT the rest — never output empty strings. "play bohemian rhapsody by queen" -> {"song":"Bohemian Rhapsody","artist":"Queen"}; "play some coldplay songs" -> {"artist":"Coldplay"}; "play my gym playlist" -> {"playlist":"gym"}; "play some music" -> no fields.
        {"action":"music_control","command":"pause|play|next|previous"} — control playback.
        {"action":"set_volume","level":0-100} or {"action":"set_volume","mute":true|false} — system volume.
        {"action":"send_email","to":"<name or address>","subject":"<subject>","body":"<full email body>"} — send an email. Write a complete, well-formed body.
        {"action":"draft_email","to":"…","subject":"…","body":"…"} — prepare an email but DON'T send (use when the user says "draft"/"prepare").
        {"action":"send_message","to":"<name or number>","body":"<message text>"} — send an iMessage.
        {"action":"add_reminder","title":"<what>","date":"<YYYY-MM-DD HH:MM optional>"} — add a Reminder.
        {"action":"create_event","title":"<what>","date":"YYYY-MM-DD HH:MM","durationMinutes":<int optional>} — add a Calendar event.
        {"action":"create_note","title":"<title>","body":"<note text>"} — make a Notes note.
        {"action":"web_answer","query":"<search query>"} — QUESTIONS and searches: facts, news, sports scores, weather, prices, people, anything you can't know. Opens a web search. "what's the score of the Lakers game" -> {"action":"web_answer","query":"Lakers game live score"}.
        {"action":"analyze_screen","query":"<the question>"} — the user asks about what is VISIBLE on their screen right now: "what's on my screen", "what am I looking at", "explain this error", "summarize this page", "review this code", "translate what's on screen". zeldaFlow screenshots the screen and a vision AI answers.
        {"action":"agent_task","task":"<the task in the user's words>"} — complex multi-step computer/developer work done by a powerful background agent with terminal access: anything about GitHub repos, PRs, issues, CI ("check my github notifications", "create a repo called X", "review my open PRs"), organizing files ("clean up my downloads folder"), coding chores, multi-step research. Copy the user's request faithfully into "task".
        {"action":"ask_claude","text":"<the prompt>"} — ONLY when the user explicitly names the Claude APP: "open claude and ask it …", "ask claude to write …". Opens the Claude desktop app and types the prompt there.
        {"action":"create_folder","target":"<path>"} — make a folder: "make a folder called invoices in documents" -> {"target":"documents/invoices"}.
        {"action":"create_file","target":"<path>","text":"<optional contents>"} — make a file: "create notes.txt on my desktop" -> {"target":"desktop/notes.txt"}.
        {"action":"delete_file","target":"<path>"} — move a file or folder to the Trash: "delete the screenshot in downloads" -> {"target":"downloads/screenshot.png"}. Recoverable; the user is asked to confirm first.
        {"action":"move_file","target":"<from path>","destination":"<to path or folder>"} — move or rename: "move report.pdf from downloads to documents" -> {"target":"downloads/report.pdf","destination":"documents"}.
        {"action":"list_files","target":"<folder>"} — what's in a folder: "what's in my downloads".
        {"action":"reveal_file","target":"<path>"} — show it in Finder, or open a file in its default app.
        For all of the above, paths are spoken locations under the user's home folder: "downloads", "desktop", "documents", "pictures", "music", "movies", or a path like "documents/work/notes.txt". Never use absolute system paths.
        {"action":"cancel_agent"} — "stop the agent", "cancel that task".
        {"action":"none","reason":"<why>"} — unclear or unsupported.

        Rules:
        - Copy every name the user speaks — apps, songs, artists, playlists, people — EXACTLY as they said it. Never swap in a different, similar, or more common name.
        - Right now it is \(nowString) (today is \(todayString)). Resolve relative dates/times ("tomorrow","next Friday","in an hour","5pm") to absolute "YYYY-MM-DD HH:MM".
        - For emails and messages, WRITE the actual content the user described — never leave body empty.
        - The user's frontmost app is: \(frontApp.isEmpty ? "unknown" : frontApp). If they mean "write this here", use type_text.
        - Multiple requests in one command -> multiple actions in order (e.g. "open Notes and play some jazz").
        - Keep it to the actions the user actually asked for.
        - Questions about "this" / "the screen" / "what I'm looking at" -> analyze_screen. Quick facts you'd Google -> web_answer. Real WORK (github, files, code, multi-step) -> agent_task.
        """
    }

    static func systemPrompt(dictionary: [String]) -> String {
        var p = """
        You are a dictation post-processor. Rewrite the user's raw speech transcript into clean written text.
        Rules:
        - The transcript may be in ANY language, or a mix of languages. Clean it in ITS OWN language and script — NEVER translate, transliterate, or switch scripts.
        - Remove filler words (um, uh, erm, "you know" and "like" when meaningless), false starts, and stutters.
        - Apply self-corrections: "on Tuesday, no wait, Wednesday" becomes "on Wednesday"; "scratch that" discards the preceding clause.
        - Interpret spoken formatting: "new paragraph" becomes a paragraph break, "new line" becomes a line break.
        - Fix punctuation, capitalization, and obvious grammar slips. Keep the speaker's wording and tone. Never summarize, expand, answer questions, or add anything.
        - Output ONLY the cleaned text — no quotes, no commentary.
        """
        if !dictionary.isEmpty {
            p += "\n- Spell these user-dictionary terms exactly: \(dictionary.joined(separator: ", "))."
        }
        return p
    }

    // MARK: - HTTP plumbing (synchronous, called on our queue)

    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let messages: [Message]
        let temperature: Double
        let max_tokens: Int
        let stream: Bool
        // Gemma 4 is a thinking model. Measured on this build: this flag does
        // NOT suppress the chain-of-thought — identical replies with and
        // without it — the reasoning simply lands in `reasoning_content` while
        // `content` gets what's left of the budget. It stays because it's
        // harmless and future builds may honour it, but the real defence is a
        // generous max_tokens and, where correctness matters, response_format.
        let chat_template_kwargs: [String: Bool]
        /// Grammar-constrained decoding. The one reliable way to get this
        /// model to answer in a fixed shape: the tokens simply cannot form
        /// anything else, so parsing can't fail and values can't drift.
        let response_format: ResponseFormat?
        /// Reuse the KV cache across steps of a task. Only pays off when the
        /// system prompt is byte-identical each call — measured 370/375 tokens
        /// cached — so planner prompts must not interpolate anything.
        let cache_prompt: Bool
    }

    struct ResponseFormat: Encodable {
        struct Schema: Encodable {
            let name: String
            let strict: Bool
            let schema: JSONValue
        }
        let type = "json_schema"
        let json_schema: Schema
    }

    /// Just enough JSON to express a response schema literal.
    indirect enum JSONValue: Encodable {
        case string(String), bool(Bool), array([JSONValue]), object([String: JSONValue])

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .bool(let b):   try c.encode(b)
            case .array(let a):  try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finish_reason: String?
        }
        let choices: [Choice]
    }

    private func chatSync(system: String, user: String, maxTokens: Int,
                          session: URLSession,
                          schema: JSONValue? = nil, schemaName: String = "reply",
                          temperature: Double = 0) -> String? {
        var req = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChatRequest(
            messages: [.init(role: "system", content: system),
                       .init(role: "user", content: user)],
            temperature: temperature,
            max_tokens: maxTokens,
            stream: false,
            chat_template_kwargs: ["enable_thinking": false],
            response_format: schema.map {
                ResponseFormat(json_schema: .init(name: schemaName, strict: true, schema: $0))
            },
            cache_prompt: true
        )
        guard let data = try? JSONEncoder().encode(body) else { return nil }
        req.httpBody = data
        let timeout = session === commandSession ? commandTimeout : requestTimeout

        let sem = DispatchSemaphore(value: 0)
        var output: String?
        let task = session.dataTask(with: req) { data, response, _ in
            defer { sem.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data) else { return }
            output = parsed.choices.first?.message.content
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return output
    }

    private func healthCheckSync() -> Bool {
        var req = URLRequest(url: endpoint.appendingPathComponent("health"))
        req.timeoutInterval = 2
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = session.dataTask(with: req) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 3)
        return ok
    }

    /// Set the queue-confined status and mirror it to the UI on main.
    private func setStatus(_ s: Status) {
        if Thread.isMainThread {
            // Only reachable via queue.sync from main (stopSync).
            statusQ = s
            status = s
        } else {
            statusQ = s
            DispatchQueue.main.async { self.status = s }
        }
    }
}

/// Regex-only fallback ("Light" mode): strips obvious fillers without an LLM.
enum LightCleaner {
    private static let fillerPattern = try! NSRegularExpression(
        pattern: "(?i)(?:^|(?<=[\\s,.!?]))(?:um+|uh+|erm+|hmm+)(?:[,.]?\\s+|[,.]?$)",
        options: [])

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var out = fillerPattern.stringByReplacingMatches(in: text, options: [],
                                                         range: range, withTemplate: "")
        out = out.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return text }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}
