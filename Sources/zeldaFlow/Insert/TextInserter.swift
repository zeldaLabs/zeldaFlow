import Foundation
import AppKit
import Carbon

enum InsertResult {
    case pasted
    case leftOnClipboard(reason: String)
}

/// Inserts text at the cursor of the frontmost app: save clipboard → set text
/// → synthetic Cmd-V → restore clipboard. The approach every shipping
/// dictation tool uses (Wispr Flow, VoiceInk, Hex) because it works in
/// native apps, Electron, and terminals alike.
///
/// Everything here is async with suspending sleeps: the Fn event tap's
/// run-loop source lives on the main thread, and macOS disables a tap whose
/// callback goes unserviced — a Thread.sleep here while pasting was enough
/// to kill the hotkey under load.
enum TextInserter {
    /// nspasteboard.org convention: clipboard managers skip transient writes.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    // MARK: - Serialization

    /// Overlapping calls are reachable now that everything here suspends (an
    /// agent flow typing into Claude while a fresh dictation finishes, a
    /// menu re-paste mid-pipeline). Interleaved clipboard snapshots, writes
    /// and synthetic keystrokes would paste the wrong text and lose the
    /// user's clipboard — so every entry point chains behind the previous
    /// one. The deferred clipboard restore is a link on the same chain: a
    /// later insert can never snapshot our transient text as the user's
    /// "previous" clipboard.
    @MainActor private static var chainTail: Task<Void, Never>?

    @MainActor
    private static func chained<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> Task<T, Never> {
        let previous = chainTail
        let task = Task<T, Never> {
            await previous?.value
            return await op()
        }
        chainTail = Task { _ = await task.value }
        return task
    }

    /// Chains the paste cycle and its clipboard restore as two links:
    /// insert() returns as soon as the paste is posted, while the restore
    /// still blocks whatever chains next.
    @MainActor
    private static func chainedInsert(_ text: String, expectedFrontmost: String?)
        -> Task<InsertResult, Never> {
        let previous = chainTail
        let paste = Task<(result: InsertResult, restore: (@Sendable () async -> Void)?), Never> {
            await previous?.value
            return await performInsert(text, expectedFrontmost: expectedFrontmost)
        }
        let tail = Task<Void, Never> {
            await (await paste.value).restore?()
        }
        chainTail = tail
        return Task { (await paste.value).result }
    }

    /// - Parameter expectedFrontmost: bundle ID of the app dictation started
    ///   in. If focus moved to a different app by the time we're ready to
    ///   paste, don't type into the wrong window — leave the text on the
    ///   clipboard instead. Pass nil to skip that check (menu re-paste), in
    ///   which case only pasting into our own windows is refused.
    static func insert(_ text: String, expectedFrontmost: String?) async -> InsertResult {
        await chainedInsert(text, expectedFrontmost: expectedFrontmost).value
    }

    private static func performInsert(_ text: String, expectedFrontmost: String?)
        async -> (result: InsertResult, restore: (@Sendable () async -> Void)?) {
        guard !text.isEmpty else { return (.leftOnClipboard(reason: "empty"), nil) }

        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let expected = expectedFrontmost {
            if current != expected {
                setClipboard(text, transient: false)
                return (.leftOnClipboard(reason: "Focus changed — press ⌘V to paste"), nil)
            }
        } else if let current, current == Bundle.main.bundleIdentifier {
            setClipboard(text, transient: false)
            return (.leftOnClipboard(reason: "Copied — click the target app, then ⌘V"), nil)
        }

        // Synthetic keystrokes are rejected while a password field holds
        // secure input; put the text on the clipboard so nothing is lost.
        if Permissions.secureInputActive {
            setClipboard(text, transient: false)
            return (.leftOnClipboard(reason: "Secure input active — press ⌘V to paste"), nil)
        }

        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard(pb)

        setClipboard(text, transient: true)
        let ourChangeCount = pb.changeCount

        // Give slow apps (Electron) time to observe the new clipboard.
        try? await Task.sleep(nanoseconds: 120_000_000)
        await postCmdV()

        // Restore the previous clipboard once the paste has landed, but only
        // if nothing else wrote to the pasteboard in the meantime.
        let restore: (@Sendable () async -> Void)? = snapshot.map { snap in
            {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let pb = NSPasteboard.general
                if pb.changeCount == ourChangeCount {
                    restorePasteboard(pb, snapshot: snap)
                }
            }
        }
        return (.pasted, restore)
    }

