// SPDX-License-Identifier: AGPL-3.0-only

/// A position in an AsciiDoc source document.
///
/// Every node the parser produces carries its source range. This is required
/// twice over: the Abstract Semantic Graph used by the AsciiDoc TCK mandates
/// location metadata, and an editor needs it to map syntax back to the text it
/// decorates.
public struct SourceLocation: Hashable, Sendable, Comparable {
    /// Byte offset from the start of the document.
    public let offset: Int
    /// One-based line number.
    public let line: Int
    /// One-based column, counted in Unicode scalars rather than bytes.
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

    public func contains(_ location: SourceLocation) -> Bool {
        location.offset >= start.offset && location.offset < end.offset
    }
}
