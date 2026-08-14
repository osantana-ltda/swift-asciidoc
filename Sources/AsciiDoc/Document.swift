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

    public init(header: DocumentHeader?, blocks: [Block], range: SourceRange) {
        self.header = header
        self.blocks = blocks
        self.range = range
    }

    /// Document attributes declared in the header, by name.
    public var attributes: [String: String] {
        guard let header else {
            return [:]
        }
        return Dictionary(
            header.attributes.map { ($0.name, $0.value) },
            uniquingKeysWith: { _, last in last }
        )
    }
}

/// The block of lines before the first blank line, when it starts with a
/// level-zero title.
public struct DocumentHeader: Hashable, Sendable {
    public var title: Title?
    /// The whole `= Title` line, marker included.
    public var titleRange: SourceRange?
    /// The author line, unparsed. Splitting it into names and addresses is
    /// deferred; see the package's documented limitations.
    public var authorLine: String?
    public var attributes: [AttributeEntry]
    public var range: SourceRange

    public init(
        title: Title?,
        titleRange: SourceRange?,
        authorLine: String?,
        attributes: [AttributeEntry],
        range: SourceRange
    ) {
        self.title = title
        self.titleRange = titleRange
        self.authorLine = authorLine
        self.attributes = attributes
        self.range = range
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
        case listItem
        /// A `//` line or a `////` block.
        case comment
        /// A `:name: value` entry outside the header.
        case attributeEntry
        /// A construct this parser does not model yet, preserved verbatim so
        /// that nothing is lost on the way back out.
        case unparsed
    }

    public var kind: Kind
    /// Everything the block covers, including its delimiters, attribute list
    /// and title.
    public var range: SourceRange
    /// The block title, from a `.Title` line, or a section's own title.
    public var title: Title?
    public var attributes: BlockAttributes
    /// Nested blocks, for sections, lists and compound delimited blocks.
    public var blocks: [Block]
    /// Content lines, for leaf blocks. Inline structure is not parsed yet, so
    /// these are the raw lines.
    public var lines: [SourceLine]

    public init(
        kind: Kind,
        range: SourceRange,
        title: Title? = nil,
        attributes: BlockAttributes = BlockAttributes(),
        blocks: [Block] = [],
        lines: [SourceLine] = []
    ) {
        self.kind = kind
        self.range = range
        self.title = title
        self.attributes = attributes
        self.blocks = blocks
        self.lines = lines
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
