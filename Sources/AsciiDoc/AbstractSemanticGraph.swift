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
                node["inlines"] = [joinedText(of: block)].compactMap { $0 }
            } else {
                node["blocks"] = block.blocks.compactMap(encodeBlock)
            }
            node["location"] = location(block.range)
            return node

        case .paragraph:
            var node = named("paragraph")
            node["inlines"] = [joinedText(of: block)].compactMap { $0 }
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
        node["inlines"] = [joinedText(of: block)].compactMap { $0 }
        node["location"] = location(block.range)
        return node
    }

    private static func encodeListItem(_ block: Block, marker: String) -> [String: Any]? {
        var node = named("listItem")
        node["marker"] = marker

        if let principal = joinedText(of: block, droppingMarker: marker.count + 1) {
            node["principal"] = [principal]
        }

        node["location"] = location(block.range)
        return node
    }

    // MARK: - Inlines

    /// A block's content as a single text node. Inline syntax is not parsed
    /// yet, so a paragraph is one unbroken run of text — which is right for
    /// content with no markup in it and wrong for anything else.
    private static func joinedText(of block: Block, droppingMarker markerLength: Int = 0) -> [String: Any]? {
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
