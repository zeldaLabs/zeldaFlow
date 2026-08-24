import Foundation

/// Well-known file locations. Everything lives under
/// ~/Library/Application Support/zeldaFlow/
enum Paths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("zeldaFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var modelsDir: URL {
        let dir = appSupport.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var whisperModel: URL { modelsDir.appendingPathComponent("ggml-large-v3-turbo-q8_0.bin") }
    static var vadModel: URL { modelsDir.appendingPathComponent("ggml-silero-v6.2.0.bin") }
    static var cleanupModel: URL { modelsDir.appendingPathComponent("gemma-4-E2B-it-Q4_0.gguf") }

    /// Speaker-diarization models (ADR 31), populated by scripts/setup.sh and
    /// loaded fully offline. The two-level layout is FluidAudio's ModelHub
    /// contract: `load(from: diarizerModelsDir)` resolves the repo folder
    /// ("speaker-diarization") itself, so the directory handed to the library
    /// is the parent.
    static var diarizerModelsDir: URL { modelsDir.appendingPathComponent("diarizer", isDirectory: true) }
    static var diarizerRepoDir: URL { diarizerModelsDir.appendingPathComponent("speaker-diarization", isDirectory: true) }
    static let diarizerRequiredFiles = ["Segmentation.mlmodelc", "FBank.mlmodelc",
                                        "Embedding.mlmodelc", "PldaRho.mlmodelc",
                                        "plda-parameters.json"]
    static var diarizerModelsExist: Bool {
        diarizerRequiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: diarizerRepoDir.appendingPathComponent($0).path)
        }
    }

    static var historyFile: URL { appSupport.appendingPathComponent("history.jsonl") }
    static var meetingsFile: URL { appSupport.appendingPathComponent("meetings.jsonl") }
    static var meetingsDir: URL {
        let dir = appSupport.appendingPathComponent("meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var logFile: URL { appSupport.appendingPathComponent("zeldaflow.log") }
    static var llamaLogFile: URL { appSupport.appendingPathComponent("llama-server.log") }
    static var agentLogFile: URL { appSupport.appendingPathComponent("agent.log") }

    /// llama-server from Homebrew (Apple Silicon default prefix), with a real
    /// PATH fallback for MacPorts/nix/custom prefixes.
    static var llamaServerBinary: String? {
        findExecutable("llama-server",
                       candidates: ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"])
    }

    /// PATH from the user's login shell, fetched once — a GUI app inherits a
    /// bare PATH that misses brew, nvm, and custom prefixes. AppState
    /// pre-warms this off the main thread at startup, because a heavy login
    /// profile can take seconds to run.
    static let loginShellPATH: String? = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "echo $PATH"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // A hung profile must not hang us: terminate() closes the pipe, so
        // the read below hits EOF and returns.
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
        // Drain BEFORE waiting — a chatty profile can fill the 64 KB pipe
        // buffer, and waitUntilExit-first is the classic Process deadlock.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()
        let text = String(data: data, encoding: .utf8) ?? ""
        // Profiles can print banners — the PATH is the last non-empty line.
        let path = text.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return path.contains("/") ? path : nil
    }()

    /// First executable hit: fixed candidate paths, then the login shell's PATH.
    static func findExecutable(_ name: String, candidates: [String]) -> String? {
        let fm = FileManager.default
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        for dir in (loginShellPATH ?? "").split(separator: ":") {
            let path = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static var whisperModelExists: Bool { FileManager.default.fileExists(atPath: whisperModel.path) }
    static var vadModelExists: Bool { FileManager.default.fileExists(atPath: vadModel.path) }
    static var cleanupModelExists: Bool { FileManager.default.fileExists(atPath: cleanupModel.path) }
}
