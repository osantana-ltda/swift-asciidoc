// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// Parses AsciiDoc into a block tree.
///
/// This is a line-oriented recursive-descent parser: almost every AsciiDoc
/// construct is decided by what a line begins with, and the few that are not —
/// delimited blocks, list continuation — need only to look ahead by lines.
///
/// It parses **block structure only**. Inline syntax inside a paragraph is left
/// as raw lines for now. Anything the parser does not model is preserved as an
/// `.unparsed` block rather than dropped or guessed at, so a document survives a
/// round trip even where this parser does not yet understand it.
public enum Parser {
    public static func parse(_ source: String) -> Document {
        parse(lines: LineReader.lines(of: source), sourceLength: source.utf16.count)
    }

    /// The entry the incremental parser uses: the lines are already split, so a
    /// spliced edit skips the string scan entirely.
    static func parse(lines: [SourceLine], sourceLength: Int) -> Document {
        var state = State(lines: lines)
        let header = state.parseHeader()
        var blocks = state.parseBlocks(untilSectionLevel: nil)

        if header != nil {
            blocks = wrapPreamble(blocks)
        }

        let start = header?.range.start ?? blocks.first?.range.start
        let end = blocks.last?.range.end ?? header?.range.end

        return Document(
            header: header,
            blocks: blocks,
            range: SourceRange(
                start: start ?? SourceLocation(offset: 0, line: 1, column: 1),
                end: end ?? SourceLocation(offset: 0, line: 1, column: 1)
            ),
            // A trailing terminator exists exactly when the last line's content
            // ends before the source does. This is UTF-16 arithmetic rather
            // than `hasSuffix("\n")`, which is false for a CRLF document —
            // Swift reads the final `\r\n` as one grapheme.
            endsInNewline: (lines.last?.range.end.offset ?? 0) < sourceLength,
            sourceLineCount: lines.count,
            sourceLines: lines,
            sourceLength: sourceLength
        )
    }
}

extension Parser {
    /// Content between the header and the first section becomes a preamble —
    /// but only when there is a section for it to precede, and only when the
    /// document has a header. A document with leading text and no section has
    /// no preamble, and neither does one without a header.
    fileprivate static func wrapPreamble(_ blocks: [Block]) -> [Block] {
        guard
            let firstSection = blocks.firstIndex(where: {
                if case .section = $0.kind { true } else { false }
            }),
            firstSection > 0
        else {
            return blocks
        }

        let leading = Array(blocks[..<firstSection])
        let preamble = Block(
            kind: .preamble,
            range: SourceRange(
                start: leading[0].range.start,
                end: leading[leading.count - 1].range.end
            ),
            blocks: leading
        )

        return [preamble] + blocks[firstSection...]
    }

    struct State {
        let lines: [SourceLine]
        var index = 0

        var current: SourceLine? {
            index < lines.count ? lines[index] : nil
        }

        func peek(_ ahead: Int) -> SourceLine? {
            let target = index + ahead
            return target < lines.count ? lines[target] : nil
        }

        mutating func advance() {
            index += 1
        }

        mutating func skipBlankLines() {
            while let line = current, line.isBlank {
                advance()
            }
        }

        // MARK: - Header

        mutating func parseHeader() -> DocumentHeader? {
            skipBlankLines()

            guard let first = current, let title = Self.sectionTitle(first, level: 0) else {
                return parseAttributeOnlyHeader()
            }

            advance()
            var headerLines = [first]
            var authorLine: String?
            if let next = current, !next.isBlank, !Self.isAttributeEntry(next) {
                authorLine = String(next.trimmed)
                headerLines.append(next)
                advance()
            }

            let (attributes, attributeLines) = parseHeaderAttributes()
            headerLines += attributeLines
            let end = attributes.last?.range.end ?? first.range.end

            return DocumentHeader(
                title: title,
                titleRange: first.range,
                authorLine: authorLine,
                attributes: attributes,
                range: SourceRange(start: first.range.start, end: end),
                lines: headerLines
            )
        }

