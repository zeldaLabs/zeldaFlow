import AppKit

/// Files and folders by voice: create, rename, move, reveal, delete.
///
/// Two rules shape this whole file.
///
/// Deletes go to the Trash, never to `unlink`. A misheard filename is going to
/// happen eventually, and the difference between "wrong file in the Trash" and
/// "wrong file gone" is the difference between an annoyance and a disaster.
///
/// Paths are resolved, not interpolated. Nothing here builds a shell string, so
/// a filename containing quotes, semicolons or `$(…)` is just an odd filename.
enum FileActions {
    /// Spoken place names → real directories. Only locations a person would
    /// name out loud; anything else has to arrive as an explicit path.
    private static let places: [String: FileManager.SearchPathDirectory] = [
        "downloads": .downloadsDirectory,
        "desktop": .desktopDirectory,
        "documents": .documentDirectory,
        "pictures": .picturesDirectory,
        "music": .musicDirectory,
        "movies": .moviesDirectory,
        "applications": .applicationDirectory,
    ]

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Turn what the user said into a URL under their home directory.
    ///
    /// Everything is confined to the home directory. Voice is not a good
    /// interface for editing /System or /Library, and a transcription slip
    /// that escapes into them is not worth the capability.
    static func resolve(_ spoken: String) -> URL? {
        var s = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // "in my downloads folder" / "the desktop" — strip the filler a person
        // naturally says around a location.
        for filler in ["in my ", "in the ", "my ", "the ", "folder ", "in "] where s.lowercased().hasPrefix(filler) {
            s = String(s.dropFirst(filler.count))
        }
        if s.lowercased().hasSuffix(" folder") { s = String(s.dropLast(7)) }

        var url: URL
        if s.hasPrefix("~/") {
            url = home.appendingPathComponent(String(s.dropFirst(2)))
        } else if s.hasPrefix("/") {
            url = URL(fileURLWithPath: s)
        } else {
            // Leading component may name a known place ("downloads/report.pdf").
            var parts = s.split(separator: "/").map(String.init)
            guard let first = parts.first else { return nil }
            if let dir = places[first.lowercased()],
               let base = FileManager.default.urls(for: dir, in: .userDomainMask).first {
                parts.removeFirst()
                url = parts.reduce(base) { $0.appendingPathComponent($1) }
            } else {
                url = parts.reduce(home) { $0.appendingPathComponent($1) }
            }
        }
        url = url.standardizedFileURL

        // ".." can climb out of home even after standardising a relative path.
        guard url.path == home.path || url.path.hasPrefix(home.path + "/") else {
            Log.error("file action refused, outside home: \(url.path)")
            return nil
        }
        return url
    }

    /// Human-readable path for confirmations — "~/Downloads/report.pdf".
    static func pretty(_ url: URL) -> String {
        url.path.hasPrefix(home.path)
            ? "~" + url.path.dropFirst(home.path.count)
            : url.path
    }

    // MARK: - Actions

    @MainActor
    static func createFolder(_ a: ZeldaFlowAction) async -> ActionOutcome {
        guard let spoken = a.target ?? a.text, let url = resolve(spoken) else {
            return ActionOutcome(ok: false, summary: "[create_folder: bad path]",
                                 pillMessage: "Where should I create it?")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return ActionOutcome(ok: false, summary: "[create_folder exists: \(url.path)]",
                                 pillMessage: "\(pretty(url)) already exists")
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            Log.info("created folder \(url.path)")
            return ActionOutcome(ok: true, summary: "[created \(pretty(url))]",
                                 pillMessage: "✓ \(url.lastPathComponent)")
        } catch {
            return ActionOutcome(ok: false, summary: "[create_folder failed: \(error)]",
                                 pillMessage: "Couldn't create \(pretty(url))")
        }
    }

    @MainActor
    static func createFile(_ a: ZeldaFlowAction) async -> ActionOutcome {
        guard let spoken = a.target ?? a.title, let url = resolve(spoken) else {
            return ActionOutcome(ok: false, summary: "[create_file: bad path]",
                                 pillMessage: "What should I call it?")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return ActionOutcome(ok: false, summary: "[create_file exists: \(url.path)]",
                                 pillMessage: "\(pretty(url)) already exists")
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (a.text ?? "").write(to: url, atomically: true, encoding: .utf8)
            Log.info("created file \(url.path)")
            return ActionOutcome(ok: true, summary: "[created \(pretty(url))]",
                                 pillMessage: "✓ \(url.lastPathComponent)")
        } catch {
            return ActionOutcome(ok: false, summary: "[create_file failed: \(error)]",
                                 pillMessage: "Couldn't create \(pretty(url))")
        }
    }

