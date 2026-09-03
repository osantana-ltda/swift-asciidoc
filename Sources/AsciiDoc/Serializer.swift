// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// Writes a document back out as AsciiDoc.
///
/// Two guarantees, in order of precedence:
///
/// 1. **Round-trip identity.** A parsed document serializes back to its source
///    byte for byte. The parser retains every line it consumed — metadata
///    lines, delimiters, header lines, raw table and quote content — and the
///    serializer emits that verbatim backing at its original line numbers,
///    reconstructing blank lines from the gaps.
/// 2. **Determinism.** A document built programmatically — no source positions —
///    serializes to a canonical form: single blank lines between blocks,
///    standard delimiters, attribute lists in a fixed order with named
///    attributes sorted. The same tree always yields the same bytes, which is
///    what makes diffs quiet (§6.1 of the Bookled specification, where this
///    package originates).
///
/// Two documented normalizations, both invisible to AsciiDoc semantics:
/// whitespace-only blank lines between blocks come back as empty lines, and
/// CRLF line endings come back as LF.
public enum Serializer {
    public static func serialize(_ document: Document) -> String {
        var emitter = Emitter()

        if let header = document.header {
            emitHeader(header, into: &emitter)
        }

        for block in document.blocks {
            emit(block, into: &emitter)
        }

        return emitter.finish(
            lineCount: document.sourceLineCount,
            endsInNewline: document.endsInNewline
        )
    }

    // MARK: - Emitter

    /// Accumulates output rows. Rows with source line numbers land at those
    /// numbers, with blank rows filling the gaps; synthetic rows follow the
    /// previous row directly.
    private struct Emitter {
        private(set) var rows: [String] = []
        /// The source line number of the last numbered row; starts at zero so
        /// leading blank lines pad correctly.
        private var lastNumber: Int? = 0
        /// Set after a canonical opening delimiter, so the block's first child
        /// sits tight against it instead of being separated.
        var suppressNextSeparator = false

        mutating func emit(_ line: SourceLine) {
            if line.number > 0 {
                if let last = lastNumber, line.number > last + 1 {
                    rows += Array(repeating: "", count: line.number - last - 1)
                }
                lastNumber = line.number
                rows.append(line.text)
            } else {
                emit(text: line.text)
            }
            suppressNextSeparator = false
        }

        mutating func emit(text: String) {
            rows.append(text)
            lastNumber = lastNumber.map { $0 + 1 }
            suppressNextSeparator = false
        }

        /// One blank row before the next content, for canonical output. Does
        /// nothing at the start of the document or after an opening delimiter.
        mutating func separate() {
            if suppressNextSeparator {
                suppressNextSeparator = false
                return
            }
            guard let last = rows.last, !last.isEmpty else {
                return
            }
            rows.append("")
            lastNumber = lastNumber.map { $0 + 1 }
        }

        mutating func finish(lineCount: Int, endsInNewline: Bool) -> String {
            if let last = lastNumber, lineCount > last {
                rows += Array(repeating: "", count: lineCount - last)
            }
            guard !rows.isEmpty else {
                return ""
            }
            return rows.joined(separator: "\n") + (endsInNewline ? "\n" : "")
        }
    }

    // MARK: - Header

    private static func emitHeader(_ header: DocumentHeader, into emitter: inout Emitter) {
        guard header.lines.isEmpty else {
            for line in header.lines {
                emitter.emit(line)
            }
            return
        }

        if let title = header.title {
            emitter.emit(text: "= \(title.text)")
        }
        if let author = header.authorLine {
            emitter.emit(text: author)
        }
        for entry in header.attributes {
            let marker = entry.isUnset ? "!" : ""
            let value = entry.value.isEmpty ? "" : " \(entry.value)"
            emitter.emit(text: ":\(entry.name)\(marker):\(value)")
        }
    }

    // MARK: - Blocks

