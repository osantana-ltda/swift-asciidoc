// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// Encodes a parsed document as the Abstract Semantic Graph the AsciiDoc
/// Technology Compatibility Kit compares against.
///
/// The ASG is how the specification checks that an implementation reads the
/// language the same way every other implementation does, which makes this the
/// only external, objective measure of whether this parser is correct.
///
/// Locations are pairs of `{line, col}`, and the end column is **inclusive** —
/// the column of the last character, not one past it. Internally ranges are
/// half-open, so every boundary is converted here rather than in the parser.
public enum AbstractSemanticGraph {
    public static func encode(_ document: Document, source: String) -> [String: Any] {
        var node: [String: Any] = [
            "name": "document",
            "type": "block",
        ]

        if let header = document.header {
            node["attributes"] = attributes(of: header)
            node["header"] = encode(header)
        }

        let blocks = document.blocks.compactMap(encodeBlock)
        if !blocks.isEmpty {
            node["blocks"] = blocks
        }

        if let range = span(of: document, blocks: document.blocks) {
            node["location"] = location(range)
        }

        return node
    }

    // MARK: - Header

    private static func attributes(of header: DocumentHeader) -> [String: Any] {
        var attributes: [String: Any] = [:]
        for entry in header.attributes where !entry.isUnset {
            attributes[entry.name] = entry.value
        }
        return attributes
    }

    private static func encode(_ header: DocumentHeader) -> [String: Any] {
        var node: [String: Any] = [:]

        if let title = header.title {
            node["title"] = [text(title.text, range: title.range)]
        }

        node["location"] = location(header.range)
        return node
    }

    // MARK: - Blocks

    private static func encodeBlock(_ block: Block) -> [String: Any]? {
        switch block.kind {
        case .section(let level):
            var node = named("section")
            if let title = block.title {
                node["title"] = [text(title.text, range: title.range)]
            }
            node["level"] = level
            node["location"] = location(block.range)
            node["blocks"] = block.blocks.compactMap(encodeBlock)
            return node

        case .preamble:
            var node = named("preamble")
            node["blocks"] = block.blocks.compactMap(encodeBlock)
            node["location"] = location(block.range)
            return node

        case .admonition(let variant):
            // The specification does not define this node, so the shape follows
            // the one the graph uses elsewhere for a variant: `list` carries
            // `variant`, and so does this.
            var node = named("admonition")
            node["variant"] = variant
            if block.blocks.isEmpty {
                node["inlines"] = inlineNodes(of: block.lines)
            } else {
                node["blocks"] = block.blocks.compactMap(encodeBlock)
            }
            node["location"] = location(block.range)
            return node

        case .paragraph:
            var node = named("paragraph")
            node["inlines"] = inlineNodes(of: block.lines)
            node["location"] = location(block.range)
            return node

        case .listing, .literal, .passthrough:
            var node = named(name(for: block.kind))
            node["form"] = "delimited"
            node["delimiter"] = delimiter(for: block.kind)
            node["inlines"] = [joinedText(of: block)].compactMap { $0 }
            node["location"] = location(block.range)
            return node

        case .quote, .example, .sidebar, .open:
            var node = named(name(for: block.kind))
            node["form"] = "delimited"
            node["delimiter"] = delimiter(for: block.kind)
            node["blocks"] = block.blocks.compactMap(encodeBlock)
            node["location"] = location(block.range)
            return node

        case .table:
            // The specification has not reached tables, so the shape mirrors
            // Asciidoctor's model the way the oracle reads it: head rows and
            // body rows, each a run of cells.
            var node = named("table")
            let head = block.blocks.filter { $0.kind == .tableRow(header: true) }
            let body = block.blocks.filter { $0.kind == .tableRow(header: false) }
            if !head.isEmpty {
                node["head"] = head.compactMap(encodeRow)
            }
            if !body.isEmpty {
                node["body"] = body.compactMap(encodeRow)
            }
            node["location"] = location(block.range)
            return node

        case .tableRow:
            return encodeRow(block)

        case .tableCell:
            return encodeCell(block)

        case .unorderedList, .orderedList:
            var node = named("list")
            node["variant"] = block.kind == .orderedList ? "ordered" : "unordered"
            let marker = listMarker(of: block)
            node["marker"] = marker
            node["items"] = block.blocks.compactMap { encodeListItem($0, marker: marker) }
            node["location"] = location(block.range)
            return node

        case .listItem:
            return encodeListItem(block, marker: "*")

        case .comment, .attributeEntry, .unparsed:
            // Not part of the graph: comments carry no semantics, attribute
            // entries are folded into the document's attributes, and anything
            // unparsed is deliberately not guessed at.
            return nil
        }
    }

    private static func encodeRow(_ block: Block) -> [String: Any]? {
        var node = named("row")
        node["cells"] = block.blocks.compactMap(encodeCell)
        node["location"] = location(block.range)
        return node
    }

    private static func encodeCell(_ block: Block) -> [String: Any]? {
        var node = named("cell")
        node["inlines"] = inlineNodes(of: block.lines)
        node["location"] = location(block.range)
        return node
    }