        /// A document may open with attribute entries and no title.
        private mutating func parseAttributeOnlyHeader() -> DocumentHeader? {
            guard let first = current, Self.isAttributeEntry(first) else {
                return nil
            }

            let (attributes, attributeLines) = parseHeaderAttributes()
            guard let last = attributes.last else {
                return nil
            }

            return DocumentHeader(
                title: nil,
                titleRange: nil,
                authorLine: nil,
                attributes: attributes,
                range: SourceRange(start: first.range.start, end: last.range.end),
                lines: attributeLines
            )
        }

        private mutating func parseHeaderAttributes() -> ([AttributeEntry], [SourceLine]) {
            var entries: [AttributeEntry] = []
            var lines: [SourceLine] = []
            while let line = current, !line.isBlank {
                guard let entry = Self.attributeEntry(line) else {
                    break
                }
                entries.append(entry)
                lines.append(line)
                advance()
            }
            return (entries, lines)
        }

        // MARK: - Blocks

        /// Parses blocks until the end of input, or until a section whose level
        /// is at or above `untilSectionLevel` — which is where a section's own
        /// content stops.
        mutating func parseBlocks(untilSectionLevel limit: Int?) -> [Block] {
            var blocks: [Block] = []

            while true {
                skipBlankLines()
                guard let line = current else {
                    break
                }

                if let level = Self.sectionLevel(line), let limit, level <= limit {
                    break
                }

                guard let block = parseBlock() else {
                    break
                }
                blocks.append(block)
            }

            return blocks
        }

        mutating func parseBlock() -> Block? {
            var metadata = Metadata()
            metadata.collect(from: &self)

            skipBlankLines()
            guard let line = current else {
                return metadata.orphanBlock()
            }

            if let level = Self.sectionLevel(line) {
                return parseSection(level: level, metadata: metadata)
            }

            if let delimiter = Delimiter(line: line) {
                return parseDelimited(delimiter, metadata: metadata)
            }

            if Self.isLineComment(line) {
                return parseLineComments(metadata: metadata)
            }

            if let entry = Self.attributeEntry(line) {
                advance()
                return metadata.finish(
                    kind: .attributeEntry,
                    range: entry.range,
                    lines: [line]
                )
            }

            if Self.isMarkdownQuote(line) {
                return parseMarkdownQuote(metadata: metadata)
            }

            if ListMarker(line: line) != nil {
                return parseList(metadata: metadata)
            }

            return parseParagraph(metadata: metadata)
        }

        /// `NOTE: text` and friends. The label is markup, so it is dropped from
        /// the content the way Asciidoctor drops it.
        static func admonitionVariant(_ line: SourceLine) -> String? {
            let trimmed = line.trimmed
            for label in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]
            where trimmed.hasPrefix(label + ": ") {
                return label.lowercased()
            }
            return nil
        }

        private mutating func parseSection(level: Int, metadata: Metadata) -> Block {
            guard let line = current else {
                return metadata.orphanBlock() ?? Block(kind: .section(level: level), range: .empty)
            }

            let title = Self.sectionTitle(line, level: level)
            advance()

            let children = parseBlocks(untilSectionLevel: level)
            let end = children.last?.range.end ?? line.range.end

            var block = metadata.finish(
                kind: .section(level: level),
                range: SourceRange(start: line.range.start, end: end),
                blocks: children,
                opening: line
            )
            block.title = title
            return block
        }