    private static func emit(_ block: Block, into emitter: inout Emitter) {
        if block.kind != .listItem, startsSynthetic(block) {
            emitter.separate()
        }

        emitPrelude(of: block, into: &emitter)

        switch block.kind {
        case .preamble:
            emitChildren(of: block, into: &emitter)

        case .section(let level):
            if let opening = block.opening {
                emitter.emit(opening)
            } else {
                let marker = String(repeating: "=", count: level + 1)
                emitter.emit(text: "\(marker) \(block.title?.text ?? "")")
            }
            emitChildren(of: block, into: &emitter)

        case .paragraph, .attributeEntry, .unparsed, .tableCell:
            emitLines(of: block, into: &emitter)

        case .include(let target):
            if block.lines.isEmpty {
                emitter.emit(text: "include::\(target)[]")
            } else {
                emitLines(of: block, into: &emitter)
            }

        case .listItem:
            // The item's own text, then whatever hangs off it: a nested list,
            // or a block attached with `+`, which carries that marker on its
            // prelude.
            emitLines(of: block, into: &emitter)
            emitChildren(of: block, into: &emitter)

        case .admonition(let variant):
            emitAdmonition(block, variant: variant, into: &emitter)

        case .listing:
            emitVerbatim(block, delimiter: "----", into: &emitter)
        case .literal:
            emitVerbatim(block, delimiter: "....", into: &emitter)
        case .passthrough:
            emitVerbatim(block, delimiter: "++++", into: &emitter)

        case .comment:
            // Line comments carry their own `//` and have no frame.
            if block.opening != nil {
                emitFramed(block, delimiter: "////", into: &emitter) { emitter in
                    emitLines(of: block, into: &emitter)
                }
            } else {
                emitLines(of: block, into: &emitter)
            }

        case .quote, .example, .sidebar, .open:
            emitCompound(block, into: &emitter)

        case .table:
            emitFramed(block, delimiter: "|===", into: &emitter) { emitter in
                if !block.lines.isEmpty {
                    emitLines(of: block, into: &emitter)
                } else {
                    for row in block.blocks {
                        let cells = row.blocks.map(\.text).joined(separator: " | ")
                        emitter.emit(text: "| \(cells)")
                    }
                }
            }

        case .unorderedList, .orderedList, .descriptionList:
            emitChildren(of: block, into: &emitter)

        case .tableRow:
            let cells = block.blocks.map(\.text).joined(separator: " | ")
            emitter.emit(text: "| \(cells)")
        }
    }

    private static func emitChildren(of block: Block, into emitter: inout Emitter) {
        for child in block.blocks {
            emit(child, into: &emitter)
        }
    }

    private static func emitLines(of block: Block, into emitter: inout Emitter) {
        for line in block.lines {
            emitter.emit(line)
        }
    }

    /// A verbatim block: framed by its delimiters when it had (or needs) them,
    /// bare when a style attribute made it verbatim without delimiters.
    private static func emitVerbatim(
        _ block: Block,
        delimiter: String,
        into emitter: inout Emitter
    ) {
        if block.opening == nil, block.attributes.style != nil {
            emitLines(of: block, into: &emitter)
            return
        }

        emitFramed(block, delimiter: delimiter, into: &emitter) { emitter in
            emitLines(of: block, into: &emitter)
        }
    }

    /// A compound block. Four shapes, decided by what the parser retained:
    /// delimited (frame + children), Markdown quote (raw lines), style-derived
    /// (children only), or canonical (synthetic frame + children).
    private static func emitCompound(_ block: Block, into emitter: inout Emitter) {
        if block.opening == nil, !block.lines.isEmpty {
            emitLines(of: block, into: &emitter)
            return
        }

        if block.opening == nil, block.attributes.style != nil {
            emitChildren(of: block, into: &emitter)
            return
        }

        let delimiter: String =
            switch block.kind {
            case .quote: "____"
            case .example: "===="
            case .sidebar: "****"
            default: "--"
            }

        emitFramed(block, delimiter: delimiter, into: &emitter) { emitter in
            emitChildren(of: block, into: &emitter)
        }
    }

