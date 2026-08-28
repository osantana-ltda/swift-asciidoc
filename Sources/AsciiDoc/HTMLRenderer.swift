// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// Renders a parsed document as semantic HTML — a body fragment, no chrome:
/// the caller owns the page, the stylesheet and the assembly. Kept
/// deliberately simple: structural elements, inline formatting and links.
///
/// Two rules govern the corners:
/// - Passthrough blocks emit their content raw — that is their meaning.
/// - Unparsed and unknown content is escaped and preserved visibly rather
///   than dropped; the §4.2 guarantee is "never silently lost".
public enum HTMLRenderer {
    public static func render(_ document: Document) -> String {
        // Attribute names are case-insensitive; references resolve against
        // the lowercased header entries.
        let attributes = Dictionary(
            document.attributes.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        var html = ""
        if let header = document.header {
            if let title = header.title {
                html += "<h1>\(escape(title.text))</h1>\n"
            }
            if let author = header.authorLine {
                html += "<p class=\"author\">\(escape(author))</p>\n"
            }
        }
        html += render(document.blocks, attributes: attributes)
        return html
    }

    static func render(_ blocks: [Block], attributes: [String: String] = [:]) -> String {
        blocks.map { render($0, attributes: attributes) }.joined()
    }

    static func render(_ block: Block, attributes: [String: String] = [:]) -> String {
        switch block.kind {
        case .section(let level):
            // AsciiDoc levels: `=` is the document title (h1), `==` is
            // section level 1 (h2), and so on.
            let heading = min(max(level + 1, 1), 6)
            let title = block.title.map { inlineHTML(of: $0.text, attributes: attributes) } ?? ""
            return "<h\(heading)>\(title)</h\(heading)>\n"
                + render(block.blocks, attributes: attributes)

        case .preamble:
            return render(block.blocks, attributes: attributes)

        case .paragraph:
            return "<p>\(inlineHTML(of: block.lines, attributes: attributes))</p>\n"

        case .admonition(let variant):
            let label = variant.uppercased()
            return "<aside class=\"admonition \(variant.lowercased())\">"
                + "<strong>\(escape(label))</strong> "
                + "<span>\(inlineHTML(of: block.lines, attributes: attributes))</span></aside>\n"

        case .listing:
            let language =
                block.attributes.positional.count > 1
                ? block.attributes.positional[1] : nil
            let cls = language.map { " class=\"language-\(escape($0))\"" } ?? ""
            return "<pre><code\(cls)>\(escape(block.text))</code></pre>\n"

        case .literal:
            return "<pre class=\"literal\">\(escape(block.text))</pre>\n"

        case .quote:
            let body =
                block.blocks.isEmpty
                ? "<p>\(inlineHTML(of: block.lines, attributes: attributes))</p>\n"
                : render(block.blocks, attributes: attributes)
            return "<blockquote>\(body)</blockquote>\n"

        case .example:
            let body =
                block.blocks.isEmpty
                ? "<p>\(inlineHTML(of: block.lines, attributes: attributes))</p>\n"
                : render(block.blocks, attributes: attributes)
            return "<div class=\"example\">\(body)</div>\n"

        case .sidebar:
            let body =
                block.blocks.isEmpty
                ? "<p>\(inlineHTML(of: block.lines, attributes: attributes))</p>\n"
                : render(block.blocks, attributes: attributes)
            return "<aside class=\"sidebar\">\(body)</aside>\n"

        case .open:
            let body =
                block.blocks.isEmpty
                ? "<p>\(inlineHTML(of: block.lines, attributes: attributes))</p>\n"
                : render(block.blocks, attributes: attributes)
            return "<div class=\"open\">\(body)</div>\n"

        case .passthrough:
            // Raw by definition: passthrough exists to reach the output
            // unmediated.
            return block.text + "\n"

        case .table:
            return "<table>\n\(render(block.blocks, attributes: attributes))</table>\n"

        case .tableRow(let header):
            let cell = header ? "th" : "td"
            let cells = block.blocks.map { child in
                "<\(cell)>\(inlineHTML(of: child.lines, attributes: attributes))</\(cell)>"
            }.joined()
            return "<tr>\(cells)</tr>\n"

        case .tableCell:
            return "<td>\(inlineHTML(of: block.lines, attributes: attributes))</td>\n"

        case .unorderedList:
            return "<ul>\n\(render(block.blocks, attributes: attributes))</ul>\n"

        case .orderedList:
            return "<ol>\n\(render(block.blocks, attributes: attributes))</ol>\n"

        case .listItem:
            return
                "<li>\(inlineHTML(of: strippedItemLines(block.lines), attributes: attributes))</li>\n"

        case .comment, .attributeEntry:
            // Not content: comments address the authors, attribute entries
            // address the toolchain.
            return ""

        case .unparsed:
            return "<pre class=\"unparsed\">\(escape(block.text))</pre>\n"
        }
    }

    // MARK: - Inlines

    static func inlineHTML(of lines: [SourceLine], attributes: [String: String] = [:]) -> String {
        render(InlineParser.parse(lines), attributes: attributes)
    }

    static func inlineHTML(of text: String, attributes: [String: String] = [:]) -> String {
        let line = SourceLine(
            text: text,
            range: SourceRange(
                start: SourceLocation(offset: 0, line: 0, column: 0),
                end: SourceLocation(offset: text.utf16.count, line: 0, column: text.utf16.count)
            ),
            number: 0)
        return render(InlineParser.parse([line]), attributes: attributes)
    }

    static func render(_ inlines: [Inline], attributes: [String: String] = [:]) -> String {
        inlines.map { render($0, attributes: attributes) }.joined()
    }

    static func render(_ inline: Inline, attributes: [String: String] = [:]) -> String {
        switch inline {
        case .text(let value, _):
            return escape(value)

        case .anchor(let id, let reftext, _):
            // The anchor is the target; its reference text, when given, is
            // what a cross-reference without its own label would show, so it
            // stays in the document as the anchor's content.
            return "<span id=\"\(escapeAttribute(id))\">\(escape(reftext))</span>"

        case .attributeReference(let name, _):
            // Substitution is the renderer's job: a defined attribute
            // resolves to its value, an unknown reference stays visibly
            // literal — Asciidoctor's skip behavior, and the §4.2 instinct.
            if let value = attributes[name.lowercased()] {
                return escape(value)
            }
            return escape("{\(name)}")

        case .span(let span):
            let body = render(span.inlines, attributes: attributes)
            switch span.variant {
            case .strong: return "<strong>\(body)</strong>"
            case .emphasis: return "<em>\(body)</em>"
            case .code: return "<code>\(body)</code>"
            case .mark: return "<mark>\(body)</mark>"
            case .superscriptText: return "<sup>\(body)</sup>"
            case .subscriptText: return "<sub>\(body)</sub>"
            }

        case .macro(let macro):
            switch macro.name {
            case "link", "mailto":
                let target = macro.name == "mailto" ? "mailto:\(macro.target)" : macro.target
                let label = macro.attributes.isEmpty ? macro.target : macro.attributes
                return "<a href=\"\(escapeAttribute(target))\">\(escape(label))</a>"
            case "image":
                let alt = macro.attributes.isEmpty ? macro.target : macro.attributes
                return
                    "<img src=\"\(escapeAttribute(macro.target))\" alt=\"\(escapeAttribute(alt))\">"
            case "kbd":
                return
                    "<kbd>\(escape(macro.target.isEmpty ? macro.attributes : macro.target))</kbd>"
            case "xref":
                // Now that anchors exist, a cross-reference is a real link
                // to one; without its own label it shows the target id,
                // which is what a document with no reftext can honestly say.
                let label = macro.attributes.isEmpty ? macro.target : macro.attributes
                return "<a href=\"#\(escapeAttribute(macro.target))\">\(escape(label))</a>"
            case "anchor":
                return "<span id=\"\(escapeAttribute(macro.target))\"></span>"
            default:
                // Preserved visibly, never dropped.
                let attributes = macro.attributes.isEmpty ? "" : "[\(macro.attributes)]"
                return
                    "<code class=\"macro\">\(escape("\(macro.name):\(macro.target)\(attributes)"))</code>"
            }
        }
    }

    // MARK: - Helpers

    /// List item lines carry their marker; the first line sheds it. Returns
    /// plain item text — the caller renders the inlines exactly once.
    static func strippedItemLines(_ lines: [SourceLine]) -> String {
        guard let first = lines.first else {
            return ""
        }
        var text = first.text
        let trimmed = text.drop(while: { $0 == " " })
        let marker = trimmed.prefix { $0 == "*" || $0 == "." || $0 == "-" }
        if !marker.isEmpty, trimmed.dropFirst(marker.count).first == " " {
            text = String(trimmed.dropFirst(marker.count + 1))
        }
        return ([text] + lines.dropFirst().map(\.text)).joined(separator: "\n")
    }

    public static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    static func escapeAttribute(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
