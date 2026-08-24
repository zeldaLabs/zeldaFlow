import Foundation

/// Runs AppleScript via /usr/bin/osascript on a background queue (keeps the
/// UI alive; TCC Automation prompts attribute to zeldaFlow as the
/// responsible process). Scripts are passed as argv — no shell involved.
enum AppleScriptRunner {
    struct ScriptResult {
        let ok: Bool
        let output: String
    }

    static func run(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", source]
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: ScriptResult(ok: false, output: "\(error)"))
                    return
                }
                p.waitUntilExit()
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                let ok = p.terminationStatus == 0
                let text = (ok ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                if !ok { Log.error("osascript failed: \(text.prefix(300))") }
                cont.resume(returning: ScriptResult(ok: ok, output: text))
            }
        }
    }

    /// Quote a value for embedding in an AppleScript string literal.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
               .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Build AppleScript lines that set variable `varName` to the given
    /// "YYYY-MM-DD HH:MM" moment. Locale-proof: no `date "…"` string parsing.
    static func dateAssignment(varName: String, from string: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var date = formatter.date(from: string)
        if date == nil {
            formatter.dateFormat = "yyyy-MM-dd"
            date = formatter.date(from: string)
        }
        guard let date else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        // Day is forced to 1 before setting the month: starting from
        // "current date" on e.g. Jan 31, `set month to 4` would overflow
        // (April 31 → May 1) and corrupt the whole date.
        return """
        set \(varName) to current date
        set day of \(varName) to 1
        set year of \(varName) to \(c.year!)
        set month of \(varName) to \(c.month!)
        set day of \(varName) to \(c.day!)
        set hours of \(varName) to \(c.hour ?? 9)
        set minutes of \(varName) to \(c.minute ?? 0)
        set seconds of \(varName) to 0
        """
    }
}
