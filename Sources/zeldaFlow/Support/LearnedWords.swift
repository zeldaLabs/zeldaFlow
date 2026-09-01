import Foundation

/// Auto-learning dictionary: watches final dictation text for distinctive
/// recurring words and queues them as suggestions in the Hub's Dictionary
/// page — and, since ADR 0037, records correction pairs observed after a
/// dictation ("coupon" → "KubeCon") as a second, stronger suggestion source.
/// Every entry still requires the user's explicit approval; frequency
/// suggestions never interrupt, correction pairs may show one idle-only,
/// click-optional pill prompt (ADR 0037 amends ADR 0014).
final class LearnedWords: ObservableObject {
    static let shared = LearnedWords()

    @Published private(set) var suggestions: [String] = []
    @Published private(set) var correctionSuggestions: [CorrectionRecord] = []

    struct CorrectionRecord: Codable, Equatable, Identifiable {
        var from: String
        var to: String
        var count: Int
        var date: Date
        var id: String { Self.key(from: from, to: to) }
        static func key(from: String, to: String) -> String {
            from.lowercased() + "→" + to.lowercased()
        }
    }

    private var counts: [String: Int] = [:]
    private var dismissed: Set<String> = []
    private var corrections: [CorrectionRecord] = []
    private var dismissedPairs: Set<String> = []
    private let file: URL
    private struct Blob: Codable {
        var counts: [String: Int]
        var dismissed: [String]
        // Optional so a pre-0037 learned-words.json still decodes.
        var corrections: [CorrectionRecord]?
        var dismissedPairs: [String]?
    }

    private convenience init() {
        self.init(file: Paths.appSupport.appendingPathComponent("learned-words.json"))
    }

    /// Internal so the evals can run a real instance against a scratch file;
    /// the app only ever uses `shared`.
    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let blob = try? JSONDecoder().decode(Blob.self, from: data) {
            counts = blob.counts
            dismissed = Set(blob.dismissed)
            corrections = blob.corrections ?? []
            dismissedPairs = Set(blob.dismissedPairs ?? [])
        }
        refresh()
    }

    /// Called on the main thread after each dictation lands.
    func observe(_ text: String) {
        let known = Set(AppSettings.shared.dictionaryWords.map { $0.lowercased() })
        for term in Set(Self.candidates(in: text)) {   // once per session each
            let key = term.lowercased()
            guard !dismissed.contains(key), !known.contains(key) else { continue }
            counts[term, default: 0] += 1
        }
        refresh()
        save()
    }

    func approve(_ word: String) {
        if !AppSettings.shared.dictionaryWords.contains(word) {
            AppSettings.shared.dictionaryWords.append(word)
        }
        counts.removeValue(forKey: word)
        refresh()
        save()
    }

    func dismiss(_ word: String) {
        dismissed.insert(word.lowercased())
        counts.removeValue(forKey: word)
        refresh()
        save()
    }

    // MARK: - Correction pairs (ADR 0037)

    /// A detected retype. Recorded even when the pill prompt shows, so an
    /// ignored prompt still lands in the Hub with nothing lost.
    func recordCorrection(from: String, to: String) {
        let key = CorrectionRecord.key(from: from, to: to)
        guard !dismissedPairs.contains(key) else { return }
        let known = Set(AppSettings.shared.dictionaryWords.map { $0.lowercased() })
        guard !known.contains(to.lowercased()) else { return }
        if let i = corrections.firstIndex(where: { $0.id == key }) {
            corrections[i].count += 1
            corrections[i].date = Date()
        } else {
            corrections.append(CorrectionRecord(from: from, to: to, count: 1, date: Date()))
        }
        refresh()
        save()
    }

    /// The one approval path (pill tap and Hub button both land here):
    /// the replacement rule always, the glossary word only when it clears
    /// the distinctiveness bar — a short common word in the Whisper prompt
    /// widens the hallucination filter's kill radius for no gain (ADR 0037).
    func approveCorrection(from: String, to: String) {
        if !AppSettings.shared.replacements.keys
            .contains(where: { $0.lowercased() == from.lowercased() }) {
            AppSettings.shared.replacements[from] = to
        }
        if Self.belongsInGlossary(to),
           !AppSettings.shared.dictionaryWords
            .contains(where: { $0.lowercased() == to.lowercased() }) {
            AppSettings.shared.dictionaryWords.append(to)
        }
        corrections.removeAll { $0.id == CorrectionRecord.key(from: from, to: to) }
        refresh()
        save()
    }

    func dismissCorrection(from: String, to: String) {
        let key = CorrectionRecord.key(from: from, to: to)
        dismissedPairs.insert(key)
        corrections.removeAll { $0.id == key }
        refresh()
        save()
    }

    /// Replacements alone fix short or common words; only distinctive terms
    /// earn a seat in the decoder's prompt.
    static func belongsInGlossary(_ word: String) -> Bool {
        word.count >= 4 && !commonWords.contains(word.lowercased())
    }

    private static let commonWords: Set<String> = [
        "that", "this", "with", "from", "have", "will", "what", "when", "where",
        "your", "them", "they", "then", "than", "there", "their", "about",
        "would", "could", "should", "which", "were", "been", "just", "like",
    ]

    private func refresh() {
        let known = Set(AppSettings.shared.dictionaryWords.map { $0.lowercased() })
        suggestions = counts
            .filter { $0.value >= 2 && !dismissed.contains($0.key.lowercased())
                      && !known.contains($0.key.lowercased()) }
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map(\.key)
        correctionSuggestions = corrections
            .sorted { $0.date > $1.date }
            .prefix(8)
            .map { $0 }
    }

    private func save() {
        let blob = Blob(counts: counts, dismissed: Array(dismissed),
                        corrections: corrections, dismissedPairs: Array(dismissedPairs))
        if let data = try? JSONEncoder().encode(blob) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Distinctive words worth learning: mid-sentence capitalized terms and
    /// camelCase/technical tokens — the ones Whisper tends to fumble.
    static func candidates(in text: String) -> [String] {
        var out: [String] = []
        for sentence in text.split(whereSeparator: { ".!?\n".contains($0) }) {
            let words = sentence.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            for (i, raw) in words.enumerated() {
                let w = String(raw)
                guard w.count >= 4, w.count <= 30, let first = w.first, first.isLetter else { continue }
                let camel = w.dropFirst().contains(where: \.isUppercase)
                let midSentenceCapital = i > 0 && first.isUppercase && !w.allSatisfy(\.isUppercase)
                if camel || midSentenceCapital {
                    out.append(w)
                }
            }
        }
        return out
    }
}