    private static func encodeListItem(_ block: Block, marker: String) -> [String: Any]? {
        var node = named("listItem")
        node["marker"] = marker

        var lines = block.lines
        if !lines.isEmpty {
            lines[0] = stripMarker(lines[0], length: marker.count + 1)
        }
        let principal = inlineNodes(of: lines)
        if !principal.isEmpty {
            node["principal"] = principal
        }

        node["location"] = location(block.range)
        return node
    }

    /// Drops the list marker and the space after it, keeping the rest located
    /// where it actually is. Marker characters are ASCII, so character counts
    /// and UTF-16 widths agree.
    private static func stripMarker(_ line: SourceLine, length: Int) -> SourceLine {
        let leading = line.text.prefix { $0 == " " || $0 == "\t" }.count
        let drop = leading + length
        let start = SourceLocation(
            offset: line.range.start.offset + drop,
            line: line.number,
            column: line.range.start.column + drop
        )

        return SourceLine(
            text: String(line.text.dropFirst(drop)),
            range: SourceRange(start: start, end: line.range.end),
            number: line.number
        )
    }

    // MARK: - Inlines

    private static func inlineNodes(of lines: [SourceLine]) -> [[String: Any]] {
        InlineParser.parse(lines).map(encodeInline)
    }

    /// Encodes one inline node. Public because the TCK adapter's inline mode
    /// emits these at the top level.
    public static func encodeInline(_ inline: Inline) -> [String: Any] {
        switch inline {
        case .text(let value, let range):
            return text(value, range: range)

        case .span(let span):
            return [
                "name": "span",
                "type": "inline",
                "variant": span.variant.rawValue,
                "form": span.form.rawValue,
                "inlines": span.inlines.map(encodeInline),
                "location": location(span.range),
            ]

        case .macro(let macro):
            // The specification has not reached macro encoding; the shape
            // follows the span pattern with `form: macro`.
            var node: [String: Any] = [
                "name": macro.name,
                "type": "inline",
                "form": "macro",
                "target": macro.target,
                "location": location(macro.range),
            ]
            if !macro.attributes.isEmpty {
                node["attrlist"] = macro.attributes
            }
            return node

        case .attributeReference(let name, let range):
            // Not reached by the specification either; the macro shape with
            // its own form keeps the reference addressable.
            return [
                "name": "ref",
                "type": "inline",
                "form": "attribute-reference",
                "target": name,
                "location": location(range),
            ]
        }
    }

    /// A verbatim block's content as a single text node — listings and
    /// literals take no inline markup, which is their point.
    private static func joinedText(of block: Block, droppingMarker markerLength: Int = 0)
        -> [String: Any]?
    {
        guard let first = block.lines.first, let last = block.lines.last else {
            return nil
        }

        var value = block.lines.map(\.text).joined(separator: "\n")
        var startColumn = first.range.start.column

        if markerLength > 0 {
            let leading = first.text.prefix { $0 == " " || $0 == "\t" }.count
            let drop = leading + markerLength
            value = String(value.dropFirst(drop))
            startColumn += drop
        }

        let start = SourceLocation(
            offset: first.range.start.offset + startColumn - first.range.start.column,
            line: first.number,
            column: startColumn
        )

        return text(
            value,
            range: SourceRange(start: start, end: last.range.end)
        )
    }

    private static func text(_ value: String, range: SourceRange) -> [String: Any] {
        [
            "name": "text",
            "type": "string",
            "value": value,
            "location": location(range),
        ]
    }

    // MARK: - Helpers

    private static func named(_ name: String) -> [String: Any] {
        ["name": name, "type": "block"]
    }

    private static func name(for kind: Block.Kind) -> String {
        switch kind {
        case .listing: "listing"
        case .literal: "literal"
        case .passthrough: "pass"
        case .quote: "quote"
        case .example: "example"
        case .sidebar: "sidebar"
        case .open: "open"
        default: "block"
        }
    }

    private static func delimiter(for kind: Block.Kind) -> String {
        switch kind {
        case .listing: "----"
        case .literal: "...."
        case .passthrough: "++++"
        case .quote: "____"
        case .example: "===="
        case .sidebar: "****"
        case .open: "--"
        default: ""
        }
    }

    private static func listMarker(of block: Block) -> String {
        guard let first = block.blocks.first?.lines.first else {
            return block.kind == .orderedList ? "." : "*"
        }
        return String(first.trimmed.prefix { !$0.isWhitespace })
    }

    private static func span(of document: Document, blocks: [Block]) -> SourceRange? {
        let ranges = [document.header?.range].compactMap { $0 } + blocks.map(\.range)
        guard let first = ranges.first else {
            return nil
        }
        return ranges.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Half-open internally, inclusive in the graph.
    private static func location(_ range: SourceRange) -> [[String: Int]] {
        [
            ["line": range.start.line, "col": range.start.column],
            ["line": range.end.line, "col": Swift.max(1, range.end.column - 1)],
        ]
    }
}
