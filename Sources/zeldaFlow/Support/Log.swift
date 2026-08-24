import Foundation
import os

/// Lightweight logger: os_log for Console.app plus a rotating file in
/// ~/Library/Application Support/zeldaFlow/zeldaflow.log for post-hoc debugging.
enum Log {
    private static let logger = Logger(subsystem: "com.zeldalabs.zeldaflow", category: "app")
    private static let queue = DispatchQueue(label: "zeldaflow.log", qos: .utility)
    private static let maxFileBytes: UInt64 = 5 * 1024 * 1024

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    // Messages can contain the user's spoken words — in the shared unified
    // log they stay private (Console shows <private>); the app's own file
    // log below keeps the full text for local debugging.
    static func info(_ message: String) {
        logger.info("\(message, privacy: .private)")
        appendToFile("INFO  \(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .private)")
        appendToFile("ERROR \(message)")
    }

    private static func appendToFile(_ line: String) {
        // Timestamp taken here, formatted on the queue: DateFormatter is not
        // thread-safe, and the hotkey tap now logs from its own thread.
        let now = Date()
        queue.async {
            let stamped = "\(dateFormatter.string(from: now)) \(line)\n"
            let url = Paths.logFile
            do {
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                var handle = try FileHandle(forWritingTo: url)
                var size = try handle.seekToEnd()
                if size > maxFileBytes {
                    // Rotate, don't truncate — the tail of a long session is
                    // exactly what post-hoc debugging needs.
                    try? handle.close()
                    let old = url.deletingPathExtension().appendingPathExtension("log.old")
                    try? FileManager.default.removeItem(at: old)
                    try? FileManager.default.moveItem(at: url, to: old)
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    handle = try FileHandle(forWritingTo: url)
                    size = 0
                }
                defer { try? handle.close() }
                try handle.write(contentsOf: Data(stamped.utf8))
            } catch {
                // Logging must never crash the app.
            }
        }
    }
}
