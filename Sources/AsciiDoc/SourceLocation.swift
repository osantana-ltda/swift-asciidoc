// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// A position in an AsciiDoc source document.
///
/// Every node the parser produces carries its source range. This is required
/// twice over: the Abstract Semantic Graph used by the AsciiDoc TCK mandates
/// location metadata, and an editor needs it to map syntax back to the text it
/// decorates.
///
/// Offsets and columns are counted in **UTF-16 code units**. That is not the
/// obvious choice for a language tool — UTF-8 would be — but every Apple text
/// API this library exists to serve, `NSTextStorage` and `NSRange` above all,
/// is UTF-16 indexed, and a conversion on every lookup would cost more than it
/// saves.
public struct SourceLocation: Hashable, Sendable, Comparable {
    /// Offset in UTF-16 code units from the start of the document.
    public let offset: Int
    /// One-based line number.
    public let line: Int
    /// One-based column, in UTF-16 code units.
    public let column: Int

    public init(offset: Int, line: Int, column: Int) {
        self.offset = offset
        self.line = line
        self.column = column
    }

    public static func < (lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        lhs.offset < rhs.offset
    }
}

/// A half-open range of source text, `start ..< end`.
public struct SourceRange: Hashable, Sendable {
    public let start: SourceLocation
    public let end: SourceLocation

    public init(start: SourceLocation, end: SourceLocation) {
        self.start = start
        self.end = end
    }

    public var isEmpty: Bool {
        start.offset >= end.offset
    }

    public var length: Int {
        max(0, end.offset - start.offset)
    }

    public func contains(_ location: SourceLocation) -> Bool {
        location.offset >= start.offset && location.offset < end.offset
    }

    /// The smallest range covering both.
    public func union(_ other: SourceRange) -> SourceRange {
        SourceRange(
            start: min(start, other.start),
            end: max(end, other.end)
        )
    }
}

extension SourceLocation {
    static func max(_ lhs: SourceLocation, _ rhs: SourceLocation) -> SourceLocation {
        lhs.offset >= rhs.offset ? lhs : rhs
    }
}
