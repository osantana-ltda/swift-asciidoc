// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// One line of source, with its position.
///
/// AsciiDoc is a line-oriented language: almost every construct is decided by
/// what a line starts with, and only a few need to look further. Splitting once
/// and parsing over lines keeps that structure visible in the code.
public struct SourceLine: Hashable, Sendable {
    /// The line's text, without its terminator.
    public let text: String
    /// The range the text occupies, excluding the terminator.
    public let range: SourceRange
    /// One-based line number.
    public let number: Int

    public init(text: String, range: SourceRange, number: Int) {
        self.text = text
        self.range = range
        self.number = number
    }

    /// The text with leading and trailing whitespace removed. Most block
    /// markers are recognised against this rather than the raw text.
    public var trimmed: Substring {
        var slice = text[...]
        while let first = slice.first, first == " " || first == "\t" {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == " " || last == "\t" {
            slice = slice.dropLast()
        }
        return slice
    }

    public var isBlank: Bool {
        trimmed.isEmpty
    }
}

public enum LineReader {
    /// Splits a document into lines, tracking positions as it goes.
    ///
    /// A document ending in a newline does not produce a trailing empty line;
    /// one that does not end in a newline still yields its last line. Both
    /// matter for round-tripping.
    ///
    /// The walk is over unicode scalars, not characters: Swift treats `\r\n` as
    /// a single grapheme, so splitting on the `"\n"` character would not split
    /// CRLF documents at all. The carriage return is normalised away; ranges
    /// cover the text without it.
    public static func lines(of source: String) -> [SourceLine] {
        var result: [SourceLine] = []
        var text = ""
        var lineStart = 0
        var offset = 0
        var number = 1

        func close() {
            if text.hasSuffix("\r") {
                text.removeLast()
            }
            let length = text.utf16.count
            result.append(
                SourceLine(
                    text: text,
                    range: SourceRange(
                        start: SourceLocation(offset: lineStart, line: number, column: 1),
                        end: SourceLocation(
                            offset: lineStart + length,
                            line: number,
                            column: length + 1
                        )
                    ),
                    number: number
                )
            )
            text = ""
            number += 1
        }

        for scalar in source.unicodeScalars {
            if scalar == "\n" {
                close()
                offset += 1
                lineStart = offset
            } else {
                text.unicodeScalars.append(scalar)
                offset += UTF16.width(scalar)
            }
        }

        if offset > lineStart {
            close()
        }

        return result
    }
}
