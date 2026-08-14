// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// A run of inline content: plain text, or a formatting span holding more
/// inline content.
public enum Inline: Hashable, Sendable {
    case text(value: String, range: SourceRange)
    case span(Span)

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
        }
    }

    /// The plain text of this inline and everything under it, markup dropped.
    public var plainText: String {
        switch self {
        case .text(let value, _): value
        case .span(let span): span.inlines.map(\.plainText).joined()
        }
    }
}
