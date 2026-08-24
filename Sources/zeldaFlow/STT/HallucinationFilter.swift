import Foundation

/// Whisper was trained on YouTube captions, so on silence or background music
/// it emits caption furniture: "Thanks for watching", subtitle credits,
/// "[Music]" tags, song/artist credit lines. The VAD pre-filter kills most of
/// it on the final pass; this scrubber catches what leaks through — and does
/// the heavy lifting for the live preview, which runs on partial audio and
/// hallucinates far more.
///
/// Two strictness levels, because the failure costs differ completely:
/// the preview is display-only (a false drop costs nothing), while the final
/// transcript is the user's words (a false drop is silent data loss).
enum HallucinationFilter {

    /// Whole-utterance junk: preview-only — a user can genuinely dictate
    /// "thank you", so the final pass never touches these.
    /// Matched against the full text, lowercased, punctuation stripped.
    private static let previewJunk: Set<String> = [
        "thank you", "thanks", "thank you for watching", "thanks for watching",
        "thank you so much for watching", "thanks for watching guys",
        "please subscribe", "like and subscribe", "subscribe to my channel",
        "see you in the next video", "see you next time", "see you soon",
        "bye", "bye bye", "goodbye", "the end", "you", "so", "oh", "okay", "hmm",
    ]

    /// Caption credits that could *conceivably* be dictated ("this book was
    /// translated by…") — dropped from the preview only.
    private static let previewJunkSubstrings: [String] = [
        "subtitles by", "subtitle by", "captions by", "captioned by",
        "translated by", "transcribed by", "copyright ©", "all rights reserved",
        "www.youtube", "youtube.com/watch",
    ]

    /// Strings that never occur in real dictation in any plausible context —
    /// the only sentence-level drops the FINAL transcript gets.
    private static let impossibleSubstrings: [String] = [
        "amara.org", "mbc 뉴스", "ご視聴ありがとう", "チャンネル登録", "字幕視聴ありがとう",
    ]

    /// Music-notation tokens whisper emits when it hears music, not speech.
    private static let musicTokenPattern = try! NSRegularExpression(
        pattern: "[♪♫🎵🎶]+|\\[\\s*(?:music|applause|laughter|silence|noise)\\s*\\]|\\(\\s*(?:music|applause|laughter|silence|upbeat music|soft music)\\s*\\)",
        options: [.caseInsensitive])

    /// Sentence-ish chunks including their trailing delimiter, so filtered
    /// text reassembles byte-identical — no punctuation rewriting.
    ///
    /// A terminator only ends a sentence when whitespace or end-of-string
    /// follows. Without that guard the period inside "amara.org" split the
    /// token, so the marker never matched any single sentence and the caption
    /// boilerplate survived — that impossibleSubstrings entry was dead code.
    /// (Found by the Windows port's test suite, 2026-07-29.)
    private static let sentencePattern = try! NSRegularExpression(
        pattern: "(?:[^.!?\\n]|[.!?](?![\\s]|$))*(?:[.!?\\n]+|$)", options: [])

    /// Greedy decoding at temperature 0 with no fallback re-decode (see
    /// WhisperEngine) can drop into a repetition loop: one segment emitted
    /// over and over until the audio runs out. Runs longer than this collapse
    /// to their first `maxSentenceRun` copies, so emphatic "No. No. No."
    /// survives while a 150-copy loop does not.
    ///
    /// Safe on the final transcript in a way sentence drops are not: nothing
    /// unique is lost, only duplicates of text that stays.
    private static let maxSentenceRun = 3

    /// Decode loops also repeat WITHIN a sentence: "ZeldaWoo, ZeldaWoo, …"
    /// ×35 has no terminator, so to collapseRepeats it is ONE sentence and
    /// survives whole (observed in a meeting transcript, 2026-08-08). Cap
    /// consecutive identical words the same way sentences are capped — the
    /// same safety argument holds: only duplicates of text that stays are
    /// dropped. Each word travels with its trailing separator, so whatever
    /// stays reassembles byte-identical.
    private static let wordPattern = try! NSRegularExpression(pattern: "\\S+\\s*", options: [])