    // MARK: - Pasteboard plumbing

    private static func setClipboard(_ text: String, transient: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()

        // Markdown-looking content also goes on the pasteboard as RTF and
        // HTML, so rich editors (Notes, Pages, Word, Docs) paste real
        // headings/bold/bullets while plain editors still get the markdown.
        var rtf: Data?
        var html: Data?
        if MarkdownRenderer.looksLikeMarkdown(text) {
            let rendered = MarkdownRenderer.render(text)
            let range = NSRange(location: 0, length: rendered.length)
            rtf = try? rendered.data(from: range, documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf])
            html = try? rendered.data(from: range, documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html])
        }

        var types: [NSPasteboard.PasteboardType] = []
        if rtf != nil { types.append(.rtf) }
        if html != nil { types.append(.html) }
        types.append(.string)
        if transient { types.append(transientType) }
        pb.declareTypes(types, owner: nil)
        if let rtf { pb.setData(rtf, forType: .rtf) }
        if let html { pb.setData(html, forType: .html) }
        pb.setString(text, forType: .string)
    }

    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]]? {
        guard let items = pb.pasteboardItems, !items.isEmpty else { return nil }
        var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
        for item in items {
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy[type] = data
                }
            }
            if !copy.isEmpty { snapshot.append(copy) }
        }
        return snapshot.isEmpty ? nil : snapshot
    }

    private static func restorePasteboard(_ pb: NSPasteboard,
                                          snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(items)
    }

    /// Copy the current selection in the frontmost app (synthetic ⌘C) and
    /// return its plain text. Returns nil if nothing was copied within 1 s.
    /// Note: the selection text intentionally stays on the clipboard — the
    /// subsequent insert()'s snapshot/restore cycle treats it as "previous".
    static func copySelection() async -> String? {
        await chained { await performCopySelection() }.value
    }

    private static func performCopySelection() async -> String? {
        guard !Permissions.secureInputActive else { return nil }
        let pb = NSPasteboard.general
        let before = pb.changeCount
        await postCmdKey(8)   // kVK_ANSI_C
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pb.changeCount != before {
                return pb.string(forType: .string)
            }
        }
        return nil
    }

    private static func postCmdV() async { await postCmdKey(9) }   // kVK_ANSI_V

    private static func postCmdKey(_ key: CGKeyCode) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdKey: CGKeyCode = 55   // kVK_Command

        let events: [(CGKeyCode, Bool, CGEventFlags)] = [
            (cmdKey, true, .maskCommand),
            (key, true, .maskCommand),
            (key, false, .maskCommand),
            (cmdKey, false, []),
        ]
        for (key, down, flags) in events {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            // Marker so our own event tap passes these through untouched.
            e.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticEventMarker)
            e.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    /// Press one key (with optional modifiers) in the frontmost app — Return
    /// to send, ⌘N for a new window. Same synthetic-event path as ⌘V.
    static func pressKey(_ key: CGKeyCode, flags: CGEventFlags = []) async {
        await chained { await performPressKey(key, flags: flags) }.value
    }

    private static func performPressKey(_ key: CGKeyCode, flags: CGEventFlags) async {
        guard !Permissions.secureInputActive else { return }
        if flags.contains(.maskCommand) {
            await postCmdKey(key)
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticEventMarker)
            e.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
    }
}