        private mutating func parseDelimited(_ delimiter: Delimiter, metadata: Metadata) -> Block {
            guard let opening = current else {
                return metadata.orphanBlock() ?? Block(kind: delimiter.kind, range: .empty)
            }
            advance()

            var content: [SourceLine] = []
            var closing: SourceLine?

            while let line = current {
                if delimiter.closes(line) {
                    closing = line
                    advance()
                    break
                }
                content.append(line)
                advance()
            }

            let range = SourceRange(
                start: opening.range.start,
                end: closing?.range.end ?? content.last?.range.end ?? opening.range.end
            )

            if delimiter.kind == .table {
                return metadata.finish(
                    kind: .table,
                    range: range,
                    blocks: TableParser.rows(of: content, attributes: metadata.attributes),
                    lines: content,
                    opening: opening,
                    closing: closing
                )
            }

            // A compound block holds blocks; a verbatim one holds its lines
            // exactly as written, which is the whole point of it.
            if delimiter.isCompound {
                var inner = State(lines: content)
                return metadata.finish(
                    kind: delimiter.kind,
                    range: range,
                    blocks: inner.parseBlocks(untilSectionLevel: nil),
                    opening: opening,
                    closing: closing
                )
            }

            return metadata.finish(
                kind: delimiter.kind,
                range: range,
                lines: content,
                opening: opening,
                closing: closing
            )
        }

        private mutating func parseLineComments(metadata: Metadata) -> Block {
            var comments: [SourceLine] = []
            while let line = current, Self.isLineComment(line) {
                comments.append(line)
                advance()
            }

            return metadata.finish(
                kind: .comment,
                range: SourceRange(
                    start: comments[0].range.start,
                    end: comments[comments.count - 1].range.end
                ),
                lines: comments
            )
        }

        private mutating func parseParagraph(metadata: Metadata) -> Block {
            var content: [SourceLine] = []

            while let line = current,
                !line.isBlank,
                Self.sectionLevel(line) == nil,
                Delimiter(line: line) == nil,
                !Self.isLineComment(line),
                !Self.isMarkdownQuote(line),
                ListMarker(line: line) == nil,
                !Self.isBlockAttributeLine(line)
            {
                content.append(line)
                advance()
            }

            guard !content.isEmpty else {
                // Nothing consumable here; take the line verbatim rather than
                // spinning.
                let line = current
                if line != nil {
                    advance()
                }
                return metadata.finish(
                    kind: .unparsed,
                    range: line?.range ?? .empty,
                    lines: line.map { [$0] } ?? []
                )
            }

            var kind = Block.Kind.paragraph
            var labelledLine: SourceLine?
            if let variant = Self.admonitionVariant(content[0]) {
                kind = .admonition(variant: variant)
                labelledLine = content[0]
                content[0] = Self.strippingLabel(content[0], length: variant.count + 2)
            }

            return metadata.finish(
                kind: kind,
                range: SourceRange(
                    start: content[0].range.start,
                    end: content[content.count - 1].range.end
                ),
                lines: content,
                opening: labelledLine
            )
        }

        /// Drops a leading label from a line, keeping the rest located where it
        /// actually is.
        static func strippingLabel(_ line: SourceLine, length: Int) -> SourceLine {
            let leading = line.text.prefix { $0 == " " || $0 == "\t" }.count
            let drop = leading + length
            let text = String(line.text.dropFirst(drop))
            let startColumn = line.range.start.column + drop

            return SourceLine(
                text: text,
                range: SourceRange(
                    start: SourceLocation(
                        offset: line.range.start.offset + drop,
                        line: line.number,
                        column: startColumn
                    ),
                    end: line.range.end
                ),
                number: line.number
            )
        }

        /// AsciiDoc also accepts Markdown's `>` blockquote, which Asciidoctor
        /// reads as a quote block. Found by comparing against it on a real
        /// document — the TCK has no case for it.
        static func isMarkdownQuote(_ line: SourceLine) -> Bool {
            let trimmed = line.trimmed
            return trimmed == ">" || trimmed.hasPrefix("> ")
        }

