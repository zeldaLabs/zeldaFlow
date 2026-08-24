import Foundation

/// One interpreted voice-command action from the local LLM. A flexible bag of
/// optional parameters; `action` selects which ones apply. The LLM only fills
/// these fields — it never produces executable code.
struct ZeldaFlowAction: Decodable {
    let action: String
    // open_app / open_url / type_text / none
    let app: String?
    let url: String?
    let text: String?
    let reason: String?
    // play_music / music_control / set_volume
    let song: String?
    let artist: String?
    let playlist: String?
    let service: String?   // music app the user named ("spotify"), if any
    let command: String?
    let level: Int?
    let mute: Bool?
    // send_email / draft_email / send_message
    let to: String?
    let subject: String?
    let body: String?
    // add_reminder / create_note / create_event
    let title: String?
    let date: String?
    let durationMinutes: Int?
    // web_answer / analyze_screen
    let query: String?
    // navigate
    let destination: String?
    let transport: String?
    // agent_task
    let task: String?
    // ui_click / ui_type — the control being acted on, by its on-screen label
    let target: String?
    // press_key — a named navigation key ("return", "tab", "escape")
    let key: String?

    /// For actions built in code (the deterministic fast path) rather than
    /// decoded from the LLM.
    init(action: String, app: String? = nil, url: String? = nil, text: String? = nil,
         reason: String? = nil, song: String? = nil, artist: String? = nil,
         playlist: String? = nil, service: String? = nil, command: String? = nil,
         level: Int? = nil, mute: Bool? = nil, to: String? = nil, subject: String? = nil,
         body: String? = nil, title: String? = nil, date: String? = nil,
         durationMinutes: Int? = nil, query: String? = nil,
         destination: String? = nil, transport: String? = nil,
         task: String? = nil, target: String? = nil, key: String? = nil) {
        self.action = action
        self.app = app
        self.url = url
        self.text = text
        self.reason = reason
        self.song = song
        self.artist = artist
        self.playlist = playlist
        self.service = service
        self.command = command
        self.level = level
        self.mute = mute
        self.to = to
        self.subject = subject
        self.body = body
        self.title = title
        self.date = date
        self.durationMinutes = durationMinutes
        self.query = query
        self.destination = destination
        self.transport = transport
        self.task = task
        self.target = target
        self.key = key
    }
}

/// Result of executing one action.
struct ActionOutcome {
    let ok: Bool
    let summary: String        // for history
    let pillMessage: String?   // shown in the pill; nil = plain ✓ checkmark
    /// Full text worth keeping (an analysis answer, an agent report) —
    /// becomes "Paste Last Transcript" so long results aren't lost to the pill.
    let payload: String?

    init(ok: Bool, summary: String, pillMessage: String?, payload: String? = nil) {
        self.ok = ok
        self.summary = summary
        self.pillMessage = pillMessage
        self.payload = payload
    }
}

struct CommandContext {
    let expectedFrontmost: String?
}

/// Actions that change something in the outside world (send a message to
/// someone) get a spoken-confirmation gate before they run.
enum ActionGate {
    /// A one-line confirmation string, or nil if the action can run immediately.
    static func confirmationLabel(for a: ZeldaFlowAction, confirmBeforeSending: Bool) -> String? {
        guard confirmBeforeSending else { return nil }
        switch a.action {
        case "send_email":
            return "Send email to \(a.to ?? "?")? Tap Fn to confirm, Esc to cancel"
        case "send_message":
            // Show enough of the body to catch a mis-transcribed tail —
            // same budget the agent gate uses.
            let preview = (a.body ?? "").prefix(160)
            return "Message \(a.to ?? "?"): “\(preview)”? Tap Fn to send, Esc to cancel"
        default:
            return nil
        }
    }

    /// A background agent gets terminal access — that always needs an explicit
    /// Fn-tap, regardless of the "confirm before sending" toggle. The label
    /// must show the exact task the executor will run (same field fallback),
    /// and enough of it to catch a mis-transcribed destructive tail.
    static func alwaysConfirmLabel(for a: ZeldaFlowAction) -> String? {
        // A menu command that destroys something is gated with no opt-out.
        // "Delete" misheard is not an undo away, and unlike sending a message
        // there is often nothing left to inspect afterwards.
        if a.action == "ui_command", a.reason == "destructive" {
            let what = (a.text ?? "?").replacingOccurrences(of: " ▸ ", with: " → ")
            return "Run “\(what)”? Tap Fn to confirm, Esc to cancel"
        }
        // Show the resolved path, not the spoken words. "delete the report in
        // downloads" reads fine even when it resolved to the wrong file; the
        // path is the only place that mistake is visible before it happens.
        if a.action == "delete_file" {
            let spoken = a.target ?? a.text ?? "?"
            let shown = FileActions.resolve(spoken).map { FileActions.pretty($0) } ?? spoken
            return "Move \(shown) to Trash? Tap Fn to confirm, Esc to cancel"
        }
        // Clicking a button that spends money or destroys something is the one
        // case where a misheard word costs more than a redo — "Get" and "Buy"
        // in the App Store complete a purchase with no further prompt.
        if a.action == "ui_click" {
            let label = a.text ?? a.target ?? ""
            if a.reason == "destructive" || UIActions.isGuarded(label: label) {
                return "Click “\(label)”? Tap Fn to confirm, Esc to cancel"
            }
        }
        guard a.action == "agent_task" else { return nil }
        let preview = (a.task ?? a.text ?? "?").prefix(160)
        return "Run agent: “\(preview)”? Tap Fn to start, Esc to cancel"
    }

    static func isConsequential(_ a: ZeldaFlowAction) -> Bool {
        a.action == "send_email" || a.action == "send_message" || a.action == "agent_task"
            || a.action == "delete_file"
            || (a.action == "ui_command" && a.reason == "destructive")
            || (a.action == "ui_click" && alwaysConfirmLabel(for: a) != nil)
    }
}
