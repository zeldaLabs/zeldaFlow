import Foundation
import AppKit

/// Web searches and questions open a Google search in the user's default
/// browser — whatever they actually use, not an assumed one.
enum WebAnswer {
    static func run(_ a: ZeldaFlowAction) async -> ActionOutcome {
        let query = (a.query ?? a.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ActionOutcome(ok: false, summary: "[web: no query]",
                                 pillMessage: "What should I look up?")
        }

        // Instant path: math/conversions/stable facts answered offline in
        // the pill when the local model is certain. Live-data questions and
        // anything it doubts still open a real web search.
        let lower = query.lowercased()
        let liveWords = ["score", "live", "today", "now", "news", "weather",
                         "price", "stock", "latest", "current", "tonight"]
        if !liveWords.contains(where: lower.contains) {
            let cleanup = await MainActor.run { AppState.shared.cleanup }
            if await cleanup.ensureReady(timeoutSeconds: 8),
               let answer = await cleanup.instantAnswer(question: query) {
                Log.info("WebAnswer: instant → \(answer.prefix(140))")
                // The payload marks this as an answer (not a status), which
                // is what lets the pill offer a follow-up chat on it.
                return ActionOutcome(ok: true, summary: "[answer: \(answer)]",
                                     pillMessage: "💡 \(answer)", payload: answer)
            }
        }

        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else {
            return ActionOutcome(ok: false, summary: "[web: bad query]",
                                 pillMessage: "Couldn't build that search")
        }
        let ok = await MainActor.run { NSWorkspace.shared.open(url) }
        Log.info("WebAnswer: search → \"\(query)\" (ok: \(ok))")
        return ActionOutcome(ok: ok,
                             summary: ok ? "[searched: \(query)]" : "[search failed: \(query)]",
                             pillMessage: ok ? "🔍 Searching for “\(query)”" : "Couldn't open the browser")
    }
}
