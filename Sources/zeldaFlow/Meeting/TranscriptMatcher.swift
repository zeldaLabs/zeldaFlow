import Foundation

/// Text-overlap dedup between the two meeting channels. When the far side's
/// voice leaks through the user's speakers into the mic, Whisper transcribes
/// the same words twice — once as a system segment, once as a mic segment —
/// and the mic copy must be dropped or retracted. Waveform correlation alone
/// can't decide (the leaked copy is a different recording), so OpenWhispr
/// compares the *text*: exact port of src/helpers/transcriptText.js, with the
/// window/merge constants from ipcHandlers.js:5006-5007. Pure functions, no
/// state — the whole file is pinnable by unit tests.
enum TranscriptMatcher {

    // MARK: - Ported constants

    /// A mic echo and its system original land within one transcription cycle
    /// of each other (5 s local chunks + up to ~1 s of decode), so candidates
    /// further than 6 s away are never the same utterance.
    /// ported: ipcHandlers.js:5006 (DUPLICATE_TRANSCRIPT_WINDOW_MS = 6000).
    static let duplicateWindowSeconds: TimeInterval = 6.0
    /// One spoken sentence can straddle up to three 5 s system chunks; longer
    /// concatenations only dilute the token-coverage ratios.
    /// ported: ipcHandlers.js:5007 (DUPLICATE_TRANSCRIPT_MERGE_LIMIT = 3).
    static let duplicateMergeLimit = 3

    /// Strict matcher thresholds. 0.6 coverage tolerates Whisper mishearing
    /// ~2 words in 5 across the two decodes of the same audio; below 3 tokens
    /// the ratios are meaningless ("yeah okay" matches everything).
    /// ported: transcriptText.js:1-3 (TOKEN_COVERAGE_THRESHOLD,
    /// TOKEN_SEQUENCE_THRESHOLD, MIN_TOKENS_FOR_OVERLAP).
    private static let tokenCoverageThreshold = 0.6
    private static let tokenSequenceThreshold = 0.6
    private static let minTokensForOverlap = 3

    /// Loose matcher thresholds: with stopwords gone the surviving tokens are
    /// nearly all content words, so a lower ratio (0.55) over a higher floor
    /// (4 meaningful tokens) still means the same utterance.
    /// ported: transcriptText.js:4-6 (MEANINGFUL_TOKEN_COVERAGE_THRESHOLD,
    /// MEANINGFUL_TOKEN_SEQUENCE_THRESHOLD, MIN_MEANINGFUL_TOKENS_FOR_OVERLAP).
    private static let meaningfulCoverageThreshold = 0.55
    private static let meaningfulSequenceThreshold = 0.55
    private static let minMeaningfulTokensForOverlap = 4

