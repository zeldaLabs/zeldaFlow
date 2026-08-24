import Foundation

/// Deterministic parser for common single-intent commands, tried before the
/// LLM. Whatever it recognizes is built from the user's exact words, so a
/// small model can never substitute "Google Chrome" for "Safari" or drop an
/// artist name. Returns nil for anything it isn't sure about — the LLM stays
/// the fallback for phrasing this doesn't cover.
enum CommandFastPath {
    static func parse(_ transcript: String) -> [ZeldaFlowAction]? {
        var t = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper emits typographic quotes ("what’s") — normalize so the
        // ASCII phrase lists below actually match.
        t = t.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        while let last = t.last, ".!?,;".contains(last) { t.removeLast() }

        // Wake words and courtesy fluff, possibly stacked ("hey zelda flow
        // can you please open safari"). Whisper renders the spoken name
        // inconsistently — "zelda flow", "zeldaflow", sometimes just
        // "zelda" — so all three are stripped. Longest first: "hey zelda
        // flow" must match before the bare "zelda".
        let prefixes = ["hey zelda flow", "hey zeldaflow", "hey zelda",
                        "zelda flow", "zeldaflow", "zelda",
                        "please", "can you", "could you",
                        "would you", "will you", "just"]
        var stripped = true
        while stripped {
            stripped = false
            t = t.trimmingCharacters(in: .whitespaces)
            for p in prefixes {
                // Accept "hey zeldaFlow open…" and "hey zeldaFlow, open…".
                for sep in [" ", ", ", ","] where t.hasPrefix(p + sep) {
                    t = String(t.dropFirst(p.count + sep.count))
                    stripped = true
                    break
                }
            }
        }
        for suffix in [" please", " for me", " now"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }

        // Agent phrases first: "summarize this page" must beat parseEdit's
        // "summarize this" prefix, and "what's on my screen" must beat the
        // question → Google-search route.
        if let a = parseAgent(t, original: transcript) { return [a] }

        // Edit instructions act on the user's selected text.
        if let a = parseEdit(t) { return [a] }

        // Directions — before questions so "how do I get to X" navigates.
        if let a = parseNavigate(t) { return [a] }

        // Questions go to web answering whole — even ones containing "and"
        // ("score of india and australia") are a single search query.
        if let a = parseQuestion(t) { return [a] }

        // Multi-intent commands ("open notes and play some jazz") → LLM.
        if t.contains(" and ") || t.contains(" then ") { return nil }

        if let a = parseOpen(t) { return [a] }
        if let a = parseClose(t) { return [a] }
        if let a = parseMusicControl(t) { return [a] }
        if let a = parseVolume(t) { return [a] }
        if let a = parsePlay(t) { return [a] }
        return nil
    }

    // MARK: - navigation

