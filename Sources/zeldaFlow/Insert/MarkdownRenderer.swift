import AppKit

/// Renders LLM-generated Markdown into rich text so pasted documents carry
/// real headings, bold and bullets (Notes, Pages, Word, Docs) instead of
/// literal "#" and "**" markers. Colors are emitted as classic black/gray —
/// rich-text hosts adapt those; emitting dynamic colors would bake in
/// whatever appearance zeldaFlow happened to run under.
enum MarkdownRenderer {
    static func looksLikeMarkdown(_ text: String) -> Bool {
        guard text.contains("\n") else { return false }
        if text.contains("```") || text.contains("**") { return true }
        var listLines = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.drop(while: { $0 == " " })
            if line.hasPrefix("#"),
               line.prefix(while: { $0 == "#" }).count <= 6,
               line.dropFirst(line.prefix(while: { $0 == "#" }).count).hasPrefix(" ") {
                return true
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                listLines += 1
            } else if let dot = line.firstIndex(of: "."),
                      !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber),
                      line[line.index(after: dot)...].hasPrefix(" ") {
                listLines += 1
            }
        }
        return listLines >= 2
    }

    // MARK: - Rendering

    private static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static func headingFont(_ level: Int) -> NSFont {
        let sizes: [CGFloat] = [21, 17.5, 15.5, 14, 13.5, 13]
        return .boldSystemFont(ofSize: sizes[max(0, min(level - 1, 5))])
    }

    private static func style(indent: CGFloat = 0, hanging: CGFloat = 0,
                              before: CGFloat = 2, after: CGFloat = 2) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = indent
        p.headIndent = indent + hanging
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        return p
    }

    /// Theme-aware variant for in-app display (the Meetings notes tab): the
    /// classic renderer hard-codes black/gray because pasted rich text must
    /// not bake in an appearance, but a themed window needs dynamic ink. A
    /// post-pass color map keeps the paste path byte-identical.
    static func render(_ markdown: String, ink: NSColor, muted: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: render(markdown))
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            let color = value as? NSColor
            if color == nil || color == .black {
                out.addAttribute(.foregroundColor, value: ink, range: range)
            } else {
                out.addAttribute(.foregroundColor, value: muted, range: range)
            }
        }
        return out
    }

    static func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var inCodeBlock = false

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock {
                out.append(NSAttributedString(string: rawLine + "\n", attributes: [
                    .font: monoFont, .foregroundColor: NSColor.black,
                    .paragraphStyle: style(indent: 12, before: 0, after: 0),
                ]))
                continue
            }
            if trimmed.isEmpty {
                out.append(NSAttributedString(string: "\n"))
                continue
            }

            // Heading
            let hashes = trimmed.prefix(while: { $0 == "#" })
            if !hashes.isEmpty, hashes.count <= 6, trimmed.dropFirst(hashes.count).hasPrefix(" ") {
                let content = String(trimmed.dropFirst(hashes.count + 1))
                let font = headingFont(hashes.count)
                out.append(inline(content, base: font, attributes: [
                    .paragraphStyle: style(before: hashes.count <= 2 ? 12 : 8, after: 4),
                ]))
                out.append(NSAttributedString(string: "\n"))
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                out.append(NSAttributedString(string: "──────────────────\n", attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.gray,
                    .paragraphStyle: style(before: 6, after: 6),
                ]))
                continue
            }

            let indentLevel = min(rawLine.prefix(while: { $0 == " " }).count / 2, 3)
            let baseIndent = CGFloat(indentLevel) * 16

            // Bulleted list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let content = String(trimmed.dropFirst(2))
                let para = style(indent: baseIndent + 8, hanging: 14, before: 1, after: 1)
                out.append(NSAttributedString(string: "•  ", attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.black, .paragraphStyle: para,
                ]))
                out.append(inline(content, base: bodyFont, attributes: [.paragraphStyle: para]))
                out.append(NSAttributedString(string: "\n"))
                continue
            }

            // Numbered list
            if let dot = trimmed.firstIndex(of: "."),
               !trimmed[..<dot].isEmpty, trimmed[..<dot].allSatisfy(\.isNumber),
               trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                let number = String(trimmed[..<dot])
                let content = trimmed[trimmed.index(dot, offsetBy: 2)...]
                    .trimmingCharacters(in: .whitespaces)
                let para = style(indent: baseIndent + 8, hanging: 18, before: 1, after: 1)
                out.append(NSAttributedString(string: "\(number).  ", attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.black, .paragraphStyle: para,
                ]))
                out.append(inline(content, base: bodyFont, attributes: [.paragraphStyle: para]))
                out.append(NSAttributedString(string: "\n"))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                let content = String(trimmed.dropFirst(2))
                let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
                out.append(inline(content, base: italic, color: .darkGray, attributes: [
                    .paragraphStyle: style(indent: 14, before: 2, after: 2),
                ]))
                out.append(NSAttributedString(string: "\n"))
                continue
            }

            // Table rows / plain paragraph
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                // Keep tables monospaced so the columns still line up.
                out.append(NSAttributedString(string: trimmed + "\n", attributes: [
                    .font: monoFont, .foregroundColor: NSColor.black,
                    .paragraphStyle: style(before: 0, after: 0),
                ]))
                continue
            }

            out.append(inline(trimmed, base: bodyFont, attributes: [
                .paragraphStyle: style(before: 2, after: 4),
            ]))
            out.append(NSAttributedString(string: "\n"))
        }
        return out
    }

    // MARK: - Inline spans (bold, italic, code, links)

    private static let inlinePattern = try! NSRegularExpression(
        pattern: "(`[^`]+`)|(\\*\\*[^*]+\\*\\*)|(\\*[^*\\s][^*]*\\*)|(_[^_\\s][^_]*_)|(\\[([^\\]]+)\\]\\(([^)]+)\\))")

    private static func inline(_ text: String, base: NSFont, color: NSColor = .black,
                               attributes extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var plain: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: color]
        plain.merge(extra) { a, _ in a }
        let out = NSMutableAttributedString()
        let ns = text as NSString
        var cursor = 0

        for m in inlinePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out.append(NSAttributedString(
                    string: ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)),
                    attributes: plain))
            }
            let token = ns.substring(with: m.range)
            var attrs = plain
            var content = token
            if token.hasPrefix("`") {
                content = String(token.dropFirst().dropLast())
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular)
            } else if token.hasPrefix("**") {
                content = String(token.dropFirst(2).dropLast(2))
                attrs[.font] = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            } else if token.hasPrefix("*") || token.hasPrefix("_") {
                content = String(token.dropFirst().dropLast())
                attrs[.font] = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            } else if m.range(at: 6).location != NSNotFound {
                content = ns.substring(with: m.range(at: 6))
                if m.range(at: 7).location != NSNotFound,
                   let url = URL(string: ns.substring(with: m.range(at: 7))) {
                    attrs[.link] = url
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            out.append(NSAttributedString(string: content, attributes: attrs))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out.append(NSAttributedString(string: ns.substring(from: cursor), attributes: plain))
        }
        return out
    }
}
