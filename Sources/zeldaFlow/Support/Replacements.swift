import Foundation

/// The one replacement engine: case-insensitive, whole-word, applied after
/// transcription and cleanup. Pure so --evaldictionary pins its behavior
/// ("Coupon" maps, "coupons" survives) instead of trusting a private method.
enum Replacements {
    static func apply(_ map: [String: String], to text: String) -> String {
        var out = text
        for (from, to) in map where !from.isEmpty {
            let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b"
            if let re = try? NSRegularExpression(pattern: pattern) {
                out = re.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out),
                    withTemplate: NSRegularExpression.escapedTemplate(for: to))
            }
        }
        return out
    }
}
