import Foundation

/// Auto-learning dictionary: watches final dictation text for distinctive
/// recurring words and queues them as suggestions in the Hub's Dictionary
/// page. Never interrupts the pill — the user approves or dismisses there.
final class LearnedWords: ObservableObject {
    static let shared = LearnedWords()

    @Published private(set) var suggestions: [String] = []

    private var counts: [String: Int] = [:]
    private var dismissed: Set<String> = []
    private var file: URL { Paths.appSupport.appendingPathComponent("learned-words.json") }
    private struct Blob: Codable {
        var counts: [String: Int]
        var dismissed: [String]
    }

    private init() {
        if let data = try? Data(contentsOf: file),
           let blob = try? JSONDecoder().decode(Blob.self, from: data) {
            counts = blob.counts
            dismissed = Set(blob.dismissed)
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

    private func refresh() {
        let known = Set(AppSettings.shared.dictionaryWords.map { $0.lowercased() })
        suggestions = counts
            .filter { $0.value >= 2 && !dismissed.contains($0.key.lowercased())
                      && !known.contains($0.key.lowercased()) }
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map(\.key)
    }

    private func save() {
        let blob = Blob(counts: counts, dismissed: Array(dismissed))
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