        private mutating func parseMarkdownQuote(metadata: Metadata) -> Block {
            guard let first = current else {
                return metadata.orphanBlock() ?? Block(kind: .quote, range: .empty)
            }

            var stripped: [SourceLine] = []
            var originals: [SourceLine] = []
            var last = first

            while let line = current, Self.isMarkdownQuote(line) {
                let marker = line.trimmed == ">" ? 1 : 2
                stripped.append(Self.strippingLabel(line, length: marker))
                originals.append(line)
                last = line
                advance()
            }

            var inner = State(lines: stripped)
            return metadata.finish(
                kind: .quote,
                range: SourceRange(start: first.range.start, end: last.range.end),
                blocks: inner.parseBlocks(untilSectionLevel: nil),
                lines: originals
            )
        }

        // MARK: - Lists

        private mutating func parseList(metadata: Metadata) -> Block {
            guard let first = current, let marker = ListMarker(line: first) else {
                return metadata.orphanBlock() ?? Block(kind: .unorderedList, range: .empty)
            }

            var items: [Block] = []
            while let line = current, let next = ListMarker(line: line), next.depth >= marker.depth
            {
                guard next.isOrdered == marker.isOrdered, next.depth == marker.depth else {
                    // A deeper marker belongs to the item just read; nesting is
                    // not modelled yet, so it is left to the item's own lines.
                    break
                }
                items.append(parseListItem())
            }

            let range = SourceRange(
                start: first.range.start,
                end: items.last?.range.end ?? first.range.end
            )

            return metadata.finish(
                kind: marker.isOrdered ? .orderedList : .unorderedList,
                range: range,
                blocks: items
            )
        }

        private mutating func parseListItem() -> Block {
            guard let first = current else {
                return Block(kind: .listItem, range: .empty)
            }

            var content = [first]
            advance()

            // Wrapped lines belong to the item; a new marker or a blank line
            // ends it. List continuation with `+` is not modelled yet.
            while let line = current, !line.isBlank, ListMarker(line: line) == nil,
                Self.sectionLevel(line) == nil, Delimiter(line: line) == nil
            {
                content.append(line)
                advance()
            }

            return Block(
                kind: .listItem,
                range: SourceRange(
                    start: first.range.start,
                    end: content[content.count - 1].range.end
                ),
                lines: content
            )
        }

        // MARK: - Line classification

        static func sectionLevel(_ line: SourceLine) -> Int? {
            let trimmed = line.trimmed
            let equals = trimmed.prefix { $0 == "=" }
            guard !equals.isEmpty, equals.count <= 6 else {
                return nil
            }
            guard trimmed.dropFirst(equals.count).hasPrefix(" ") else {
                return nil
            }
            return equals.count - 1
        }

        /// The title's text and its own range, which starts after the marker
        /// and the space that follows it.
        static func sectionTitle(_ line: SourceLine, level: Int) -> Title? {
            guard sectionLevel(line) == level else {
                return nil
            }
            return Self.title(in: line, skipping: level + 1)
        }

        /// Builds a title from `line`, dropping `markerLength` characters of
        /// marker plus any spaces after it, and locating what remains.
        static func title(in line: SourceLine, skipping markerLength: Int) -> Title? {
            let leading = line.text.prefix { $0 == " " || $0 == "\t" }.count
            let afterMarker = line.text.dropFirst(leading + markerLength)
            let spaces = afterMarker.prefix { $0 == " " }.count
            let text = String(afterMarker.dropFirst(spaces))

            guard !text.isEmpty else {
                return nil
            }

            let startColumn = leading + markerLength + spaces + 1
            let startOffset = line.range.start.offset + startColumn - 1

            return Title(
                text: text,
                range: SourceRange(
                    start: SourceLocation(
                        offset: startOffset,
                        line: line.number,
                        column: startColumn
                    ),
                    end: SourceLocation(
                        offset: startOffset + text.utf16.count,
                        line: line.number,
                        column: startColumn + text.utf16.count
                    )
                )
            )
        }

        static func isLineComment(_ line: SourceLine) -> Bool {
            let trimmed = line.trimmed
            return trimmed.hasPrefix("//") && !trimmed.hasPrefix("////")
        }

        static func isAttributeEntry(_ line: SourceLine) -> Bool {
            attributeEntry(line) != nil
        }

