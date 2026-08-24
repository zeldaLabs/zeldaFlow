import Foundation

/// Picks the menu command the user meant.
///
/// Deterministic on purpose, and tried before the model — the same principle
/// as CommandFastPath. If someone says "make it bold" and the app has a Bold
/// item, no language model should be involved in that decision: it is slower,
/// and it can hallucinate a command the app doesn't have.
///
/// The model is only consulted when this is genuinely unsure, and even then it
/// chooses from this shortlist rather than inventing a path.
enum UIMatcher {
    /// Words that carry no intent and shouldn't influence scoring.
    private static let filler: Set<String> = [
        "the", "a", "an", "this", "that", "it", "my", "please", "can", "you",
        "to", "for", "me", "make", "set", "turn", "do", "go", "now", "up",
        "and", "of", "in", "on", "with", "let", "s", "i", "want",
    ]

    /// Score a command against the spoken phrase. Higher is better; nil means
    /// no meaningful overlap at all.
    static func score(_ command: MenuCommand, against spoken: String) -> Double? {
        let said = tokens(spoken)
        guard !said.isEmpty else { return nil }
        let leaf = tokens(command.title)
        guard !leaf.isEmpty else { return nil }

        // Exact leaf match is the strongest possible signal: "bold" → "Bold".
        // The disabled penalty still applies: apps commonly publish the same
        // title in two places (Calendar has "New Event" in more than one menu),
        // and a greyed-out copy must never outrank the one that works.
        if leaf == said { return command.enabled ? 100 : 55 }

        let overlap = leaf.intersection(said)
        guard !overlap.isEmpty else { return nil }

        // Reward covering the whole menu title, and covering what was said.
        let leafCoverage = Double(overlap.count) / Double(leaf.count)
        let saidCoverage = Double(overlap.count) / Double(said.count)
        var s = 60 * leafCoverage + 30 * saidCoverage

        // A shorter title matching the same words is the more specific command
        // ("Bold" beats "Bold and Italic Styles").
        s -= Double(leaf.count - overlap.count) * 4

        // Path words can corroborate ("export" under File).
        let pathWords = tokens(command.path.dropLast().joined(separator: " "))
        s += Double(pathWords.intersection(said).count) * 6

        // Never steer the user into something they can't use.
        if !command.enabled { s -= 45 }
        return s
    }

    /// Best command, plus whether it's confident enough to run without asking.
    /// Returns nil when nothing plausibly matches.
    static func best(for spoken: String, in commands: [MenuCommand])
        -> (command: MenuCommand, confident: Bool)? {
        let ranked = ranking(for: spoken, in: commands)

        // Only ever return something the user can actually use. Picking the
        // best *enabled* command rather than giving up when the top match is
        // greyed out is what makes duplicate titles across menus work.
        guard let (top, topScore) = ranked.first(where: { $0.0.enabled }),
              topScore >= 55 else { return nil }

        // Confident when it's a clear win: a strong score, and meaningfully
        // ahead of the next distinct command. A near-tie is exactly when a
        // human would hesitate, so we hand it to the model instead of guessing.
        let runnerUp = ranked.first { $0.0 != top }?.1 ?? 0
        let confident = topScore >= 90 || (topScore - runnerUp) >= 20
        return (top, confident)
    }

    /// The shortlist handed to the model when the match is ambiguous.
    static func shortlist(for spoken: String, in commands: [MenuCommand], limit: Int = 25)
        -> [MenuCommand] {
        ranking(for: spoken, in: commands).prefix(limit).map(\.0)
    }

    /// Scored commands, best first. Equal scores put the usable one first —
    /// Swift's sort isn't stable, so without this tie-break the same phrase can
    /// resolve differently between runs.
    private static func ranking(for spoken: String, in commands: [MenuCommand])
        -> [(MenuCommand, Double)] {
        commands
            .compactMap { c -> (MenuCommand, Double)? in
                score(c, against: spoken).map { (c, $0) }
            }
            .sorted { a, b in
                a.1 != b.1 ? a.1 > b.1 : (a.0.enabled && !b.0.enabled)
            }
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !filler.contains($0) })
    }
}
