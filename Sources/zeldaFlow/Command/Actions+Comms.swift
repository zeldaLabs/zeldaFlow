import Foundation

/// Actions that contact another person on the user's behalf, via the user's
/// own Mail / Messages accounts. These are the same capabilities Siri and the
/// Shortcuts app expose. Two safety properties, enforced by callers and here:
///   1. They only run after the user re-confirms by tapping Fn (see ActionGate
///      / AppState command confirmation), so nothing is sent silently.
///   2. Recipients are resolved against the user's Contacts; an unresolved
///      email recipient degrades to a *visible* draft rather than a blind send.
enum CommsActions {
    /// Resolve a spoken name to an email address via Contacts (pass-through if
    /// it already looks like an address).
    private static func resolveEmail(_ recipient: String) async -> String? {
        if recipient.contains("@") { return recipient }
        let script = """
        tell application "Contacts"
            set ps to (every person whose name contains \(AppleScriptRunner.quote(recipient)))
            if (count of ps) is 0 then return "NOTFOUND"
            set es to emails of item 1 of ps
            if (count of es) is 0 then return "NOTFOUND"
            return value of item 1 of es
        end tell
        """
        let r = await AppleScriptRunner.run(script)
        return (r.ok && r.output != "NOTFOUND" && r.output.contains("@")) ? r.output : nil
    }

    static func email(_ a: ZeldaFlowAction, send: Bool) async -> ActionOutcome {
        guard let to = a.to, !to.isEmpty else {
            return ActionOutcome(ok: false, summary: "[email: no recipient]", pillMessage: "Who is it for?")
        }
        let subject = a.subject ?? ""
        let body = a.body ?? ""
        let resolved = await resolveEmail(to)
        // Never blind-send to an unresolved recipient — open a visible draft.
        let reallySend = send && resolved != nil
        let address = resolved ?? to
        let q = AppleScriptRunner.quote
        let script = """
        tell application "Mail"
            set m to make new outgoing message with properties {subject:\(q(subject)), content:\(q(body)), visible:\(reallySend ? "false" : "true")}
            tell m to make new to recipient with properties {address:\(q(address))}
            \(reallySend ? "send m" : "activate")
        end tell
        """
        let r = await AppleScriptRunner.run(script)
        guard r.ok else {
            return ActionOutcome(ok: false, summary: "[mail error]", pillMessage: "Mail error — see log")
        }
        if reallySend {
            return ActionOutcome(ok: true, summary: "[emailed \(address): \(subject)]",
                                 pillMessage: "✉️ Sent to \(address)")
        }
        let why = send ? "Couldn’t match “\(to)” — review the draft in Mail" : "Draft ready in Mail"
        return ActionOutcome(ok: true, summary: "[draft for \(address): \(subject)]", pillMessage: why)
    }

    private static func resolveHandle(_ recipient: String) async -> String? {
        let stripped = recipient.replacingOccurrences(of: " ", with: "")
        if recipient.contains("@") || stripped.allSatisfy({ "+0123456789-()".contains($0) }) {
            return recipient
        }
        let script = """
        tell application "Contacts"
            set ps to (every person whose name contains \(AppleScriptRunner.quote(recipient)))
            if (count of ps) is 0 then return "NOTFOUND"
            set p to item 1 of ps
            if (count of phones of p) > 0 then return value of item 1 of phones of p
            if (count of emails of p) > 0 then return value of item 1 of emails of p
            return "NOTFOUND"
        end tell
        """
        let r = await AppleScriptRunner.run(script)
        return (r.ok && r.output != "NOTFOUND") ? r.output : nil
    }

    static func sendMessage(_ a: ZeldaFlowAction) async -> ActionOutcome {
        guard let to = a.to, let body = a.body, !to.isEmpty, !body.isEmpty else {
            return ActionOutcome(ok: false, summary: "[message: incomplete]",
                                 pillMessage: "Need a recipient and a message")
        }
        guard let handle = await resolveHandle(to) else {
            return ActionOutcome(ok: false, summary: "[no contact: \(to)]",
                                 pillMessage: "Couldn’t find “\(to)” in Contacts")
        }
        let q = AppleScriptRunner.quote
        let script = """
        tell application "Messages"
            set svc to 1st account whose service type = iMessage
            send \(q(body)) to participant \(q(handle)) of svc
        end tell
        """
        let r = await AppleScriptRunner.run(script)
        return ActionOutcome(ok: r.ok,
                             summary: r.ok ? "[iMessage to \(handle)]" : "[message failed]",
                             pillMessage: r.ok ? "💬 Sent to \(to)" : "Message failed — see log")
    }
}