    /// Move to Trash. Recoverable by design — see the note at the top.
    @MainActor
    static func delete(_ a: ZeldaFlowAction) async -> ActionOutcome {
        guard let spoken = a.target ?? a.text, let url = resolve(spoken) else {
            return ActionOutcome(ok: false, summary: "[delete: bad path]",
                                 pillMessage: "Delete what?")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ActionOutcome(ok: false, summary: "[delete missing: \(url.path)]",
                                 pillMessage: "No \(pretty(url))")
        }
        // Trashing a whole standard folder is never what someone means by
        // "delete the downloads folder" — they mean its contents, and getting
        // that wrong takes everything with it.
        if isStandardPlace(url) {
            return ActionOutcome(ok: false, summary: "[delete refused: \(url.path)]",
                                 pillMessage: "I won't trash \(pretty(url)) itself")
        }
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            Log.info("trashed \(url.path)")
            return ActionOutcome(ok: true, summary: "[trashed \(pretty(url))]",
                                 pillMessage: "✓ \(url.lastPathComponent) → Trash")
        } catch {
            return ActionOutcome(ok: false, summary: "[delete failed: \(error)]",
                                 pillMessage: "Couldn't trash \(pretty(url))")
        }
    }

    @MainActor
    static func move(_ a: ZeldaFlowAction) async -> ActionOutcome {
        guard let fromSpoken = a.target, let from = resolve(fromSpoken),
              let toSpoken = a.destination ?? a.text, var to = resolve(toSpoken) else {
            return ActionOutcome(ok: false, summary: "[move: bad path]",
                                 pillMessage: "Move what, and where?")
        }
        guard FileManager.default.fileExists(atPath: from.path) else {
            return ActionOutcome(ok: false, summary: "[move missing: \(from.path)]",
                                 pillMessage: "No \(pretty(from))")
        }
        // "move report.pdf to Documents" names a destination folder, not a
        // destination filename — keep the original name in that case.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: to.path, isDirectory: &isDir), isDir.boolValue {
            to = to.appendingPathComponent(from.lastPathComponent)
        }
        guard !FileManager.default.fileExists(atPath: to.path) else {
            return ActionOutcome(ok: false, summary: "[move exists: \(to.path)]",
                                 pillMessage: "\(pretty(to)) already exists")
        }
        do {
            try FileManager.default.moveItem(at: from, to: to)
            Log.info("moved \(from.path) → \(to.path)")
            return ActionOutcome(ok: true, summary: "[moved \(pretty(from)) → \(pretty(to))]",
                                 pillMessage: "✓ \(to.lastPathComponent)")
        } catch {
            return ActionOutcome(ok: false, summary: "[move failed: \(error)]",
                                 pillMessage: "Couldn't move \(pretty(from))")
        }
    }

    /// Open a Finder window on a folder, or open a file in its default app.
    @MainActor
    static func reveal(_ a: ZeldaFlowAction) async -> ActionOutcome {
        guard let spoken = a.target ?? a.text, let url = resolve(spoken) else {
            return ActionOutcome(ok: false, summary: "[reveal: bad path]",
                                 pillMessage: "Open what?")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ActionOutcome(ok: false, summary: "[reveal missing: \(url.path)]",
                                 pillMessage: "No \(pretty(url))")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return ActionOutcome(ok: true, summary: "[revealed \(pretty(url))]",
                             pillMessage: "✓ \(url.lastPathComponent)")
    }

    /// What's in a folder — so "what's in my downloads" can be answered.
    @MainActor
    static func list(_ a: ZeldaFlowAction) async -> ActionOutcome {
        guard let spoken = a.target ?? a.text, let url = resolve(spoken) else {
            return ActionOutcome(ok: false, summary: "[list: bad path]",
                                 pillMessage: "List what?")
        }
        guard let items = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else {
            return ActionOutcome(ok: false, summary: "[list failed: \(url.path)]",
                                 pillMessage: "Couldn't read \(pretty(url))")
        }
        let sorted = items.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a > b
        }
        let names = sorted.map(\.lastPathComponent)
        let body = names.isEmpty ? "(empty)" : names.joined(separator: "\n")
        return ActionOutcome(
            ok: true, summary: "[listed \(pretty(url)): \(names.count) items]",
            pillMessage: "\(names.count) in \(url.lastPathComponent): "
                + names.prefix(3).joined(separator: ", "),
            payload: "\(pretty(url))\n\n\(body)")
    }

    /// True for ~/Downloads itself, as opposed to something inside it.
    private static func isStandardPlace(_ url: URL) -> Bool {
        if url.standardizedFileURL.path == home.path { return true }
        return places.values.contains { dir in
            FileManager.default.urls(for: dir, in: .userDomainMask).first?
                .standardizedFileURL.path == url.standardizedFileURL.path
        }
    }
}
