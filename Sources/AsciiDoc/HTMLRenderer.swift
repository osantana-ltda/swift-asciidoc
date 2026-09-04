// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// What a render needs beyond the document: the book-wide anchor table for
/// cross-references, where relative images live, and the footnotes collected
/// while the body renders. One context serves every document of a book so
/// references reach across chapters; a fresh one serves a single document.
public final class RenderContext {
    /// The document's header attributes, lowercased; set on each render.
    public var attributes: [String: String] = [:]
    /// Reference text per anchor id — a section's title, an inline anchor's
    /// reftext — across every document rendered with this context.
    public var anchors: [String: String]
    /// Where a relative image target resolves once `imagesdir` is applied:
    /// the chapter's directory, as a path or URL prefix. Nil leaves it as
    /// written.
    public var imageBase: String?

    var footnotes: [(id: String, html: String)] = []
    var namedFootnotes: [String: Int] = [:]
    var documentCount = 0

    public init(anchors: [String: String] = [:], imageBase: String? = nil) {
        self.anchors = anchors
        self.imageBase = imageBase
    }
}

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
        render(document, context: RenderContext())
    }

    public static func render(_ document: Document, context: RenderContext) -> String {
        // Attribute names are case-insensitive; references resolve against
        // the lowercased header entries.
        context.attributes = Dictionary(
            document.attributes.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        // The book's table wins; this document fills what it did not cover,
        // which is everything when rendering on its own.
        context.anchors.merge(anchors(in: document)) { book, _ in book }
        context.footnotes = []
        context.namedFootnotes = [:]
        context.documentCount += 1

        var html = ""
        if let header = document.header {
            if let title = header.title {
                html += "<h1>\(inlineHTML(of: title.text, context: context))</h1>\n"
            }
            // Authors are named one by one, an address becoming a link —
            // the reading of the author line, not the line itself (§6).
            let authors = header.authors
            if !authors.isEmpty {
                let names = authors.map { author -> String in
                    let name = escape(author.fullName)
                    guard let email = author.email, !email.isEmpty else {
                        return name
                    }
                    let label = name.isEmpty ? escape(email) : name
                    return "<a href=\"mailto:\(escapeAttribute(email))\">\(label)</a>"
                }
                html += "<p class=\"author\">\(names.joined(separator: ", "))</p>\n"
            } else if let author = header.authorLine {
                html += "<p class=\"author\">\(escape(author))</p>\n"
            }
        }
        html += render(document.blocks, context: context)

        // Footnotes close the document they belong to, numbered from one
        // per document the way books number them per chapter.
        if !context.footnotes.isEmpty {
            html += "<div class=\"footnotes\">\n<hr>\n"
            for note in context.footnotes {
                html += "<div class=\"footnote\" id=\"\(note.id)\">\(note.html)</div>\n"
            }
            html += "</div>\n"
        }
        return html
    }

    // MARK: - Anchors

    /// Every target a cross-reference can name in this document, with the
    /// text a reference without a label shows: sections by their title,
    /// titled blocks by theirs, inline anchors by their reftext.
    public static func anchors(in document: Document) -> [String: String] {
        var anchors: [String: String] = [:]

        func walk(_ blocks: [Block]) {
            for block in blocks {
                if isSection(block.kind) {
                    anchors[sectionID(of: block)] = block.title?.text ?? ""
                } else if let id = block.attributes.id {
                    anchors[id] = block.title?.text ?? ""
                }
                for inline in InlineParser.parse(block.lines) {
                    switch inline {
                    case .anchor(let id, let reftext, _):
                        anchors[id] = reftext
                    case .macro(let macro) where macro.name == "anchor":
                        anchors[macro.target] = macro.attributeList.positional.first ?? ""
                    default:
                        break
                    }
                }
                walk(block.blocks)
            }
        }
        walk(document.blocks)
        return anchors
    }

    /// A section's id: the one it was given, else derived from its title the
    /// way Asciidoctor derives it — `_building_the_toolchain` — so references
    /// written against the conventional id resolve here too.
    static func sectionID(of block: Block) -> String {
        if let id = block.attributes.id, !id.isEmpty {
            return id
        }
        var slug = ""
        var pendingSeparator = false
        for character in (block.title?.text ?? "").lowercased() {
            if character.isLetter || character.isNumber {
                if pendingSeparator, !slug.isEmpty {
                    slug += "_"
                }
                slug.append(character)
                pendingSeparator = false
            } else {
                pendingSeparator = true
            }
        }
        return "_" + slug
    }

    // MARK: - Blocks

    static func render(_ blocks: [Block], context: RenderContext) -> String {
        blocks.map { render($0, context: context) }.joined()
    }

    static func render(_ block: Block, context: RenderContext) -> String {
        // A block's `.Title` line is content, not decoration: it names a
        // listing, captions a figure, titles a table. It was reaching the
        // model and stopping there; now it reaches the page, inline
        // formatting and attribute references included.
        let titled = title(of: block, context: context)
        return titled + body(of: block, context: context)
    }

    /// The block's own title as markup, empty when it has none. Tables are
    /// the exception: HTML wants their caption *inside* the table, so
    /// `body(of:)` places it.
    static func title(of block: Block, context: RenderContext) -> String {
        guard let title = block.title, !isSection(block.kind), block.kind != .table else {
            return ""
        }
        return "<div class=\"title\">\(inlineHTML(of: title.text, context: context))</div>\n"
    }

    static func isSection(_ kind: Block.Kind) -> Bool {
        if case .section = kind {
            return true
        }
        return false
    }

    static func body(of block: Block, context: RenderContext) -> String {
        switch block.kind {
        case .section(let level):
            // AsciiDoc levels: `=` is the document title (h1), `==` is
            // section level 1 (h2), and so on.
            let heading = min(max(level + 1, 1), 6)
            let title = block.title.map { inlineHTML(of: $0.text, context: context) } ?? ""
            let id = escapeAttribute(sectionID(of: block))
            return "<h\(heading) id=\"\(id)\">\(title)</h\(heading)>\n"
                + render(block.blocks, context: context)

        case .preamble:
            return render(block.blocks, context: context)

        case .paragraph:
            return "<p>\(inlineHTML(of: block.lines, context: context))</p>\n"

        case .admonition(let variant):
            let label = variant.uppercased()
            return "<aside class=\"admonition \(variant.lowercased())\">"
                + "<strong>\(escape(label))</strong> "
                + "<span>\(inlineHTML(of: block.lines, context: context))</span></aside>\n"

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
                ? "<p>\(inlineHTML(of: block.lines, context: context))</p>\n"
                : render(block.blocks, context: context)
            return "<blockquote>\(body)</blockquote>\n"

        case .example:
            let body =
                block.blocks.isEmpty
                ? "<p>\(inlineHTML(of: block.lines, context: context))</p>\n"
                : render(block.blocks, context: context)
            return "<div class=\"example\">\(body)</div>\n"

        case .sidebar:
            let body =
                block.blocks.isEmpty
                ? "<p>\(inlineHTML(of: block.lines, context: context))</p>\n"
                : render(block.blocks, context: context)
            return "<aside class=\"sidebar\">\(body)</aside>\n"

        case .open:
            let body =
                block.blocks.isEmpty
                ? "<p>\(inlineHTML(of: block.lines, context: context))</p>\n"
                : render(block.blocks, context: context)
            return "<div class=\"open\">\(body)</div>\n"

        case .passthrough:
            // Raw by definition: passthrough exists to reach the output
            // unmediated.
            return block.text + "\n"

        case .table:
            // HTML puts a table's caption inside the table, first.
            let caption =
                block.title.map { title in
                    "<caption>\(inlineHTML(of: title.text, context: context))</caption>\n"
                } ?? ""
            return
                "<table>\n\(caption)\(render(block.blocks, context: context))</table>\n"

        case .tableRow(let header):
            let cells = block.blocks.map { child in
                tableCell(child, inHeaderRow: header, context: context)
            }.joined()
            return "<tr>\(cells)</tr>\n"

        case .tableCell:
            return tableCell(block, inHeaderRow: false, context: context)

        case .unorderedList:
            return "<ul>\n\(render(block.blocks, context: context))</ul>\n"

        case .orderedList:
            return "<ol>\n\(render(block.blocks, context: context))</ol>\n"

        case .descriptionList:
            return "<dl>\n\(render(block.blocks, context: context))</dl>\n"

        case .listItem:
            let body = inlineHTML(
                of: strippedItemLines(block.lines, term: block.title?.text),
                context: context
            )
            // Whatever hangs off the item — a nested list, a block attached
            // with `+` — renders inside it, not after it.
            let nested = render(block.blocks, context: context)

            guard let term = block.title else {
                return "<li>\(body)\(nested)</li>\n"
            }
            let label = inlineHTML(of: term.text, context: context)
            return "<dt>\(label)</dt>\n<dd>\(body)\(nested)</dd>\n"

        case .comment, .attributeEntry:
            // Not content: comments address the authors, attribute entries
            // address the toolchain.
            return ""

        case .include(let target):
            // Reaching the renderer means nobody resolved it. Showing the
            // reference and saying so is the §4.2 guarantee; quietly dropping
            // the line would lose content the author wrote.
            return "<div class=\"include unresolved\">Unresolved include: "
                + "<code>\(escape(target))</code></div>\n"

        case .unparsed:
            return "<pre class=\"unparsed\">\(escape(block.text))</pre>\n"
        }
    }

    /// One cell, wearing its specifier: spans become attributes, alignments
    /// become inline styles, `h` makes a header cell wherever it appears, and
    /// `a` means the content is AsciiDoc in its own right — a list or a
    /// listing inside a cell — so it is parsed rather than read as inlines.
    static func tableCell(
        _ cell: Block, inHeaderRow: Bool, context: RenderContext
    ) -> String {
        let style = cell.attributes.style
        let element = (style == "h" || inHeaderRow) ? "th" : "td"

        var markup = ""
        if let colspan = cell.attributes.named[TableParser.AttributeKey.colspan] {
            markup += " colspan=\"\(escapeAttribute(colspan))\""
        }
        if let rowspan = cell.attributes.named[TableParser.AttributeKey.rowspan] {
            markup += " rowspan=\"\(escapeAttribute(rowspan))\""
        }
        var css = ""
        if let align = cell.attributes.named[TableParser.AttributeKey.horizontalAlign] {
            css += "text-align:\(align);"
        }
        if let align = cell.attributes.named[TableParser.AttributeKey.verticalAlign] {
            css += "vertical-align:\(align);"
        }
        if !css.isEmpty {
            markup += " style=\"\(escapeAttribute(css))\""
        }

        let text = cell.lines.map(\.text).joined(separator: "\n")
        let content: String
        switch style {
        case "a":
            content = render(Parser.parse(text).blocks, context: context)
        case "l", "v":
            content = "<pre>\(escape(text))</pre>"
        case "m":
            content = "<code>\(escape(text))</code>"
        case "s":
            content = "<strong>\(inlineHTML(of: cell.lines, context: context))</strong>"
        default:
            content = inlineHTML(of: cell.lines, context: context)
        }

        return "<\(element)\(markup)>\(content)</\(element)>"
    }

    // MARK: - Inlines

    static func inlineHTML(of lines: [SourceLine], context: RenderContext) -> String {
        render(InlineParser.parse(lines), context: context)
    }

    static func inlineHTML(of text: String, context: RenderContext) -> String {
        let line = SourceLine(
            text: text,
            range: SourceRange(
                start: SourceLocation(offset: 0, line: 0, column: 0),
                end: SourceLocation(offset: text.utf16.count, line: 0, column: text.utf16.count)
            ),
            number: 0)
        return render(InlineParser.parse([line]), context: context)
    }

    static func render(_ inlines: [Inline], context: RenderContext) -> String {
        inlines.map { render($0, context: context) }.joined()
    }

    static func render(_ inline: Inline, context: RenderContext) -> String {
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
            if let value = context.attributes[name.lowercased()] {
                return escape(value)
            }
            return escape("{\(name)}")

        case .span(let span):
            let body = render(span.inlines, context: context)
            let markup = htmlAttributes(id: span.attributes.id, roles: span.attributes.roles)
            switch span.variant {
            case .strong: return "<strong\(markup)>\(body)</strong>"
            case .emphasis: return "<em\(markup)>\(body)</em>"
            case .code: return "<code\(markup)>\(body)</code>"
            case .superscriptText: return "<sup\(markup)>\(body)</sup>"
            case .subscriptText: return "<sub\(markup)>\(body)</sub>"
            case .mark:
                // `#text#` on its own is a highlight. Given an id or a role it
                // is AsciiDoc's plain styled span instead — the attributes are
                // the whole point, and there is nothing to highlight.
                guard markup.isEmpty else {
                    return "<span\(markup)>\(body)</span>"
                }
                return "<mark>\(body)</mark>"
            }

        case .macro(let macro):
            return render(macro, context: context)
        }
    }

    static func render(_ macro: Inline.Macro, context: RenderContext) -> String {
        switch macro.name {
        case "link", "mailto":
            let list = macro.attributeList
            let target = macro.name == "mailto" ? "mailto:\(macro.target)" : macro.target
            let label = list.positional.first ?? macro.target
            var attributes = " href=\"\(escapeAttribute(target))\""
            attributes += htmlAttributes(id: list.id, roles: list.roles)
            // `window=_blank` is AsciiDoc's way of asking for a new tab;
            // the `noopener` that should accompany it comes along.
            if let window = list.named["window"] {
                attributes += " target=\"\(escapeAttribute(window))\""
                attributes += " rel=\"noopener\""
            }
            return "<a\(attributes)>\(escape(label))</a>"

        case "image":
            let list = macro.attributeList
            // The block form `image::` reaches here with the second colon
            // still on the target.
            let written =
                macro.target.hasPrefix(":") ? String(macro.target.dropFirst()) : macro.target
            let alt = list.positional.first ?? written
            var attributes = " src=\"\(escapeAttribute(imagePath(written, context: context)))\""
            attributes += " alt=\"\(escapeAttribute(alt))\""
            if let width = list.named["width"] {
                attributes += " width=\"\(escapeAttribute(width))\""
            }
            if let height = list.named["height"] {
                attributes += " height=\"\(escapeAttribute(height))\""
            }
            if let title = list.named["title"] {
                attributes += " title=\"\(escapeAttribute(title))\""
            }
            attributes += htmlAttributes(id: list.id, roles: list.roles)
            return "<img\(attributes)>"

        case "kbd":
            return "<kbd>\(escape(macro.target.isEmpty ? macro.attributes : macro.target))</kbd>"

        case "xref":
            // A cross-reference is a link to an anchor. Without its own label
            // it shows what the anchor table says the target is called — a
            // section's title, an anchor's reftext — and only a target
            // nobody declared falls back to the bare id.
            let label: String
            if !macro.attributes.isEmpty {
                label = escape(macro.attributes)
            } else if let known = context.anchors[macro.target], !known.isEmpty {
                label = inlineHTML(of: known, context: context)
            } else {
                label = escape(macro.target)
            }
            return "<a href=\"#\(escapeAttribute(macro.target))\">\(label)</a>"

        case "anchor":
            return "<span id=\"\(escapeAttribute(macro.target))\"></span>"

        case "footnote":
            return footnote(macro, context: context)

        default:
            // Preserved visibly, never dropped.
            let attributes = macro.attributes.isEmpty ? "" : "[\(macro.attributes)]"
            return
                "<code class=\"macro\">\(escape("\(macro.name):\(macro.target)\(attributes)"))</code>"
        }
    }

    /// `footnote:[text]` numbers a note and collects it for the document's
    /// end; `footnote:id[text]` names it so a later `footnote:id[]` refers
    /// back to the same number.
    static func footnote(_ macro: Inline.Macro, context: RenderContext) -> String {
        let name = macro.target
        let document = context.documentCount

        if !name.isEmpty, let number = context.namedFootnotes[name] {
            return "<sup class=\"footnote\">"
                + "<a href=\"#_footnote_\(document)_\(number)\">\(number)</a></sup>"
        }

        let number = context.footnotes.count + 1
        if !name.isEmpty {
            context.namedFootnotes[name] = number
        }
        let noteID = "_footnote_\(document)_\(number)"
        let refID = "_footnoteref_\(document)_\(number)"
        context.footnotes.append(
            (
                id: noteID,
                html: "<a href=\"#\(refID)\">\(number)</a>. "
                    + inlineHTML(of: macro.attributes, context: context)
            ))
        return "<sup class=\"footnote\"><a id=\"\(refID)\" href=\"#\(noteID)\">\(number)</a></sup>"
    }

    /// Where an image target points: absolute and remote targets as written,
    /// relative ones under `imagesdir`, and what is still relative after that
    /// under the context's image base.
    static func imagePath(_ target: String, context: RenderContext) -> String {
        func isAbsolute(_ path: String) -> Bool {
            if path.hasPrefix("/") || path.hasPrefix("data:") {
                return true
            }
            // A scheme: `https://…`, `file://…`. Spelled out because
            // substring search on String needs Foundation or macOS 13.
            guard let colon = path.firstIndex(of: ":") else {
                return false
            }
            return path[path.index(after: colon)...].hasPrefix("//")
        }
        func join(_ base: String, _ path: String) -> String {
            base.hasSuffix("/") ? base + path : base + "/" + path
        }

        var path = target
        if !isAbsolute(path), let imagesdir = context.attributes["imagesdir"], !imagesdir.isEmpty {
            path = join(imagesdir, path)
        }
        if !isAbsolute(path), let base = context.imageBase {
            path = join(base, path)
        }
        return path
    }

    // MARK: - Helpers

    /// List item lines carry their marker; the first line sheds it. Returns
    /// plain item text — the caller renders the inlines exactly once.
    ///
    /// `term` is a description item's label: there the marker trails the term
    /// rather than opening the line, so what is shed is everything up to and
    /// including it.
    static func strippedItemLines(_ lines: [SourceLine], term: String? = nil) -> String {
        guard let first = lines.first else {
            return ""
        }
        var text = String(first.text.drop { $0 == " " || $0 == "\t" })

        if let term {
            // Measured off the term itself, so a term holding a colon of its
            // own is shed whole rather than cut at the wrong place.
            text = String(text.dropFirst(term.count))
            text = String(text.drop { $0 == " " || $0 == "\t" })
            text = String(text.drop { $0 == ":" || $0 == ";" })
            text = String(text.drop { $0 == " " })
            return ([text] + lines.dropFirst().map(\.text)).joined(separator: "\n")
        }

        let bullet = text.prefix { $0 == "*" || $0 == "." || $0 == "-" || $0.isNumber }
        if !bullet.isEmpty, text.dropFirst(bullet.count).first == " " {
            text = String(text.dropFirst(bullet.count + 1))
        }
        return ([text] + lines.dropFirst().map(\.text)).joined(separator: "\n")
    }

    /// The id and roles of an attribute list as HTML attributes — roles are
    /// AsciiDoc's classes, and they carry that meaning straight across.
    static func htmlAttributes(id: String?, roles: [String]) -> String {
        var rendered = ""
        if let id, !id.isEmpty {
            rendered += " id=\"\(escapeAttribute(id))\""
        }
        if !roles.isEmpty {
            rendered += " class=\"\(escapeAttribute(roles.joined(separator: " ")))\""
        }
        return rendered
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