    private static func parseNavigate(_ t: String) -> ZeldaFlowAction? {
        let verbs = ["navigate to ", "navigate me to ", "directions to ", "direction to ",
                     "get directions to ", "take me to ", "drive me to ", "drive to ",
                     "walk to ", "walk me to ", "route to ", "get me to ",
                     "how do i get to ", "how do i go to "]
        guard let verb = verbs.first(where: { t.hasPrefix($0) }) else { return nil }
        var dest = String(t.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        var transport = verb.hasPrefix("walk") ? "walk" : "drive"
        for (suffix, mode) in [(" by walk", "walk"), (" by walking", "walk"), (" on foot", "walk"),
                               (" by transit", "transit"), (" by train", "transit"),
                               (" by bus", "transit"), (" by car", "drive"), (" by driving", "drive")]
        where dest.hasSuffix(suffix) {
            dest = String(dest.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            transport = mode
        }
        guard !dest.isEmpty else { return nil }
        return ZeldaFlowAction(action: "navigate", destination: dest.capitalized, transport: transport)
    }

    // MARK: - speak-to-edit (selected text)

    private static func parseEdit(_ t: String) -> ZeldaFlowAction? {
        let starters = ["make this ", "make it ", "make that ", "rewrite this", "rewrite that",
                        "rewrite ", "tighten this", "tighten ", "shorten this", "shorten ",
                        "expand this", "expand on this", "summarize this", "summarise this",
                        "fix the grammar", "fix grammar", "fix this", "proofread this",
                        "translate this ", "translate that ", "turn this into ",
                        "convert this to ", "bulletize this", "simplify this", "formalize this"]
        guard starters.contains(where: { t.hasPrefix($0) }) else { return nil }
        return ZeldaFlowAction(action: "edit_text", text: t)
    }

    // MARK: - agent (screen analysis, ask claude, cancel)

    private static func parseAgent(_ t: String, original: String) -> ZeldaFlowAction? {
        switch t {
        case "stop the agent", "cancel the agent", "stop agent", "cancel agent",
             "stop the agent task", "cancel the agent task", "cancel that task":
            return ZeldaFlowAction(action: "cancel_agent")
        default:
            break
        }

        // "ask claude …" — recover the user's casing for the typed prompt.
        for verb in ["open claude and ask it to ", "open claude and ask it ",
                     "open claude and ask ", "open claude and tell it to ",
                     "ask claude to ", "ask claude ", "tell claude to "]
        where t.hasPrefix(verb) {
            let rest = String(t.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            return ZeldaFlowAction(action: "ask_claude", text: originalCasing(of: rest, in: original))
        }

        // Screen-analysis phrases are only ours when the agent can actually
        // run — otherwise "what is this" should keep falling through to a web
        // search like it always did.
        guard AppSettings.shared.agentEnabled, AgentService.isAvailable else { return nil }

        // Any question or inspect request that references the screen is a
        // screen question — people phrase these a hundred ways ("what's
        // THERE on my screen", "what's THAT on my screen"), so match the
        // pattern, not exact strings.
        let screenRefs = ["my screen", "the screen", "this screen", "that screen",
                          "on screen", "onscreen", "my display", "my monitor",
                          "i'm looking at", "im looking at"]
        let inspectHints = ["what", "who", "why", "how", "which", "where", "when",
                            "tell", "see", "look", "read", "describe", "explain",
                            "analyze", "analyse", "summarize", "summarise",
                            "review", "check", "translate", "can you", "anything"]
        if screenRefs.contains(where: t.contains),
           inspectHints.contains(where: { t.hasPrefix($0) || t.contains(" " + $0) }) {
            // "look at my screen and tell me X" → the question is the tail;
            // otherwise the whole utterance IS the question.
            for verb in ["look at my screen and ", "look at the screen and ",
                         "see my screen and ", "check my screen and "]
            where t.hasPrefix(verb) {
                let rest = String(t.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
                guard !rest.isEmpty else { break }
                return ZeldaFlowAction(action: "analyze_screen",
                                    query: originalCasing(of: rest, in: original))
            }
            return ZeldaFlowAction(action: "analyze_screen",
                                query: originalCasing(of: t, in: original))
        }

        // Screen-implied phrases that don't say "screen".
        let screenImplied: Set<String> = [
            "what am i looking at", "what am i looking at right now",
            "what's this", "what is this", "whats this",
            "explain this error", "what does this error mean",
            "what's this error", "what is this error",
            "summarize this page", "summarise this page",
        ]
        if screenImplied.contains(t) {
            return ZeldaFlowAction(action: "analyze_screen",
                                query: originalCasing(of: t, in: original))
        }
        return nil
    }

    /// The transcript was lowercased for matching; pull the same span out of
    /// the original so typed prompts keep the user's casing. The original may
    /// still carry typographic quotes the matcher normalized away — search a
    /// same-length normalized copy and map the range back by offsets.
    private static func originalCasing(of needle: String, in original: String) -> String {
        let normalized = original
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        if let r = normalized.range(of: needle, options: [.caseInsensitive]) {
            let start = normalized.distance(from: normalized.startIndex, to: r.lowerBound)
            let length = normalized.distance(from: r.lowerBound, to: r.upperBound)
            if let s = original.index(original.startIndex, offsetBy: start,
                                      limitedBy: original.endIndex),
               let e = original.index(s, offsetBy: length, limitedBy: original.endIndex) {
                return String(original[s..<e])
            }
        }
        return needle
    }

    // MARK: - questions → web answer

    private static func parseQuestion(_ t: String) -> ZeldaFlowAction? {
        // Explicit search verbs: the rest of the utterance is the query.
        for verb in ["search for ", "search ", "look up ", "google ",
                     "find out about ", "find out "] where t.hasPrefix(verb) {
            let q = String(t.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return nil }
            return ZeldaFlowAction(action: "web_answer", query: q)
        }
        // Question-word openers claim the whole utterance as a search query.
        let openers = ["what", "who", "when", "where", "why", "how", "which",
                       "is ", "are ", "was ", "were ", "did ", "does ", "do ",
                       "has ", "have ", "score of", "weather in", "weather at",
                       "price of", "temperature in"]
        guard openers.contains(where: { t.hasPrefix($0) }) else { return nil }
        return ZeldaFlowAction(action: "web_answer", query: t)
    }

    // MARK: - open <app or url>

    private static func parseOpen(_ t: String) -> ZeldaFlowAction? {
        let verbs = ["open up", "open", "launch", "start", "switch to", "go to"]
        guard let verb = verbs.first(where: { t.hasPrefix($0 + " ") }) else { return nil }
        var target = String(t.dropFirst(verb.count + 1)).trimmingCharacters(in: .whitespaces)
        for article in ["the ", "my "] where target.hasPrefix(article) {
            target = String(target.dropFirst(article.count))
        }
        for suffix in [" app", " application"] where target.hasSuffix(suffix) {
            target = String(target.dropLast(suffix.count))
        }
        guard !target.isEmpty else { return nil }

        if target.contains("."), !target.contains(" ") {
            return ZeldaFlowAction(action: "open_url", url: target)
        }
        if let resolved = AppResolver.resolve(target) {
            return ZeldaFlowAction(action: "open_app", app: resolved)
        }
        // Not installed on this Mac, but a service we know the web app for
        // ("open spotify" without Spotify, "open youtube") — go straight there.
        if let web = AppResolver.webFallback(for: target) {
            return ZeldaFlowAction(action: "open_url", url: web.absoluteString)
        }
        // Unknown name — may still be a website; let the LLM decide.
        return nil
    }

    // MARK: - close/quit <app>

    private static func parseClose(_ t: String) -> ZeldaFlowAction? {
        let verbs = ["close", "quit", "exit", "kill"]
        guard let verb = verbs.first(where: { t.hasPrefix($0 + " ") }) else { return nil }
        var target = String(t.dropFirst(verb.count + 1)).trimmingCharacters(in: .whitespaces)
        for article in ["the ", "my "] where target.hasPrefix(article) {
            target = String(target.dropFirst(article.count))
        }
        for suffix in [" app", " application"] where target.hasSuffix(suffix) {
            target = String(target.dropLast(suffix.count))
        }
        guard !target.isEmpty else { return nil }
        // "close the tab/window/this" is about UI, not an app.
        if ["tab", "tabs", "window", "windows", "this", "that", "it", "everything"].contains(target) {
            return nil
        }
        // Claim only when it maps to a real app.
        guard let resolved = AppResolver.resolveRunning(target) ?? AppResolver.resolve(target) else {
            return nil
        }
        return ZeldaFlowAction(action: "close_app", app: resolved)
    }

    // MARK: - playback control

    private static func parseMusicControl(_ t: String) -> ZeldaFlowAction? {
        switch t {
        case "pause", "pause music", "pause the music", "pause song", "pause the song",
             "stop", "stop music", "stop the music", "stop playing", "stop the song":
            return ZeldaFlowAction(action: "music_control", command: "pause")
        case "play", "resume", "resume music", "resume the music", "resume playing",
             "keep playing", "unpause", "continue playing":
            return ZeldaFlowAction(action: "music_control", command: "play")
        case "next", "next song", "next track", "skip", "skip song", "skip track",
             "skip this song", "skip this track", "play the next song", "play next song":
            return ZeldaFlowAction(action: "music_control", command: "next")
        case "previous", "previous song", "previous track", "go back", "last song",
             "play the previous song", "play the last song":
            return ZeldaFlowAction(action: "music_control", command: "previous")
        default:
            return nil
        }
    }

    // MARK: - volume

    private static let volumeWords: Set<String> =
        ["set", "turn", "put", "the", "volume", "to", "at", "percent", "sound", "up", "down"]

    private static func parseVolume(_ t: String) -> ZeldaFlowAction? {
        switch t {
        case "mute", "mute volume", "mute the volume", "mute sound", "mute the sound":
            return ZeldaFlowAction(action: "set_volume", mute: true)
        case "unmute", "unmute volume", "unmute the volume", "unmute sound", "unmute the sound":
            return ZeldaFlowAction(action: "set_volume", mute: false)
        default:
            break
        }
        guard t.contains("volume") else { return nil }
        let words = t.split(separator: " ").map { $0.replacingOccurrences(of: "%", with: "") }
        let numbers = words.compactMap { Int($0) }
        // Claim only clean "set the volume to 40" shapes — one number, no
        // unrecognized words that could change the meaning.
        guard numbers.count == 1, let level = numbers.first, (0...100).contains(level),
              words.allSatisfy({ volumeWords.contains($0) || Int($0) != nil }) else { return nil }
        return ZeldaFlowAction(action: "set_volume", level: level)
    }

    // MARK: - play music

    private static func parsePlay(_ t: String) -> ZeldaFlowAction? {
        guard t.hasPrefix("play ") else { return nil }
        var rest = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        // Video, not music — not ours to guess.
        if rest.contains("youtube") { return nil }
        // A named player wins; otherwise MusicPlayer.resolve picks the right
        // app for this machine.
        var service: String?
        for (suffix, svc) in [(" on spotify", "spotify"), (" in spotify", "spotify"),
                              (" with spotify", "spotify"), (" using spotify", "spotify"),
                              (" on apple music", "apple music"), (" in apple music", "apple music"),
                              (" with apple music", "apple music"), (" using apple music", "apple music"),
                              (" in the library", "apple music"), (" in my library", "apple music"),
                              (" in library", "apple music"), (" from my library", "apple music"),
                              (" from the library", "apple music"), (" from library", "apple music")]
        where rest.hasSuffix(suffix) {
            rest = String(rest.dropLast(suffix.count))
            service = svc
            break
        }
        for article in ["some ", "my "] where rest.hasPrefix(article) {
            rest = String(rest.dropFirst(article.count))
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else {
            return service.map { _ in ZeldaFlowAction(action: "play_music", service: service) }
        }

        switch rest {
        case "music", "songs", "a song", "something", "anything":
            return ZeldaFlowAction(action: "play_music", service: service)
        case "spotify":
            return ZeldaFlowAction(action: "play_music", service: "spotify")
        case "apple music":
            return ZeldaFlowAction(action: "play_music", service: "apple music")
        default:
            break
        }
        // A service named mid-utterance ("play spotify hits from the 90s")
        // is phrasing this parser doesn't own — never bake the service name
        // into the song query; the LLM sorts it out.
        if rest.contains("spotify") || rest.contains("apple music") { return nil }
        if rest.hasPrefix("playlist ") {
            return ZeldaFlowAction(action: "play_music",
                                playlist: titleCased(String(rest.dropFirst(9))), service: service)
        }
        if rest.hasSuffix(" playlist") {
            return ZeldaFlowAction(action: "play_music",
                                playlist: titleCased(String(rest.dropLast(9))), service: service)
        }
        // "play <song> by <artist>" / "play songs by <artist>"
        if let range = rest.range(of: " by ") {
            let left = String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let artist = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !artist.isEmpty else { return nil }
            if ["songs", "song", "music", "tracks", "something", "anything"].contains(left) || left.isEmpty {
                return ZeldaFlowAction(action: "play_music", artist: titleCased(artist), service: service)
            }
            return ZeldaFlowAction(action: "play_music", song: titleCased(left),
                                artist: titleCased(artist), service: service)
        }
        // "play <artist> songs" — the reported failure case.
        for suffix in [" songs", " song", " music", " tracks"] where rest.hasSuffix(suffix) {
            let artist = String(rest.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            guard !artist.isEmpty else { return nil }
            return ZeldaFlowAction(action: "play_music", artist: titleCased(artist), service: service)
        }
        // Bare "play X": X may be a song or an artist — playMusic tries both.
        return ZeldaFlowAction(action: "play_music", song: titleCased(rest), service: service)
    }

    /// The transcript arrives lowercased; Music search is contains-based and
    /// case-insensitive, but title case reads better in the pill and history.
    private static func titleCased(_ s: String) -> String {
        s.capitalized
    }
}