        static func attributeEntry(_ line: SourceLine) -> AttributeEntry? {
            let trimmed = line.trimmed
            guard trimmed.hasPrefix(":") else {
                return nil
            }

            let body = trimmed.dropFirst()
            guard let colon = body.firstIndex(of: ":") else {
                return nil
            }

            var name = String(body[body.startIndex..<colon])
            guard !name.isEmpty, !name.contains(" ") else {
                return nil
            }

            let isUnset = name.hasSuffix("!")
            if isUnset {
                name.removeLast()
            }

            let value = body[body.index(after: colon)...]
                .drop { $0 == " " }

            return AttributeEntry(
                name: name,
                value: String(value),
                isUnset: isUnset,
                range: line.range
            )
        }

        static func isBlockAttributeLine(_ line: SourceLine) -> Bool {
            let trimmed = line.trimmed
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.count >= 2
        }
    }
}

// MARK: - Block metadata

extension Parser {
    /// A block title and attribute list read before the block they belong to.
    fileprivate struct Metadata {
        var title: Title?
        var attributes = BlockAttributes()
        var start: SourceLocation?
        /// The metadata lines exactly as written, for the serializer.
        var rawLines: [SourceLine] = []

        mutating func collect(from state: inout Parser.State) {
            while true {
                state.skipBlankLines()
                guard let line = state.current else {
                    return
                }

                let trimmed = line.trimmed

                if Parser.State.isBlockAttributeLine(line) {
                    apply(AttributeListParser.parse(String(trimmed), range: line.range))
                    start = start ?? line.range.start
                    rawLines.append(line)
                    state.advance()
                    continue
                }

                // `.Title`, but not `...` which opens a literal block.
                if trimmed.hasPrefix("."), !trimmed.hasPrefix(".."),
                    trimmed.count > 1,
                    let second = trimmed.dropFirst().first, second != " "
                {
                    title = Metadata.blockTitle(of: line)
                    start = start ?? line.range.start
                    rawLines.append(line)
                    state.advance()
                    continue
                }

                return
            }
        }

        /// `.Title` — the marker is one character.
        static func blockTitle(of line: SourceLine) -> Title? {
            Parser.State.title(in: line, skipping: 1)
        }

        private mutating func apply(_ parsed: BlockAttributes) {
            attributes.id = parsed.id ?? attributes.id
            attributes.roles += parsed.roles
            attributes.options += parsed.options
            attributes.style = parsed.style ?? attributes.style
            attributes.positional += parsed.positional
            attributes.named.merge(parsed.named) { _, new in new }
            attributes.range = attributes.range.map { $0.union(parsed.range ?? $0) } ?? parsed.range
        }

        /// A style in the attribute list outranks the delimiter, and outranks
        /// having no delimiter at all: `[source]` over `....` is a listing, not
        /// a literal, and `[source]` over bare lines is a listing, not a
        /// paragraph. Found by comparing against Asciidoctor on a real
        /// document — see tools/compare-with-asciidoctor.py.
        static func isCompound(_ kind: Block.Kind) -> Bool {
            switch kind {
            case .quote, .example, .sidebar, .open: true
            default: false
            }
        }

        static func kind(forStyle style: String) -> Block.Kind? {
            switch style {
            case "source", "listing": .listing
            case "literal": .literal
            case "quote", "verse": .quote
            case "example": .example
            case "sidebar": .sidebar
            case "pass": .passthrough
            case "open": .open
            case "comment": .comment
            case "NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION":
                .admonition(
                    variant: style.lowercased()
                )
            default: nil
            }
        }

        func finish(
            kind: Block.Kind,
            range: SourceRange,
            blocks: [Block] = [],
            lines: [SourceLine] = [],
            opening: SourceLine? = nil,
            closing: SourceLine? = nil
        ) -> Block {
            var kind = kind
            var blocks = blocks
            var lines = lines

            // Only content blocks take a style; a section or a list is what it
            // is regardless of what the attribute list says.
            switch kind {
            case .paragraph, .listing, .literal, .quote, .example, .sidebar,
                .passthrough, .open, .admonition:
                if let style = attributes.style, let overridden = Self.kind(forStyle: style) {
                    kind = overridden
                }
            default:
                break
            }

            // A style that turns a paragraph into a compound block leaves the
            // text as that block's child, not as its own lines: `[quote]` over a
            // paragraph is a quote *containing* a paragraph.
            if case .paragraph = kind {
            } else if !lines.isEmpty, blocks.isEmpty,
                Self.isCompound(kind)
            {
                blocks = [
                    Block(
                        kind: .paragraph,
                        range: SourceRange(
                            start: lines[0].range.start,
                            end: lines[lines.count - 1].range.end
                        ),
                        lines: lines
                    )
                ]
                lines = []
            }

            return Block(
                kind: kind,
                range: SourceRange(start: start ?? range.start, end: range.end),
                title: title,
                attributes: attributes,
                blocks: blocks,
                lines: lines,
                prelude: rawLines,
                opening: opening,
                closing: closing
            )
        }

        /// Metadata at the very end of a document, with no block to attach to.
        func orphanBlock() -> Block? {
            guard let start, !attributes.isEmpty || title != nil else {
                return nil
            }
            return Block(
                kind: .unparsed,
                range: SourceRange(start: start, end: attributes.range?.end ?? start),
                title: title,
                attributes: attributes,
                prelude: rawLines
            )
        }
    }
}

