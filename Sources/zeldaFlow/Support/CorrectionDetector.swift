import AppKit
import ApplicationServices

/// Learns from the user's own corrections: after a dictation is pasted, two
/// delayed one-shot reads of the focused text field check whether the user
/// retyped one of the inserted words ("coupon" → "KubeCon"). A retype is the
/// strongest vocabulary evidence there is — the user just supplied the exact
/// spelling, in context, seconds after the decoder got it wrong (ADR 0037).
///
/// Everything fails closed: no anchors, a rewrite, an ambiguous diff, a
/// changed app, secure input — all mean "no candidate", never a guess. The
/// probes are bounded pulls in the ScreenContext mold (ADR 0019); there are
/// no standing AX observers and no keystroke watching anywhere in this file.
enum CorrectionDetector {

    struct Candidate: Equatable {
        let from: String   // what dictation inserted
        let to: String     // what the user retyped it into
    }

    // MARK: - Pure core (pinned by --evaldictionary)

    /// Word-diff the pasted text against the field's current value and return
    /// the single best correction pair, or nil for "nothing worth learning".
    /// `knownWords`/`knownReplacements` suppress pairs the dictionary already
    /// covers. Only the located inserted span is ever compared — text the
    /// user wrote around it is out of bounds by construction.
    static func detect(inserted: String, fieldValue: String,
                       knownWords: [String] = [],
                       knownReplacements: [String: String] = [:]) -> Candidate? {
        let ins = tokens(inserted)
        guard ins.count >= 4 else { return nil }           // too short to anchor
        let field = tokens(fieldValue)
        guard !field.isEmpty else { return nil }
        let insLower = ins.map { $0.lowercased() }
        let fieldLower = field.map { $0.lowercased() }

        // Unchanged: the full inserted run still sits in the field verbatim.
        // Case-sensitive — a recapitalized word IS a correction (ADR 0037).
        if containsRun(field, ins) { return nil }

        guard let span = locateSpan(insLower: insLower, fieldLower: fieldLower)
        else { return nil }
        guard abs(span.count - ins.count) <= 5 else { return nil }  // rewrote the region

        let spanTokens = Array(field[span])
        let spanLower = Array(fieldLower[span])
        let (subs, matches) = align(a: insLower, b: spanLower)
        // Case-only respellings align as matches (the diff is lowercased), so
        // they surface from the matched positions, not the substitutions —
        // and they never count toward the rewrite guard.
        let caseOnly = matches.filter { ins[$0.0] != spanTokens[$0.1] }
        // One changed word is always a plausible correction; several changed
        // words must stay a small fraction of the text or it was a rewrite.
        guard subs.count <= 3,
              subs.count <= 1 || subs.count * 5 <= ins.count else { return nil }
        guard !subs.isEmpty || !caseOnly.isEmpty else { return nil }

        let known = Set(knownWords.map { $0.lowercased() })
        let mapped = Set(knownReplacements.keys.map { $0.lowercased() })
        var best: (candidate: Candidate, score: Double)?
        for (i, j) in subs + caseOnly {
            guard i >= 0, j >= 0 else { continue }   // unequal-gap churn marker
            let from = ins[i], to = spanTokens[j]
            guard isLikelyCorrection(from: from, to: to),
                  !known.contains(to.lowercased()),
                  !mapped.contains(from.lowercased()) else { continue }
            let d = Double(levenshtein(from.lowercased(), to.lowercased()))
            let score = 1.0 - d / Double(max(from.count, to.count))
            if best == nil || score > best!.score {
                best = (Candidate(from: from, to: to), score)
            }
        }
        return best?.candidate
    }

    /// Is `from` → `to` plausibly the same spoken word respelled, rather than
    /// a content edit? Case-only changes qualify ("github" → "GitHub"). With
    /// a shared first letter a generous edit distance passes ("kubcon" →
    /// "KubeCon"); with different first letters only a tiny edit on a longer
    /// word does ("sindy" → "Cindy" — sound-alike spellings often disagree on
    /// the first letter). "tomorrow" → "Friday" and "cat" → "hat" both fail.
    static func isLikelyCorrection(from: String, to: String) -> Bool {
        guard from != to, (2...30).contains(to.count), from.count >= 2,
              to.contains(where: \.isLetter) else { return false }
        let fl = from.lowercased(), tl = to.lowercased()
        if fl == tl { return true }                         // case-only respelling
        let maxLen = max(fl.count, tl.count)
        let d = levenshtein(fl, tl)
        if fl.first == tl.first { return d <= max(2, maxLen / 2) }
        return maxLen >= 5 && d <= 2
    }

