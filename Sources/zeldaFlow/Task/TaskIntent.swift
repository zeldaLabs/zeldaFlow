import Foundation

/// Decides whether a sentence is a *task* (several steps) or a *command* (one).
///
/// Deterministic and deliberately reluctant. Entering the loop when the user
/// only wanted one thing done is the worse error: instead of opening the App
/// Store and stopping, it opens the App Store and then starts clicking around.
/// So this only fires when the sentence clearly asks for something beyond the
/// single action the interpreter produced.
enum TaskIntent {
    /// Verbs that imply "and then do something once you're there".
    private static let taskVerbs = [
        "download", "install", "search", "find", "look up", "look for",
        "get me", "buy", "check", "sign in", "log in", "update",
    ]

    /// Words that make a sentence one instruction no matter how it's phrased.
    private static let oneShot = [
        "just open", "only open", "switch to", "quit", "close",
    ]

    static func looksLikeTask(_ transcript: String, firstAction: ZeldaFlowAction) -> Bool {
        let t = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if oneShot.contains(where: { t.contains($0) }) { return false }

        // Only these lead somewhere. A send_email or a play_music is complete
        // on its own, and looping on it would be inventing work.
        guard ["open_app", "ui_click", "ui_type", "ui_command"]
            .contains(firstAction.action) else { return false }

        // A task verb is the clearest signal there's a second step.
        guard taskVerbs.contains(where: { t.contains($0) }) else { return false }

        // "open the app store" has a verb only by accident of the app's name;
        // there has to be something left once the app name is removed.
        var remainder = t
        if let app = firstAction.app?.lowercased() {
            remainder = remainder.replacingOccurrences(of: app, with: " ")
        }
        if let named = TaskCandidates.namedApp(in: t)?.lowercased() {
            remainder = remainder.replacingOccurrences(of: named, with: " ")
        }
        let words = remainder
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !filler.contains($0) }
        return words.count >= 2
    }

    private static let filler: Set<String> = [
        "the", "and", "for", "from", "please", "can", "you", "app", "application",
        "open", "into", "with", "that", "this", "some", "get",
    ]
}