    private static func emitAdmonition(
        _ block: Block,
        variant: String,
        into emitter: inout Emitter
    ) {
        // A delimited block that a `[NOTE]` style turned into an admonition.
        if !block.blocks.isEmpty {
            emitFramed(block, delimiter: "====", into: &emitter) { emitter in
                emitChildren(of: block, into: &emitter)
            }
            return
        }

        // A prefix admonition: the original labelled line was retained whole,
        // and the first content line is its label-stripped remainder.
        if let opening = block.opening, opening.number == block.lines.first?.number {
            emitter.emit(opening)
            for line in block.lines.dropFirst() {
                emitter.emit(line)
            }
            return
        }

        // `[NOTE]` over a paragraph: no label in the source.
        if block.attributes.style != nil {
            emitLines(of: block, into: &emitter)
            return
        }

        // Canonical: reconstruct the label.
        if let first = block.lines.first {
            emitter.emit(text: "\(variant.uppercased()): \(first.text)")
            for line in block.lines.dropFirst() {
                emitter.emit(line)
            }
        }
    }

    /// Frame emission: verbatim delimiters when the parser kept them, canonical
    /// ones otherwise. A parsed block with an opening but no closing was
    /// unterminated in the source and stays unterminated.
    private static func emitFramed(
        _ block: Block,
        delimiter: String,
        into emitter: inout Emitter,
        content: (inout Emitter) -> Void
    ) {
        if let opening = block.opening {
            emitter.emit(opening)
        } else {
            emitter.emit(text: delimiter)
            emitter.suppressNextSeparator = true
        }

        content(&emitter)

        if let closing = block.closing {
            emitter.emit(closing)
        } else if block.opening == nil {
            emitter.emit(text: delimiter)
        }
    }

    // MARK: - Prelude

    private static func emitPrelude(of block: Block, into emitter: inout Emitter) {
        guard block.prelude.isEmpty else {
            for line in block.prelude {
                emitter.emit(line)
            }
            return
        }

        // Canonical, for built trees. Two kinds carry their title inside their
        // own text rather than in a `.Title` row: a section's heading line, and
        // a description item's term, which stands before its `::`.
        switch block.kind {
        case .section, .listItem:
            break
        default:
            if let title = block.title {
                emitter.emit(text: ".\(title.text)")
            }
        }

        // An include writes its attribute list inside its own line, so it
        // never gets one of its own.
        if case .include = block.kind {
            return
        }
        if let line = canonicalAttributeLine(block.attributes) {
            emitter.emit(text: line)
        }
    }

    /// A deterministic `[...]` line: shorthand first, remaining positionals,
    /// then named attributes sorted by name.
    private static func canonicalAttributeLine(_ attributes: BlockAttributes) -> String? {
        guard !attributes.isEmpty else {
            return nil
        }

        var shorthand = attributes.style ?? ""
        if let id = attributes.id {
            shorthand += "#\(id)"
        }
        for role in attributes.roles {
            shorthand += ".\(role)"
        }
        for option in attributes.options {
            shorthand += "%\(option)"
        }

        var fields = shorthand.isEmpty ? [] : [shorthand]

        var positional = attributes.positional[...]
        if attributes.style != nil, positional.first == attributes.style {
            positional = positional.dropFirst()
        }
        fields += positional.map(quoteIfNeeded)

        for (name, value) in attributes.named.sorted(by: { $0.key < $1.key }) {
            fields.append("\(name)=\(quoteIfNeeded(value))")
        }

        return fields.isEmpty ? nil : "[\(fields.joined(separator: ","))]"
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        value.contains(",") || value.contains(" ") ? "\"\(value)\"" : value
    }

    // MARK: - Canonical separation

    /// Whether this block's first row will be synthetic — built rather than
    /// parsed — in which case it needs a separating blank line.
    private static func startsSynthetic(_ block: Block) -> Bool {
        if let first = block.prelude.first {
            return first.number == 0
        }
        if let opening = block.opening {
            return opening.number == 0
        }
        if let first = block.lines.first {
            return first.number == 0
        }
        // A title or an attribute list with no line of its own behind it can
        // only have been built — a description item's term is written inside
        // the item's own line, and that line was checked above.
        if block.title != nil || !block.attributes.isEmpty {
            return true
        }
        if let firstChild = block.blocks.first {
            return startsSynthetic(firstChild)
        }
        return true
    }
}

extension SourceLine {
    /// A line with no source position, for documents built programmatically.
    /// The serializer places it directly after the previous row.
    public static func synthetic(_ text: String) -> SourceLine {
        let zero = SourceLocation(offset: 0, line: 0, column: 1)
        return SourceLine(
            text: text,
            range: SourceRange(start: zero, end: zero),
            number: 0
        )
    }
}