// MARK: - Delimiters

extension Parser {
    fileprivate struct Delimiter: Equatable {
        let text: String
        let kind: Block.Kind
        let isCompound: Bool

        init?(line: SourceLine) {
            let trimmed = String(line.trimmed)

            if trimmed == "--" {
                text = trimmed
                kind = .open
                isCompound = true
                return
            }

            guard let first = trimmed.first, trimmed.count >= 4,
                trimmed.allSatisfy({ $0 == first })
            else {
                if trimmed.hasPrefix("|===") {
                    text = "|==="
                    kind = .table
                    isCompound = false
                    return
                }
                return nil
            }

            switch first {
            case "-":
                kind = .listing
                isCompound = false
            case ".":
                kind = .literal
                isCompound = false
            case "_":
                kind = .quote
                isCompound = true
            case "=":
                kind = .example
                isCompound = true
            case "*":
                kind = .sidebar
                isCompound = true
            case "+":
                kind = .passthrough
                isCompound = false
            case "/":
                kind = .comment
                isCompound = false
            default:
                return nil
            }

            text = trimmed
        }

        /// AsciiDoc closes a delimited block with a line of the same character,
        /// not necessarily the same length.
        func closes(_ line: SourceLine) -> Bool {
            let trimmed = String(line.trimmed)
            guard let first = text.first else {
                return false
            }

            if text == "--" {
                return trimmed == "--"
            }
            if text == "|===" {
                return trimmed == "|==="
            }

            return trimmed.count >= 4 && trimmed.allSatisfy { $0 == first }
        }
    }
}

// MARK: - List markers

extension Parser {
    fileprivate struct ListMarker {
        let depth: Int
        let isOrdered: Bool

        init?(line: SourceLine) {
            let trimmed = line.trimmed
            guard let first = trimmed.first else {
                return nil
            }

            switch first {
            case "*", "-":
                let run = trimmed.prefix { $0 == first }
                guard trimmed.dropFirst(run.count).hasPrefix(" ") else {
                    return nil
                }
                // Four or more is a delimiter, not a list.
                guard !(first == "*" && run.count >= 4), !(first == "-" && run.count >= 2) else {
                    return nil
                }
                depth = run.count
                isOrdered = false

            case ".":
                let run = trimmed.prefix { $0 == "." }
                guard run.count < 4, trimmed.dropFirst(run.count).hasPrefix(" ") else {
                    return nil
                }
                depth = run.count
                isOrdered = true

            case "0"..."9":
                let digits = trimmed.prefix { $0.isNumber }
                guard trimmed.dropFirst(digits.count).hasPrefix(". ") else {
                    return nil
                }
                depth = 1
                isOrdered = true

            default:
                return nil
            }
        }
    }
}

