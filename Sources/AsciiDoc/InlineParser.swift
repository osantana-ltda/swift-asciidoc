// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// Parses the inline syntax inside a block's text: formatting spans, nested,
/// with escapes.
///
/// AsciiDoc distinguishes **constrained** spans (`*strong*`, single delimiters,
/// valid only at word boundaries) from **unconstrained** ones (`**strong**`,
/// doubled, valid anywhere — `un**frea**king**believable**` works). A delimiter
/// that cannot open or close a span is ordinary text, never an error.
///
/// Macros (`link:`, `xref:`, `image:`, footnotes), attribute references
/// (`{name}`) and inline anchors are not parsed yet; their syntax passes
/// through as text.
public enum InlineParser {
    /// Parses the inline content of the given lines, which are joined by
    /// newlines the way they appear in the source. Positions in the result are
    /// exact source positions.
    public static func parse(_ lines: [SourceLine]) -> [Inline] {
        let characters = flatten(lines)
        return parse(characters[...])
    }

    // MARK: - Character stream

    /// One character with its exact source position.
    struct Positioned {
        let character: Character
        let location: SourceLocation
        /// UTF-16 width, for advancing offsets.
        let width: Int

        var end: SourceLocation {
            SourceLocation(
                offset: location.offset + width,
                line: location.line,
                column: location.column + width
            )
        }
    }

    /// The lines as one character stream, with a newline between each pair —
    /// the newline really is there in the source, at the line's end offset.
    private static func flatten(_ lines: [SourceLine]) -> [Positioned] {
        var characters: [Positioned] = []

        for (index, line) in lines.enumerated() {
            var offset = line.range.start.offset
            var column = line.range.start.column

            for character in line.text {
                let width = String(character).utf16.count
                characters.append(
                    Positioned(
                        character: character,
                        location: SourceLocation(
                            offset: offset,
                            line: line.number,
                            column: column
                        ),
                        width: width
                    )
                )
                offset += width
                column += width
            }

            if index < lines.count - 1 {
                characters.append(
                    Positioned(
                        character: "\n",
                        location: line.range.end,
                        width: 1
                    )
                )
            }
        }

        return characters
    }

    // MARK: - Parsing

    private static let variants: [Character: Inline.Span.Variant] = [
        "*": .strong,
        "_": .emphasis,
        "`": .code,
        "#": .mark,
        "^": .superscriptText,
        "~": .subscriptText,
    ]

    /// `^` and `~` have no doubled form and take no spaces in their content.
    private static let singleOnly: Set<Character> = ["^", "~"]

    private static func parse(_ characters: ArraySlice<Positioned>) -> [Inline] {
        var inlines: [Inline] = []
        var text = ""
        var textStart: SourceLocation?
        var textEnd: SourceLocation?
        var index = characters.startIndex

        func flushText() {
            guard let start = textStart, let end = textEnd, !text.isEmpty else {
                return
            }
            inlines.append(.text(value: text, range: SourceRange(start: start, end: end)))
            text = ""
            textStart = nil
            textEnd = nil
        }

        func appendText(_ positioned: Positioned) {
            text.append(positioned.character)
            textStart = textStart ?? positioned.location
            textEnd = positioned.end
        }

        while index < characters.endIndex {
            let current = characters[index]

            // An escaped markup character is that character, as text.
            if current.character == "\\", index + 1 < characters.endIndex,
                variants.keys.contains(characters[index + 1].character)
            {
                appendText(characters[index + 1])
                index += 2
                continue
            }

            guard let variant = variants[current.character] else {
                appendText(current)
                index += 1
                continue
            }

            let delimiter = current.character
            let doubled =
                !singleOnly.contains(delimiter)
                && index + 1 < characters.endIndex
                && characters[index + 1].character == delimiter

            if doubled, let close = closingPair(of: delimiter, in: characters, after: index + 2) {
                flushText()
                inlines.append(
                    .span(
                        Inline.Span(
                            variant: variant,
                            form: .unconstrained,
                            inlines: parse(characters[(index + 2)..<close]),
                            range: SourceRange(
                                start: current.location,
                                end: characters[close + 1].end
                            )
                        )
                    )
                )
                index = close + 2
                continue
            }

            if canOpenConstrained(delimiter, in: characters, at: index),
                let close = closingSingle(of: delimiter, in: characters, after: index + 1)
            {
                flushText()
                inlines.append(
                    .span(
                        Inline.Span(
                            variant: variant,
                            form: .constrained,
                            inlines: parse(characters[(index + 1)..<close]),
                            range: SourceRange(
                                start: current.location,
                                end: characters[close].end
                            )
                        )
                    )
                )
                index = close + 1
                continue
            }

            // Not a span here; the delimiter is just a character.
            appendText(current)
            index += 1
        }

        flushText()
        return inlines
    }

    // MARK: - Delimiter rules

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n"
    }

    /// A constrained span opens only at a word boundary, and not before a
    /// space. Superscript and subscript are the exception: `x^2^` works
    /// mid-word, which is their entire reason to exist.
    private static func canOpenConstrained(
        _ delimiter: Character,
        in characters: ArraySlice<Positioned>,
        at index: Int
    ) -> Bool {
        if !singleOnly.contains(delimiter),
            index > characters.startIndex,
            isWord(characters[index - 1].character)
        {
            return false
        }
        guard index + 1 < characters.endIndex else {
            return false
        }
        return !isSpace(characters[index + 1].character)
    }

    /// The closing delimiter of a constrained span: not after a space, and at a
    /// word boundary. For `^` and `~`, no space may appear on the way.
    private static func closingSingle(
        of delimiter: Character,
        in characters: ArraySlice<Positioned>,
        after start: Int
    ) -> Int? {
        var index = start

        while index < characters.endIndex {
            let character = characters[index].character

            if character == "\\" {
                index += 2
                continue
            }

            if singleOnly.contains(delimiter), isSpace(character) {
                return nil
            }

            if character == delimiter, index > start {
                // Superscript and subscript close at the next delimiter; the
                // others close only at a word boundary, never after a space.
                if singleOnly.contains(delimiter) {
                    return index
                }
                if !isSpace(characters[index - 1].character),
                    index + 1 == characters.endIndex
                        || !isWord(characters[index + 1].character)
                {
                    return index
                }
            }

            index += 1
        }

        return nil
    }

    /// The closing pair of an unconstrained span.
    private static func closingPair(
        of delimiter: Character,
        in characters: ArraySlice<Positioned>,
        after start: Int
    ) -> Int? {
        var index = start

        while index + 1 < characters.endIndex {
            if characters[index].character == "\\" {
                index += 2
                continue
            }
            if characters[index].character == delimiter,
                characters[index + 1].character == delimiter,
                index > start
            {
                return index
            }
            index += 1
        }

        return nil
    }
}
