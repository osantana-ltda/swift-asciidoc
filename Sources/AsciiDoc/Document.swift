// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// A title, with the range of the text itself rather than of the line that
/// carries it. The distinction matters: the Abstract Semantic Graph locates a
/// section title at the first character after the marker, not at the marker.
public struct Title: Hashable, Sendable {
    public var text: String
    public var range: SourceRange

    public init(text: String, range: SourceRange) {
        self.text = text
        self.range = range
    }
}

/// A parsed AsciiDoc document.
public struct Document: Hashable, Sendable {
    /// The document header, if the source opens with one.
    public var header: DocumentHeader?
    /// Top-level blocks, in source order. Sections nest their own content.
    public var blocks: [Block]
    public var range: SourceRange
    /// Whether the source ended with a newline — the serializer must reproduce
    /// either form exactly.
    public var endsInNewline: Bool
    /// How many lines the source had, so trailing blank lines survive the
    /// round trip; zero for documents built programmatically.
    public var sourceLineCount: Int
    /// The source split into lines, retained so an edit can be reparsed
    /// incrementally without re-splitting the whole string. Empty for
    /// documents built programmatically.
    public var sourceLines: [SourceLine]
    /// The source length in UTF-16 code units.
    public var sourceLength: Int

    public init(
        header: DocumentHeader?,
        blocks: [Block],
        range: SourceRange,
        endsInNewline: Bool = true,
        sourceLineCount: Int = 0,
        sourceLines: [SourceLine] = [],
        sourceLength: Int = 0
    ) {
        self.header = header
        self.blocks = blocks
        self.range = range
        self.endsInNewline = endsInNewline
        self.sourceLineCount = sourceLineCount
        self.sourceLines = sourceLines
        self.sourceLength = sourceLength
    }

    /// Document attributes by name: those the header declares, over the ones
    /// AsciiDoc derives from the author line (`{author}`, `{email}`,
    /// `{firstname}` and their numbered forms). A declared entry wins, since
    /// writing `:author:` is how an author line is overridden.
    public var attributes: [String: String] {
        guard let header else {
            return [:]
        }
        var derived = authorAttributes(of: header)
        for entry in header.attributes {
            derived[entry.name] = entry.value
        }
        return derived
    }

    private func authorAttributes(of header: DocumentHeader) -> [String: String] {
        let authors = header.authors
        guard !authors.isEmpty else {
            return [:]
        }

        var attributes: [String: String] = ["authorcount": String(authors.count)]

        func record(_ author: Author, suffix: String) {
            attributes["author\(suffix)"] = author.fullName
            attributes["firstname\(suffix)"] = author.firstName
            attributes["authorinitials\(suffix)"] = author.initials
            if let middle = author.middleName {
                attributes["middlename\(suffix)"] = middle
            }
            if let last = author.lastName {
                attributes["lastname\(suffix)"] = last
            }
            if let email = author.email {
                attributes["email\(suffix)"] = email
            }
        }

        // The first author also answers to the unnumbered names.
        record(authors[0], suffix: "")
        for (index, author) in authors.enumerated() {
            record(author, suffix: "_\(index + 1)")
        }
        return attributes
    }
}

/// The block of lines before the first blank line, when it starts with a
/// level-zero title.
public struct DocumentHeader: Hashable, Sendable {
    public var title: Title?
    /// The whole `= Title` line, marker included.
    public var titleRange: SourceRange?
    /// The author line exactly as written — the stored, authoritative form.
    /// `authors` is the reading of it.
    public var authorLine: String?
    public var attributes: [AttributeEntry]
    public var range: SourceRange
    /// Every header line exactly as written, in order — what the serializer
    /// emits, so spacing and entry order survive the round trip.
    public var lines: [SourceLine]

    public init(
        title: Title?,
        titleRange: SourceRange?,
        authorLine: String?,
        attributes: [AttributeEntry],
        range: SourceRange,
        lines: [SourceLine] = []
    ) {
        self.title = title
        self.titleRange = titleRange
        self.authorLine = authorLine
        self.attributes = attributes
        self.range = range
        self.lines = lines
    }

    /// The author line read into names and addresses (§6). Computed, so the
    /// line itself remains the only stored form.
    public var authors: [Author] {
        authorLine.map(Author.parse(line:)) ?? []
    }
}

/// An attribute entry, `:name: value`, or `:name!:` to unset.
public struct AttributeEntry: Hashable, Sendable {
    public var name: String
    public var value: String
    public var isUnset: Bool
    public var range: SourceRange

    public init(name: String, value: String, isUnset: Bool, range: SourceRange) {
        self.name = name
        self.value = value
        self.isUnset = isUnset
        self.range = range
    }
}