    /// Words as the diff sees them: letters/digits plus the joiners that live
    /// inside real words. Punctuation between words never produces a token.
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: {
            !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "'" || $0 == "-")
        }).map(String.init)
    }

    /// Locate the pasted run inside the field via 3-word lead/trail anchors.
    /// The LAST lead occurrence wins — the freshest paste is nearest the end.
    /// Nil when no anchor survives (the user rewrote even the edges).
    private static func locateSpan(insLower: [String], fieldLower: [String]) -> Range<Int>? {
        let lead = Array(insLower.prefix(3))
        let trail = Array(insLower.suffix(3))
        let leadIdx = lastIndexOfRun(fieldLower, lead)
        var trailIdx: Int?
        if let l = leadIdx {
            trailIdx = firstIndexOfRun(fieldLower, trail, from: l + lead.count - 3)
        } else {
            trailIdx = lastIndexOfRun(fieldLower, trail)
        }
        if let l = leadIdx, let t = trailIdx, t + 3 > l {
            return l..<(t + 3)
        }
        // One anchor: v1 corrections are 1→1 word swaps, so the span is the
        // same length as the insert — extra slack here would only manufacture
        // churn out of whatever the user typed next.
        if let l = leadIdx {
            return l..<min(l + insLower.count, fieldLower.count)
        }
        if let t = trailIdx {
            let end = t + 3
            return max(0, end - insLower.count)..<end
        }
        return nil
    }

    private static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        firstIndexOfRun(haystack, needle, from: 0) != nil
    }

    private static func firstIndexOfRun(_ hay: [String], _ needle: [String], from: Int) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        for i in max(0, from)...(hay.count - needle.count)
        where Array(hay[i..<i + needle.count]) == needle { return i }
        return nil
    }

    private static func lastIndexOfRun(_ hay: [String], _ needle: [String]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        for i in stride(from: hay.count - needle.count, through: 0, by: -1)
        where Array(hay[i..<i + needle.count]) == needle { return i }
        return nil
    }

    /// LCS walk of the two (lowercased) token runs → aligned 1→1 mismatches
    /// plus the matched positions. Gaps of equal width pair up positionally;
    /// unequal gaps (inserts/deletes) yield churn markers, never pairs — a
    /// 2→1 merge is a v2 problem, guessing at it is not.
    private static func align(a: [String], b: [String])
        -> (subs: [(Int, Int)], matches: [(Int, Int)]) {
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1
                                        : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var matches: [(Int, Int)] = []
        var i = 0, j = 0
        var gapA: [Int] = [], gapB: [Int] = []
        func flushGap() {
            if gapA.count == gapB.count {
                pairs.append(contentsOf: zip(gapA, gapB))
            } else {
                // Unequal gap: count every skipped token as a substitution so
                // the caller's rewrite guard sees the churn, pair up nothing.
                pairs.append(contentsOf: Array(repeating: (-1, -1),
                                               count: max(gapA.count, gapB.count)))
            }
            gapA = []; gapB = []
        }
        while i < n, j < m {
            if a[i] == b[j] {
                flushGap(); matches.append((i, j)); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                gapA.append(i); i += 1
            } else {
                gapB.append(j); j += 1
            }
        }
        gapA.append(contentsOf: i..<n)
        gapB.append(contentsOf: j..<m)
        flushGap()
        return (pairs, matches)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1,
                             prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}

/// Arms after each pasted dictation and runs the two probes. Owned by
/// AppState; delivery hops back to the main actor as a two-word Candidate —
/// the raw field text never leaves the probe queue.
@MainActor
final class CorrectionWatcher {
    var onCandidate: ((CorrectionDetector.Candidate) -> Void)?

    private struct Context {
        let inserted: String
        let bundleID: String?
        let generation: Int
    }

    private var context: Context?
    private var probeWork: [DispatchWorkItem] = []
    /// AX blocks in mach IPC (ADR 0019) — probes never run on main.
    private static let queue = DispatchQueue(label: "zeldaFlow.correction-probe",
                                             qos: .utility)
    private static let probeDelays: [TimeInterval] = [5, 12]
    private static let axCallTimeout: Float = 0.25
    private static let maxFieldChars = 20_000

    func arm(inserted: String, bundleID: String?, generation: Int) {
        disarm()
        guard AppSettings.shared.learnFromCorrections else { return }
        context = Context(inserted: inserted, bundleID: bundleID, generation: generation)
        for (i, delay) in Self.probeDelays.enumerated() {
            let last = i == Self.probeDelays.count - 1
            let work = DispatchWorkItem { [weak self] in
                self?.probe(generation: generation, last: last)
            }
            probeWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func disarm() {
        probeWork.forEach { $0.cancel() }
        probeWork = []
        context = nil
    }

    private func probe(generation: Int, last: Bool) {
        guard let ctx = context, ctx.generation == generation else { return }
        // The world must still look like the one we pasted into.
        guard !Permissions.secureInputActive,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              ctx.bundleID == nil || front.bundleIdentifier == ctx.bundleID
        else { disarm(); return }
        if last { context = nil }

        let pid = front.processIdentifier
        let inserted = ctx.inserted
        let words = AppSettings.shared.dictionaryWords
        let replacements = AppSettings.shared.replacements
        Self.queue.async { [weak self] in
            guard let value = Self.focusedFieldValue(pid: pid) else {
                DispatchQueue.main.async { self?.disarm() }   // fail closed
                return
            }
            let candidate = CorrectionDetector.detect(
                inserted: inserted, fieldValue: value,
                knownWords: words, knownReplacements: replacements)
            guard let candidate else { return }               // unchanged: wait for probe 2
            DispatchQueue.main.async {
                self?.disarm()
                self?.onCandidate?(candidate)
            }
        }
    }

    /// Exactly two bounded AX calls: focused element, then its value. Nil for
    /// anything but an ordinary text element with a sane amount of text —
    /// secure fields are refused by role before their value is ever asked for.
    private static func focusedFieldValue(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axCallTimeout)
        var elRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                app, kAXFocusedUIElementAttribute as CFString, &elRef) == .success,
              let elRaw = elRef, CFGetTypeID(elRaw) == AXUIElementGetTypeID()
        else { return nil }
        let el = elRaw as! AXUIElement
        AXUIElementSetMessagingTimeout(el, axCallTimeout)

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, role == "AXSecureTextField" { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              !value.isEmpty, value.count <= maxFieldChars else { return nil }
        return value
    }
}
