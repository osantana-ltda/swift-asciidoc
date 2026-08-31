// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// A run of inline content: plain text, or a formatting span holding more
/// inline content.
public enum Inline: Hashable, Sendable {
    case text(value: String, range: SourceRange)
    case span(Span)
    case macro(Macro)
    /// `{name}` — a document attribute reference. The parse keeps the
    /// reference, never the value: substitution is a rendering concern, and
    /// the source round-trips untouched.
    case attributeReference(name: String, range: SourceRange)
    /// `[[id]]` or `[[id,reftext]]` — an inline anchor: a cross-reference
    /// target sitting inside prose. The `anchor:id[]` macro form parses as
    /// a macro instead, like every other `name:target[]`.
    case anchor(id: String, reftext: String, range: SourceRange)

    /// An inline macro: `name:target[attrlist]`, a bare URL, or the `<<xref>>`
    /// shorthand — the last two normalised to `link` and `xref` macros.
    public struct Macro: Hashable, Sendable {
        public var name: String
        /// Between the colon and the bracket; the URL itself for links, empty
        /// for macros like `footnote:[...]` and `kbd:[...]`.
        public var target: String
        /// The raw attribute list between the brackets, exactly as written.
        /// This stays the source of truth — serialization writes it back
        /// untouched; `attributeList` is the *reading* of it.
        public var attributes: String
        /// The whole macro, name through closing bracket.
        public var range: SourceRange

        public init(name: String, target: String, attributes: String, range: SourceRange) {
            self.name = name
            self.target = target
            self.attributes = attributes
            self.range = range
        }

        /// The attribute list read as fields: positional arguments, named
        /// values, and the `#id.role%option` shorthand. Computed on demand
        /// so the raw string remains the only stored form.
        ///
        /// Not meaningful for every macro: `xref` and a bracketed URL carry
        /// reference text here, not an attribute list, and their readers
        /// should use `attributes` directly.
        public var attributeList: BlockAttributes {
            var parsed = BlockAttributes(range: range)
            AttributeListParser.parse(
                body: attributes, into: &parsed, firstPositionalIsStyle: false)
            return parsed
        }
    }

    public struct Span: Hashable, Sendable {
        public enum Variant: String, Hashable, Sendable {
            /// `*strong*`
            case strong
            /// `_emphasis_`
            case emphasis
            /// `` `code` ``
            case code
            /// `#mark#`
            case mark
            /// `^superscript^`
            case superscriptText = "superscript"
            /// `~subscript~`
            case subscriptText = "subscript"
        }

        public enum Form: String, Hashable, Sendable {
            /// Single delimiters, valid only at word boundaries.
            case constrained
            /// Doubled delimiters, valid anywhere.
            case unconstrained
        }

        public var variant: Variant
        public var form: Form
        public var inlines: [Inline]
        /// The whole span, delimiters included.
        public var range: SourceRange

        public init(variant: Variant, form: Form, inlines: [Inline], range: SourceRange) {
            self.variant = variant
            self.form = form
            self.inlines = inlines
            self.range = range
        }
    }

    public var range: SourceRange {
        switch self {
        case .text(_, let range): range
        case .span(let span): span.range
        case .macro(let macro): macro.range
        case .attributeReference(_, let range): range
        case .anchor(_, _, let range): range
        }
    }

    /// The plain text of this inline and everything under it, markup dropped.
    /// For a macro this is its display text — the attribute list when there is
    /// one, the target otherwise. An attribute reference stays in its raw
    /// form: plain text has no document to resolve against.
    public var plainText: String {
        switch self {
        case .text(let value, _): value
        case .span(let span): span.inlines.map(\.plainText).joined()
        case .macro(let macro): macro.attributes.isEmpty ? macro.target : macro.attributes
        case .attributeReference(let name, _): "{\(name)}"
        // An anchor marks a place; it contributes no prose of its own,
        // beyond the reference text when one is given.
        case .anchor(_, let reftext, _): reftext
        }
    }
}
