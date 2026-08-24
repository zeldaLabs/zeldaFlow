import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let rawText: String
    let finalText: String
    let appName: String
    let audioSeconds: Double
    let transcribeMs: Int
    let cleanupMs: Int
}

/// Append-only JSONL history at ~/Library/Application Support/zeldaFlow/history.jsonl.
/// Keeps the most recent `maxInMemory` entries loaded for the UI.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []  // newest first
    private let maxInMemory = 500
    private let queue = DispatchQueue(label: "zeldaflow.history", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    var totalWords: Int {
        entries.reduce(0) { $0 + $1.finalText.split(separator: " ").count }
    }

    // MARK: - Dashboard stats

    /// Dictations only — command runs (rawText "⌘ …") would skew word stats.
    private var dictations: [HistoryEntry] {
        entries.filter { !$0.rawText.hasPrefix("⌘") }
    }

    var dictatedWords: Int {
        dictations.reduce(0) { $0 + $1.finalText.split(separator: " ").count }
    }

    /// Speaking speed across all dictations, words per minute.
    var averageWPM: Int {
        let seconds = dictations.reduce(0.0) { $0 + $1.audioSeconds }
        guard seconds >= 5 else { return 0 }
        return Int((Double(dictatedWords) / (seconds / 60.0)).rounded())
    }

    /// Consecutive days with at least one entry, counting back from today
    /// (yesterday still counts as an unbroken streak if today is quiet so far).
    var dayStreak: Int {
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day),
                  days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    var hasDictated: Bool { !dictations.isEmpty }
    var hasUsedCommands: Bool { entries.contains { $0.rawText.hasPrefix("⌘") } }
    var hasPlayedMusic: Bool {
        entries.contains { $0.rawText.hasPrefix("⌘") && $0.finalText.lowercased().contains("play") }
    }

    func add(_ entry: HistoryEntry) {
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxInMemory {
                self.entries.removeLast(self.entries.count - self.maxInMemory)
            }
        }
        queue.async {
            guard let data = try? self.encoder.encode(entry) else { return }
            let line = data + Data("\n".utf8)
            let url = Paths.historyFile
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            }
        }
    }

    func clearAll() {
        DispatchQueue.main.async { self.entries = [] }
        queue.async {
            try? FileManager.default.removeItem(at: Paths.historyFile)
        }
    }

    private func load() {
        queue.async {
            guard let data = try? Data(contentsOf: Paths.historyFile),
                  let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n").suffix(self.maxInMemory)
            var loaded: [HistoryEntry] = []
            for line in lines {
                if let entry = try? self.decoder.decode(HistoryEntry.self, from: Data(line.utf8)) {
                    loaded.append(entry)
                }
            }
            let newestFirst = Array(loaded.reversed())
            DispatchQueue.main.async { self.entries = newestFirst }
        }
    }
}