/// A block of content.
///
/// Deliberately one type with a `kind` rather than a case per construct. The
/// shape of a block — a title, an attribute list, then either child blocks or
/// raw lines — is the same across the language, and a single type keeps the
/// tree easy to walk before inline parsing exists to complicate it.
public struct Block: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `== Title`, at the given level. Level 0 is the document title.
        case section(level: Int)
        case paragraph
        /// Content between the header and the first section. Only exists when
        /// the document has both a header and a section; established by
        /// probing Asciidoctor, since the specification does not say.
        case preamble
        /// `NOTE:`, `TIP:`, `IMPORTANT:`, `WARNING:` or `CAUTION:`, either as a
        /// paragraph prefix or as a `[NOTE]` style.
        case admonition(variant: String)
        /// `----`
        case listing
        /// `....`
        case literal
        /// `____`
        case quote
        /// `====`
        case example
        /// `****`
        case sidebar
        /// `++++`
        case passthrough
        /// `--`
        case open
        /// `|===`
        case table
        /// A row of cells; `header` marks rows in the table head.
        case tableRow(header: Bool)
        case tableCell
        case unorderedList
        case orderedList
        /// `term:: definition`
        case descriptionList
        /// An item of any list family. Its own lines are the item's text; a
        /// nested list, or a block attached with `+`, is a child block.
        case listItem
        /// A `//` line or a `////` block.
        case comment
        /// A `:name: value` entry outside the header.
        case attributeEntry
        /// `include::target[attrlist]`. Resolving one needs a filesystem,
        /// which this package deliberately has none of: the parse records the
        /// reference and the host expands it. An include that reaches the
        /// tree is therefore one nobody resolved, and it is kept whole.
        case include(target: String)
        /// A construct this parser does not model yet, preserved verbatim so
        /// that nothing is lost on the way back out.
        case unparsed
    }

    public var kind: Kind
    /// Everything the block covers, including its delimiters, attribute list
    /// and title.
    public var range: SourceRange
    /// The block title, from a `.Title` line, a section's own title, or a
    /// description item's term — the label standing before its definition.
    public var title: Title?
    public var attributes: BlockAttributes
    /// Nested blocks, for sections, lists and compound delimited blocks.
    public var blocks: [Block]
    /// Content lines, for leaf blocks. Inline structure is not parsed yet, so
    /// these are the raw lines. Compound blocks that were recognised from
    /// marker syntax — tables, Markdown quotes — also keep their raw content
    /// here as verbatim backing for the serializer.
    public var lines: [SourceLine]
    /// Metadata lines exactly as written — anchors, attribute lists, the
    /// `.Title` line — in source order.
    public var prelude: [SourceLine]
    /// The line that opened this block, verbatim: a section's heading line, a
    /// delimited block's opening delimiter, or a prefix admonition's original
    /// labelled first line.
    public var opening: SourceLine?
    /// The closing delimiter line, verbatim; nil for unterminated blocks,
    /// which stay unterminated on the way back out.
    public var closing: SourceLine?

    public init(
        kind: Kind,
        range: SourceRange,
        title: Title? = nil,
        attributes: BlockAttributes = BlockAttributes(),
        blocks: [Block] = [],
        lines: [SourceLine] = [],
        prelude: [SourceLine] = [],
        opening: SourceLine? = nil,
        closing: SourceLine? = nil
    ) {
        self.kind = kind
        self.range = range
        self.title = title
        self.attributes = attributes
        self.blocks = blocks
        self.lines = lines
        self.prelude = prelude
        self.opening = opening
        self.closing = closing
    }

    /// The block's text content, joined by newlines. Convenience for leaf
    /// blocks; empty for blocks that hold children.
    public var text: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

/// The contents of a `[...]` block attribute list.
public struct BlockAttributes: Hashable, Sendable {
    /// From `[#id]` or `[[id]]`.
    public var id: String?
    /// From `[.role]` or a `role=` named attribute.
    public var roles: [String]
    /// From `[%option]` or an `options=`/`opts=` named attribute.
    public var options: [String]
    /// The first positional attribute, which names the block's style —
    /// `source` in `[source,swift]`.
    public var style: String?
    public var positional: [String]
    public var named: [String: String]
    /// The `[...]` line itself, when there was one.
    public var range: SourceRange?

    public init(
        id: String? = nil,
        roles: [String] = [],
        options: [String] = [],
        style: String? = nil,
        positional: [String] = [],
        named: [String: String] = [:],
        range: SourceRange? = nil
    ) {
        self.id = id
        self.roles = roles
        self.options = options
        self.style = style
        self.positional = positional
        self.named = named
        self.range = range
    }

    public var isEmpty: Bool {
        id == nil && roles.isEmpty && options.isEmpty && style == nil && positional.isEmpty
            && named.isEmpty
    }
}
