import Foundation
import CoreGraphics

/// One-shot screenshots for "look at my screen" commands, via the system
/// `screencapture` tool (same TCC identity as the app). Files land in a
/// private capture directory and are deleted as soon as the analysis is done.
enum ScreenCapture {
    static var captureDir: URL {
        let dir = Paths.appSupport.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Capture the main display to a JPEG. Returns nil on failure (most
    /// commonly: Screen Recording permission not granted).
    static func captureMainDisplay() -> URL? {
        let url = captureDir.appendingPathComponent("screen-\(UUID().uuidString.prefix(8)).jpg")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x: no shutter sound, -m: main display only, -t jpg: smaller file.
        p.arguments = ["-x", "-m", "-t", "jpg", url.path]
        do {
            try p.run()
        } catch {
            Log.error("ScreenCapture: \(error)")
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path) else {
            Log.error("ScreenCapture: screencapture exited \(p.terminationStatus)")
            try? FileManager.default.removeItem(at: url)   // partial file
            return nil
        }
        return url
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Called at launch: a crash or quit mid-analysis can strand a screenshot
    /// on disk — screenshots never outlive the analysis they were taken for.
    static func sweepLeftovers() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: captureDir,
                                                      includingPropertiesForKeys: nil) else { return }
        for f in files {
            try? fm.removeItem(at: f)
        }
        if !files.isEmpty {
            Log.info("ScreenCapture: swept \(files.count) leftover capture(s)")
        }
    }
}
