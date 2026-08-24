import AppKit
import ApplicationServices

/// Local Deep Context: reads the visible text of the frontmost window via
/// accessibility, extracts distinctive terms (names, emails, jargon), and
/// biases the current dictation session with them so Whisper and cleanup
/// spell them right. Session-scoped and fully local — the extracted text is
/// discarded when the session ends; nothing ever leaves the Mac.
enum ScreenContext {
    /// Media apps are wall-to-wall song titles and artist names (an artist's
    /// "Essentials" playlist × 20 rows). Feeding those into the STT prompt
    /// biases the decoder toward emitting them on non-speech audio, so these
    /// windows are never harvested.
    private static let mediaApps: Set<String> = [
        "com.apple.Music", "com.apple.TV", "com.apple.podcasts",
        "com.spotify.client", "com.apple.QuickTimePlayerX",
    ]

    /// Per-element cap on AX messaging. The default is ~6 s per call to an
    /// unresponsive app — a tree walk of hundreds of elements against a busy
    /// app could otherwise pin its thread for minutes. Deliberately set per
    /// element, not on the systemwide element: a process-global cap would
    /// also govern MusicUIDriver's UI scripting, which needs the default.
    private static let axCallTimeout: Float = 0.25

    /// A slow app can still cost one messaging timeout per element; the
    /// whole harvest additionally gets a wall-clock budget so it can never
    /// outlive the dictation session it's biasing.
    private static let harvestBudget: TimeInterval = 0.4

    /// Distinctive terms visible in the frontmost window, best first (≤15).
    static func glossaryTerms() -> [String] {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              !mediaApps.contains(front.bundleIdentifier ?? "") else { return [] }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, axCallTimeout)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRaw = winRef, CFGetTypeID(winRaw) == AXUIElementGetTypeID() else { return [] }
        let window = winRaw as! AXUIElement

        var chunks: [String] = []
        var visited = 0
        var totalChars = 0
        let deadline = Date().addingTimeInterval(harvestBudget)
        collect(window, depth: 0, visited: &visited, totalChars: &totalChars,
                into: &chunks, deadline: deadline)
        return extractTerms(from: chunks.joined(separator: "\n"))
    }

    private static func collect(_ el: AXUIElement, depth: Int, visited: inout Int,
                                totalChars: inout Int, into chunks: inout [String],
                                deadline: Date) {
        guard depth < 25, visited < 1500, totalChars < 6000, Date() < deadline else { return }
        visited += 1
        // The timeout doesn't transfer between refs — cap each one (local
        // token write, no IPC).
        AXUIElementSetMessagingTimeout(el, axCallTimeout)
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
               let s = ref as? String, s.count > 2, s.count < 2000 {
                chunks.append(s)
                totalChars += s.count
                break
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            collect(child, depth: depth + 1, visited: &visited, totalChars: &totalChars,
                    into: &chunks, deadline: deadline)
        }
    }

    private static let stopWords: Set<String> = [
        "The", "This", "That", "These", "Those", "And", "But", "For", "You", "Your",
        "With", "From", "Have", "Will", "What", "When", "Where", "How", "Are", "Was",
        "Not", "All", "New", "Open", "Close", "File", "Edit", "View", "Window", "Help",
        "Save", "Cancel", "Done", "Back", "Next", "Search", "Home", "Settings", "Today",
        "Yesterday", "Tomorrow", "About", "More", "Less", "Show", "Hide", "Add", "Delete",
    ]

    /// Emails always win; camelCase/technical tokens score double; plain
    /// capitalized words must recur to beat sentence-start noise.
    private static func extractTerms(from text: String) -> [String] {
        var scores: [String: Int] = [:]

        if let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}") {
            let range = NSRange(text.startIndex..., in: text)
            for m in regex.matches(in: text, range: range) {
                if let r = Range(m.range, in: text) { scores[String(text[r]), default: 0] += 4 }
            }
        }

        let words = text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") })
        for raw in words {
            let s = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
            guard s.count >= 3, s.count <= 30, let first = s.first, first.isLetter else { continue }
            let tail = s.dropFirst()
            let isCamel = tail.contains(where: \.isUppercase) || s.contains(where: \.isNumber)
            if isCamel, !s.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                scores[s, default: 0] += 2
            } else if first.isUppercase, !stopWords.contains(s), !s.allSatisfy(\.isUppercase) {
                scores[s, default: 0] += 1
            }
        }
        return scores.filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(15)
            .map(\.key)
    }
}
