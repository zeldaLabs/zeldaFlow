import AppKit

/// Live check of the file/folder actions, run against a real scratch folder in
/// the user's Downloads and cleaned up afterwards.
///
/// The refusal cases matter more than the happy path here: every one of them is
/// a way a misheard sentence could destroy something.
enum FileEvals {
    static func run() -> Int32 {
        print("zeldaFlow file evals — creates and trashes a scratch folder in ~/Downloads")
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task { @MainActor in
            code = await runAll()
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return code
    }

    @MainActor
    private static func runAll() async -> Int32 {
        var failures = 0
        let root = "downloads/zeldaflow-eval"

        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("    \(ok ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        // Path resolution: spoken phrasing must land on real directories.
        print("\n  resolving spoken paths:")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cases: [(String, String?)] = [
            ("downloads", "\(home)/Downloads"),
            ("my downloads folder", "\(home)/Downloads"),
            ("in the desktop", "\(home)/Desktop"),
            ("documents/work/notes.txt", "\(home)/Documents/work/notes.txt"),
            ("~/Pictures", "\(home)/Pictures"),
            // Must be refused: outside the home directory.
            ("/System/Library", nil),
            ("../../etc/passwd", nil),
            ("downloads/../../../etc/hosts", nil),
        ]
        for (spoken, expected) in cases {
            let got = FileActions.resolve(spoken)?.path
            check("\"\(spoken)\"", got == expected, got ?? "refused")
        }

        // Create → list → move → trash, on real files.
        print("\n  create / move / list / trash:")
        let mk = await FileActions.createFolder(
            ZeldaFlowAction(action: "create_folder", target: root))
        check("create folder", mk.ok, mk.summary)

        let mkFile = await FileActions.createFile(
            ZeldaFlowAction(action: "create_file", text: "hello",
                            title: "\(root)/notes.txt"))
        check("create file", mkFile.ok, mkFile.summary)

        let mkSub = await FileActions.createFolder(
            ZeldaFlowAction(action: "create_folder", target: "\(root)/archive"))
        check("create subfolder", mkSub.ok, mkSub.summary)

        let moved = await FileActions.move(
            ZeldaFlowAction(action: "move_file", destination: "\(root)/archive",
                            target: "\(root)/notes.txt"))
        check("move into subfolder", moved.ok, moved.summary)

        let listed = await FileActions.list(
            ZeldaFlowAction(action: "list_files", target: "\(root)/archive"))
        check("list folder", listed.ok && (listed.payload?.contains("notes.txt") ?? false),
              listed.summary)

        // Refusals that protect the user's data.
        print("\n  refusals:")
        let wholeFolder = await FileActions.delete(
            ZeldaFlowAction(action: "delete_file", target: "downloads"))
        check("won't trash ~/Downloads itself", !wholeFolder.ok, wholeFolder.summary)

        let outside = await FileActions.delete(
            ZeldaFlowAction(action: "delete_file", target: "/System/Library/Fonts"))
        check("won't touch /System", !outside.ok, outside.summary)

        let missing = await FileActions.delete(
            ZeldaFlowAction(action: "delete_file", target: "\(root)/nope.txt"))
        check("reports missing file", !missing.ok, missing.summary)

        // Every delete is confirmed, and the prompt shows the resolved path.
        let gate = ActionGate.alwaysConfirmLabel(
            for: ZeldaFlowAction(action: "delete_file", target: "\(root)/archive/notes.txt"))
        check("delete is always confirmed", gate != nil, gate ?? "NOT GATED")
        check("confirmation shows resolved path",
              gate?.contains("~/Downloads/zeldaflow-eval/archive/notes.txt") ?? false,
              gate ?? "")

        // Real trash, then verify it's gone from disk.
        print("\n  trashing:")
        let trashed = await FileActions.delete(
            ZeldaFlowAction(action: "delete_file", target: root))
        check("trash scratch folder", trashed.ok, trashed.summary)
        let stillThere = FileActions.resolve(root).map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? true
        check("folder is gone from Downloads", !stillThere)

        // The machine's real app list — what makes "open iPhone Mirroring" work.
        print("\n  installed apps discovered from this Mac:")
        let apps = AppResolver.installedApps()
        print("    \(apps.count) apps")
        check("found a plausible app list", apps.count > 10, "\(apps.count)")
        for probe in ["Safari", "iPhone Mirroring", "Finder", "System Settings"] {
            let has = apps.contains { $0.localizedCaseInsensitiveContains(probe) }
            print("      \(has ? "✓" : "·") \(probe)")
        }

        print(failures == 0
              ? "\nOK — file and folder control works, and refuses what it should"
              : "\nFAIL — \(failures) problem(s)")
        return failures == 0 ? 0 : 1
    }
}