// MARK: - Attribute lists

enum AttributeListParser {
    /// Parses the inside of a `[...]` line.
    static func parse(_ text: String, range: SourceRange) -> BlockAttributes {
        var attributes = BlockAttributes(range: range)

        var body = text
        guard body.hasPrefix("["), body.hasSuffix("]") else {
            return attributes
        }
        body.removeFirst()
        body.removeLast()

        // `[[id]]` is an anchor rather than an attribute list.
        if body.hasPrefix("["), body.hasSuffix("]") {
            var anchor = body
            anchor.removeFirst()
            anchor.removeLast()
            attributes.id = String(anchor.prefix { $0 != "," })
            return attributes
        }

        parse(body: body, into: &attributes, firstPositionalIsStyle: true)
        return attributes
    }

    /// Parses the fields of an attribute list — the part between the
    /// brackets. Inline macros share this with block attribute lines: same
    /// syntax, same shorthand, same quoting. They differ in one reading
    /// only: a macro's first positional is its own argument (a link's text,
    /// an image's alt), never a block style.
    static func parse(
        body: String, into attributes: inout BlockAttributes, firstPositionalIsStyle: Bool
    ) {
        for (position, field) in split(body).enumerated() {
            let trimmed = field.trimmingCharactersInWhitespace

            if let equals = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("#"),
                !trimmed.hasPrefix(".")
            {
                let name = String(trimmed[trimmed.startIndex..<equals])
                    .trimmingCharactersInWhitespace
                var value = String(trimmed[trimmed.index(after: equals)...])
                    .trimmingCharactersInWhitespace
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value.removeFirst()
                    value.removeLast()
                }
                if name == "role" {
                    attributes.roles += value.split(separator: " ").map(String.init)
                } else if name == "id" {
                    attributes.id = value
                } else if name == "options" || name == "opts" {
                    attributes.options += value.split(separator: ",").map(String.init)
                } else {
                    attributes.named[name] = value
                }
                continue
            }

            // Shorthand: `style#id.role1.role2%option`
            var shorthand = trimmed[...]
            var positional = ""
            while let character = shorthand.first, character != "#", character != ".",
                character != "%"
            {
                positional.append(character)
                shorthand = shorthand.dropFirst()
            }

            while let marker = shorthand.first {
                shorthand = shorthand.dropFirst()
                let value = String(shorthand.prefix { $0 != "#" && $0 != "." && $0 != "%" })
                shorthand = shorthand.dropFirst(value.count)
                switch marker {
                case "#": attributes.id = value
                case "%": attributes.options.append(value)
                default: attributes.roles.append(value)
                }
            }

            if !positional.isEmpty {
                attributes.positional.append(positional)
                if position == 0, firstPositionalIsStyle {
                    attributes.style = positional
                }
            }
        }
    }

    /// Splits on commas outside quotes.
    private static func split(_ body: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false

        for character in body {
            if character == "\"" {
                quoted.toggle()
                current.append(character)
                continue
            }
            if character == "," && !quoted {
                fields.append(current)
                current = ""
                continue
            }
            current.append(character)
        }

        fields.append(current)
        return fields
    }
}

extension String {
    fileprivate var trimmingCharactersInWhitespace: String {
        var slice = self[...]
        while let first = slice.first, first == " " || first == "\t" {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == " " || last == "\t" {
            slice = slice.dropLast()
        }
        return String(slice)
    }
}

extension SourceRange {
    fileprivate static var empty: SourceRange {
        let zero = SourceLocation(offset: 0, line: 1, column: 1)
        return SourceRange(start: zero, end: zero)
    }
}