    private static func collapseWordRuns(_ text: String) -> String {
        var out = ""
        var lastNorm: String?
        var run = 0
        let range = NSRange(text.startIndex..., in: text)
        wordPattern.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m, let r = Range(m.range, in: text) else { return }
            let piece = String(text[r])
            let norm = normalize(piece)
            // Bare punctuation/space pieces pass through without breaking a run.
            guard !norm.isEmpty else { out += piece; return }
            run = (norm == lastNorm) ? run + 1 : 1
            lastNorm = norm
            if run <= maxSentenceRun { out += piece }
        }
        return out
    }

    private static func collapseRepeats(_ text: String) -> String {
        var out = ""
        var lastNorm: String?
        var run = 0
        let range = NSRange(text.startIndex..., in: text)
        sentencePattern.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m, let r = Range(m.range, in: text) else { return }
            let sentence = String(text[r])
            let norm = normalize(sentence)
            // Blank chunks (bare newlines) pass through without breaking a run.
            guard !norm.isEmpty else { out += sentence; return }
            run = (norm == lastNorm) ? run + 1 : 1
            lastNorm = norm
            if run <= maxSentenceRun { out += sentence }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live-preview scrub: aggressive. Empty result means "show nothing"
    /// (the pill then keeps the previous words on screen).
    static func scrubPreview(_ text: String, prompt: String? = nil) -> String {
        var cleaned = dropSentences(
            containing: impossibleSubstrings + previewJunkSubstrings,
            in: stripMusicTokens(collapseWordRuns(text)))
        cleaned = dropPromptEcho(from: collapseRepeats(cleaned), prompt: prompt)
        if previewJunk.contains(normalize(cleaned)) { return "" }
        return cleaned
    }

    /// On silence the decoder sometimes emits its own initial prompt as
    /// output — the pill would read "Glossary: …" mid-pause. Preview-only:
    /// drop any sentence that is a verbatim fragment of the active prompt,
    /// plus anything that leads with "Glossary" (a partial echo of the
    /// dictionary list never survives verbatim matching).
    private static func dropPromptEcho(from text: String, prompt: String?) -> String {
        let promptNorm = prompt.map(normalize) ?? ""
        var out = ""
        let range = NSRange(text.startIndex..., in: text)
        sentencePattern.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m, let r = Range(m.range, in: text) else { return }
            let sentence = String(text[r])
            let norm = normalize(sentence)
            let isEcho = norm.hasPrefix("glossary")
                || (norm.count >= 8 && !promptNorm.isEmpty && promptNorm.contains(norm))
            if !isEcho { out += sentence }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The scaffolding words zeldaFlow itself injects into the initial prompt.
    /// They only ever appear in a transcript because we put them there.
    private static let promptScaffolds = ["glossary", "on screen terms"]

    /// Final-transcript echo test — deliberately far stricter than the
    /// preview's. Under heavy background speech the decoder can fall back to
    /// reciting its own prompt, which would paste the user's private
    /// dictionary (and their name) into their document. But a false drop
    /// here is silent data loss, so a sentence must be *unmistakably* ours:
    ///   1. a long verbatim run of the prompt (≥25 normalized chars), or
    ///   2. a sentence leading with our injected scaffolding whose body
    ///      either repeats two or more words from that same prompt, or is
    ///      made of *nothing but* words from it.
    /// Someone genuinely dictating "Glossary: API, SDK, REST" keeps every
    /// word, because none of it came from us.
    ///
    /// The second half of rule 2 exists because "two or more" had a hole at
    /// one: background noise decoded as "Glossary, Manushresth." — our
    /// scaffold plus a single glossary term — and in command mode that ran a
    /// web search for the user's own name (2026-08-04). A sentence that opens
    /// with a word only we put in play and continues with nothing but words
    /// only we supplied is ours, however short it is.
    /// Echoed glossary terms come back misspelled or truncated — the decoder
    /// looped "zeldaFlow" out as "ZeldaWoo" and as bare "Zelda" (both
    /// 2026-08-08) — so exact membership misses them. A word counts as
    /// prompt-supplied when it matches exactly, or shares a 5-character
    /// prefix with a prompt word long enough (≥6) for that prefix to be
    /// distinctive.
    private static func isPromptWord(_ w: String, in promptWords: Set<String>) -> Bool {
        if promptWords.contains(w) { return true }
        guard w.count >= 5 else { return false }
        return promptWords.contains { $0.count >= 6 && w.prefix(5) == $0.prefix(5) }
    }

    private static func words(of text: String) -> [String] {
        text.split(separator: " ").map(String.init).filter { $0.count >= 4 }
    }

    private static func isFinalPromptEcho(_ norm: String, promptNorm: String) -> Bool {
        guard !promptNorm.isEmpty, norm.count >= 8 else { return false }
        if norm.count >= 25, promptNorm.contains(norm) { return true }
        let promptWords = Set(words(of: promptNorm))
        if let scaffold = promptScaffolds.first(where: { norm.hasPrefix($0) }),
           promptNorm.contains(scaffold) {
            // A sentence that is *nothing but* our scaffold word has no body
            // to match on, so rule 2 could never fire — which is how a bare
            // "Glossary." reached a user's document (2026-08-02). We are the
            // only reason that word is in play; alone, it is never dictation.
            if norm == scaffold { return true }
            let bodyWords = Set(words(of: String(norm.dropFirst(scaffold.count))))
            if bodyWords.intersection(promptWords).count >= 2 { return true }
            if !bodyWords.isEmpty,
               bodyWords.allSatisfy({ isPromptWord($0, in: promptWords) }) { return true }
        }
        // Scaffold-less recitation: "Manushresth, zeldaFlow, Manushresth."
        // (2026-08-08). Every meaningful word ours AND one of them repeated
        // — the loop signature; nobody dictates the same glossary term twice
        // in one breath. A single mention of a glossary word ("zeldaFlow.")
        // stays: no repeat, could be real speech.
        let sentenceWords = words(of: norm)
        if sentenceWords.count >= 2, Set(sentenceWords).count < sentenceWords.count,
           sentenceWords.allSatisfy({ isPromptWord($0, in: promptWords) }) { return true }
        return false
    }

    /// Final-transcript scrub: conservative. Removes only text that is never
    /// legitimate dictation; real words always survive. Pass the prompt that
    /// produced the transcript so self-recitation can be recognized.
    static func scrubFinal(_ text: String, prompt: String? = nil) -> String {
        let cleaned = collapseRepeats(
            dropSentences(containing: impossibleSubstrings,
                          in: stripMusicTokens(collapseWordRuns(text))))
        let promptNorm = prompt.map(normalize) ?? ""
        guard !promptNorm.isEmpty else { return emptyIfNoWords(cleaned) }
        var out = ""
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        sentencePattern.enumerateMatches(in: cleaned, range: range) { m, _, _ in
            guard let m, let r = Range(m.range, in: cleaned) else { return }
            let sentence = String(cleaned[r])
            if !isFinalPromptEcho(normalize(sentence), promptNorm: promptNorm) { out += sentence }
        }
        return emptyIfNoWords(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Meeting system-channel scrub: the "Them" side is other people's audio —
    /// hold music, meeting-end jingles, notification dings — where caption
    /// furniture is near-certain hallucination, and unlike dictation the user
    /// cannot have "genuinely said" it into this channel. So the final rules
    /// apply PLUS the preview junk sets: a 5 s system chunk decoding to
    /// exactly "Thanks for watching." is dropped, not preserved.
    static func scrubMeetingSystem(_ text: String, prompt: String? = nil) -> String {
        var cleaned = collapseRepeats(dropSentences(
            containing: impossibleSubstrings + previewJunkSubstrings,
            in: stripMusicTokens(collapseWordRuns(text))))
        if previewJunk.contains(normalize(cleaned)) { return "" }
        let promptNorm = prompt.map(normalize) ?? ""
        guard !promptNorm.isEmpty else { return emptyIfNoWords(cleaned) }
        var out = ""
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        sentencePattern.enumerateMatches(in: cleaned, range: range) { m, _, _ in
            guard let m, let r = Range(m.range, in: cleaned) else { return }
            let sentence = String(cleaned[r])
            if !isFinalPromptEcho(normalize(sentence), promptNorm: promptNorm) { out += sentence }
        }
        return emptyIfNoWords(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Output that normalizes to nothing — a bare ".", "…", stray commas —
    /// is decoder noise on silence, never speech (observed as "Them: ."
    /// transcript lines, 2026-08-08). Callers drop the empty segment.
    private static func emptyIfNoWords(_ text: String) -> String {
        normalize(text).isEmpty ? "" : text
    }

    private static func stripMusicTokens(_ text: String) -> String {
        musicTokenPattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dropSentences(containing junk: [String], in text: String) -> String {
        let lower = text.lowercased()
        guard junk.contains(where: { lower.contains($0) }) else { return text }
        var out = ""
        let range = NSRange(text.startIndex..., in: text)
        sentencePattern.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m, let r = Range(m.range, in: text) else { return }
            let sentence = String(text[r])
            let l = sentence.lowercased()
            if !junk.contains(where: { l.contains($0) }) { out += sentence }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// Gate for the live preview: skip the decode only when the tail is
    /// essentially digital silence. Deliberately ultra-conservative — quiet
    /// speakers and low-gain mics must always pass; the in-decoder Silero VAD
    /// is what actually separates speech from noise.
    static func hasSpeechEnergy(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var sum: Float = 0
        var activeWindows = 0
        let window = 1600  // 100 ms at 16 kHz
        var i = 0
        while i < samples.count {
            let end = min(i + window, samples.count)
            var wsum: Float = 0
            for j in i..<end { wsum += samples[j] * samples[j] }
            let rms = (wsum / Float(end - i)).squareRoot()
            if rms > 0.004 { activeWindows += 1 }
            sum += wsum
            i = end
        }
        let overallRMS = (sum / Float(samples.count)).squareRoot()
        return overallRMS > 0.001 && activeWindows >= 1
    }
}
