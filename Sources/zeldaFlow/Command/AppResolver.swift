import Foundation
import AppKit

/// Resolves a spoken app name ("safari", "chrome", "vs code") to the real
/// name of an installed application, so launching never depends on the LLM
/// (or the user) spelling the bundle name exactly right.
enum AppResolver {
    /// Common spoken shorthands → real app names. Applied before matching, so
    /// "chrome" finds Google Chrome even though no bundle is named "Chrome".
    private static let aliases: [String: String] = [
        "chrome": "Google Chrome",
        "google chrome browser": "Google Chrome",
        "vs code": "Visual Studio Code",
        "vscode": "Visual Studio Code",
        "code": "Visual Studio Code",
        "settings": "System Settings",
        "system preferences": "System Settings",
        "preferences": "System Settings",
        "word": "Microsoft Word",
        "excel": "Microsoft Excel",
        "powerpoint": "Microsoft PowerPoint",
        "outlook": "Microsoft Outlook",
        "teams": "Microsoft Teams",
        "text editor": "TextEdit",
        "intellij": "IntelliJ IDEA",
        "terminal app": "Terminal",
    ]

    /// Best installed-app name for a spoken name, or nil when nothing matches.
    static func resolve(_ spoken: String) -> String? {
        let raw = normalize(spoken)
        guard !raw.isEmpty else { return nil }
        let query = aliases[raw].map(normalize) ?? raw
        let apps = installedAppNames()

        if let hit = best(apps.filter { normalize($0) == query }) { return hit }
        if let hit = best(apps.filter { normalize($0).hasPrefix(query) }) { return hit }
        // Word-start match only ("chrome" → "Google Chrome") — a bare
        // substring match is dangerous ("tab" hides inside "Database").
        if let hit = best(apps.filter { wordStartMatch(query, in: $0) }) { return hit }
        // All spoken words appear somewhere in the app name, any order
        // ("chrome browser" → "Google Chrome"? no — but "studio code" → VS Code).
        let qTokens = Set(query.split(separator: " "))
        if !qTokens.isEmpty {
            let tokenHits = apps.filter { qTokens.isSubset(of: Set(normalize($0).split(separator: " "))) }
            if let hit = best(tokenHits) { return hit }
        }
        // Alias expansion is still the user's intent even if not installed —
        // `open -a` will then fail with an honest "no app called X".
        return aliases[raw]
    }

    /// Services people ask for by app name that may not be installed on this
    /// Mac — the web app is what they mean there. Only used after install
    /// resolution fails, so a real local app always wins.
    private static let webFallbacks: [String: String] = [
        "spotify": "https://open.spotify.com",
        "youtube": "https://www.youtube.com",
        "youtube music": "https://music.youtube.com",
        "gmail": "https://mail.google.com",
        "google docs": "https://docs.google.com",
        "google drive": "https://drive.google.com",
        "google maps": "https://maps.google.com",
        "netflix": "https://www.netflix.com",
        "whatsapp": "https://web.whatsapp.com",
        "instagram": "https://www.instagram.com",
        "twitter": "https://x.com",
        "chatgpt": "https://chatgpt.com",
        "notion": "https://www.notion.so",
        "figma": "https://www.figma.com",
        "canva": "https://www.canva.com",
        "slack": "https://app.slack.com",
        "discord": "https://discord.com/app",
    ]

    /// Web-app URL for a spoken name that didn't resolve to an installed app.
    static func webFallback(for spoken: String) -> URL? {
        webFallbacks[normalize(spoken)].flatMap(URL.init(string:))
    }

    /// Match against currently RUNNING apps (for "close X") — catches apps
    /// that live outside the standard install folders.
    static func resolveRunning(_ spoken: String) -> String? {
        let query = normalize(aliases[normalize(spoken)] ?? spoken)
        guard !query.isEmpty else { return nil }
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        if let hit = best(names.filter { normalize($0) == query }) { return hit }
        if let hit = best(names.filter { normalize($0).hasPrefix(query) }) { return hit }
        if let hit = best(names.filter { wordStartMatch(query, in: $0) }) { return hit }
        return nil
    }

    private static func wordStartMatch(_ query: String, in name: String) -> Bool {
        normalize(name).split(separator: " ").contains { $0.hasPrefix(query) }
    }

    /// Shortest name wins ties — least-decorated is usually the intended one.
    private static func best(_ matches: [String]) -> String? {
        matches.min { $0.count < $1.count }
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every app on this Mac, for prompting. Read from disk rather than a
    /// bundled list, so whatever the user actually installed is what the model
    /// is told about — including anything that shipped after this build.
    static func installedApps() -> [String] {
        Array(Set(installedAppNames())).sorted()
    }

    private static func installedAppNames() -> [String] {
        let dirs = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",   // Finder
            NSHomeDirectory() + "/Applications",
        ]
        let fm = FileManager.default
        var names: [String] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                if item.hasSuffix(".app") {
                    names.append(String(item.dropLast(4)))
                } else if dir == "/Applications" {
                    // One level of vendor subfolders (Setapp, Adobe, …).
                    let sub = dir + "/" + item
                    for nested in (try? fm.contentsOfDirectory(atPath: sub)) ?? []
                    where nested.hasSuffix(".app") {
                        names.append(String(nested.dropLast(4)))
                    }
                }
            }
        }
        return names
    }
}