    /// ported: transcriptText.js:8-78 (LOW_SIGNAL_TOKENS), verbatim — the
    /// single-letter entries ("a","d","i","m","s","t") are already excluded
    /// by the len > 1 filter but are kept so the set diffs clean against the
    /// source.
    private static let lowSignalTokens: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "but",
        "by", "d", "did", "do", "does", "for", "from", "had", "has", "have",
        "he", "her", "here", "his", "how", "i", "if", "in", "is", "it",
        "ll", "m", "me", "my", "of", "on", "or", "our", "out", "re",
        "s", "she", "so", "t", "that", "the", "their", "them", "there", "these",
        "they", "this", "those", "to", "ve", "was", "we", "well", "were", "what",
        "when", "where", "which", "who", "why", "with", "without", "you", "your",
    ]

    // MARK: - Public API

    /// Strict overlap: the two texts are (close to) the same utterance.
    /// Normalize → equality/containment shortcut → token-bag coverage OR
    /// longest-common-subsequence ratio over the shorter side, both >= 0.6,
    /// minimum 3 tokens. ported: transcriptText.js:127-146
    /// (transcriptsOverlap).
    static func overlaps(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return false }
        if na == nb { return true }

        let tokensA = tokenize(na)
        let tokensB = tokenize(nb)
        // Containment runs BEFORE the min-token gate, exactly as in the
        // source: "we should" inside "yes we should do that" is a match even
        // though the shorter side has < 3 tokens.
        //
        // Deviation from the port: containment is tested on WHOLE TOKENS,
        // not raw substrings. The source's `includes()` matches inside
        // words — "ok" is a substring of "broken", "hi" of "this" — and on
        // this side of the pipeline a false containment DELETES the user's
        // own mic segment as far-side echo. Word-boundary containment keeps
        // every real case and drops a class of silent data loss.
        if containsTokenRun(tokensA, tokensB) || containsTokenRun(tokensB, tokensA) {
            return true
        }
        let shorter = min(tokensA.count, tokensB.count)
        if shorter < minTokensForOverlap { return false }

        if Double(commonTokenCount(tokensA, tokensB)) / Double(shorter)
            >= tokenCoverageThreshold { return true }
        return Double(longestCommonTokenSubsequence(tokensA, tokensB)) / Double(shorter)
            >= tokenSequenceThreshold
    }

    /// Loose overlap on stopword-filtered "meaningful" tokens (len > 1, not
    /// in the low-signal set), thresholds 0.55, minimum 4 meaningful tokens.
    /// ported: transcriptText.js:148-167 (transcriptsLooselyOverlap).
    ///
    /// PORTED BUT UNUSED in v1: OpenWhispr only relaxes to this matcher when
    /// its 442-line waveform-correlation detector has tagged the mic segment
    /// `double_talk` (ipcHandlers.js `relaxed:` option in
    /// shouldSkipDuplicateMicSegment / removeRacingMicEntriesFor). v1 ports
    /// only the RMS activity tracker, which cannot tell double-talk from
    /// plain far-side speech, so no call site can justify the looser
    /// thresholds — dropping a mic segment on a 0.55 stopword-filtered match
    /// without that evidence would eat the user's own words. Kept, and
    /// pinned by tests, for when correlation tagging lands.
    static func looselyOverlaps(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return false }
        if na == nb { return true }

        // Whole-token containment, same reasoning as `overlaps` — and over
        // ALL tokens, not the meaningful ones: dropping stopwords first
        // would make "the budget review meeting" a containment match for
        // "budget review meeting agenda items", which is exactly the
        // 4-meaningful-token floor's job to reject.
        if containsTokenRun(tokenize(na), tokenize(nb))
            || containsTokenRun(tokenize(nb), tokenize(na)) { return true }

        let tokensA = meaningfulTokens(na)
        let tokensB = meaningfulTokens(nb)
        let shorter = min(tokensA.count, tokensB.count)
        if shorter < minMeaningfulTokensForOverlap { return false }

        if Double(commonTokenCount(tokensA, tokensB)) / Double(shorter)
            >= meaningfulCoverageThreshold { return true }
        return Double(longestCommonTokenSubsequence(tokensA, tokensB)) / Double(shorter)
            >= meaningfulSequenceThreshold
    }

    /// Every contiguous concatenation (run length 1...mergeLimit) of the
    /// segments within ±window of `around`, time-sorted — an echo that
    /// straddles two 5 s system chunks still matches the merged pair even
    /// though it matches neither chunk alone. Order-preserving dedup, first
    /// occurrence wins (the JS Set iterates in insertion order; a Swift Set
    /// would not, and deterministic output is what the tests pin).
    /// ported: transcriptText.js:169-203 (buildMergedCandidates).
    static func mergedCandidates(segments: [(text: String, at: Date)],
                                 around: Date,
                                 window: TimeInterval = TranscriptMatcher.duplicateWindowSeconds,
                                 mergeLimit: Int = TranscriptMatcher.duplicateMergeLimit)
        -> [String] {
        // The source also admits segments with a null timestamp; our tuples
        // are non-optional (MeetingSegment always carries capturedAt), so
        // that branch vanishes. The source's `extraSegment` option is folded
        // into `segments` by the caller — same effect, one code path.
        let nearby = segments
            .filter { !$0.text.isEmpty && abs($0.at.timeIntervalSince(around)) <= window }
            .sorted { $0.at < $1.at }

        var seen = Set<String>()
        var out: [String] = []
        for start in nearby.indices {
            var merged = ""
            for end in start..<min(nearby.count, start + mergeLimit) {
                merged += merged.isEmpty ? nearby[end].text : " " + nearby[end].text
                if seen.insert(merged).inserted { out.append(merged) }
            }
        }
        return out
    }

    // MARK: - Ported internals

    /// Lowercase, strip everything that is not a Unicode letter or number to
    /// a space, collapse runs, trim. ported: transcriptText.js:80-85
    /// (normalizeTranscriptText, regex /[^\p{L}\p{N}\s]/gu then /\s+/g). The
    /// JS regex classes are the Unicode general categories L* and N*, matched
    /// per scalar below — CharacterSet.alphanumerics would also admit marks
    /// (M*) and drift from the source.
    private static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for s in text.lowercased().unicodeScalars {
            scalars.append(isLetterOrNumber(s) ? s : " ")
        }
        // split/rejoin performs both the \s+ collapse and the trim; JS \s
        // (tabs, newlines, NBSP…) all landed in the "not letter/number"
        // bucket above, so they collapse identically.
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    private static func isLetterOrNumber(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// Normalized text is already single-spaced and trimmed, so a plain
    /// split yields the token array the source gets from .split(" ").
    private static func tokenize(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    /// ported: transcriptText.js:121-125 (toMeaningfulTokens).
    private static func meaningfulTokens(_ normalized: String) -> [String] {
        tokenize(normalized).filter { $0.count > 1 && !lowSignalTokens.contains($0) }
    }

    /// Is `needle` a contiguous run of whole tokens inside `haystack`?
    /// The word-boundary replacement for the source's raw `includes()`.
    private static func containsTokenRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        let last = haystack.count - needle.count
        for offset in 0...last where Array(haystack[offset..<offset + needle.count]) == needle {
            return true
        }
        return false
    }

    /// Multiset intersection size — each occurrence in `a` can absorb at
    /// most one occurrence in `b`. ported: transcriptText.js:103-119
    /// (countCommonTokens).
    private static func commonTokenCount(_ a: [String], _ b: [String]) -> Int {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(a.count)
        for token in a { counts[token, default: 0] += 1 }
        var common = 0
        for token in b {
            guard let remaining = counts[token], remaining > 0 else { continue }
            counts[token] = remaining - 1
            common += 1
        }
        return common
    }

    /// Token-level LCS length. The source builds the full DP matrix
    /// (transcriptText.js:87-101); two rolling rows compute the identical
    /// value in O(min-side) memory — candidate strings are at most 3 merged
    /// chunks (~120 tokens), so either way is microseconds, but the rows
    /// keep the transcriber tick allocation-flat.
    private static func longestCommonTokenSubsequence(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var cur = prev
        for i in 1...a.count {
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1] + 1
                    : max(prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
