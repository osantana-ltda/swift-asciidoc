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
/// Macros (`link:`, `xref:`, `image:`, footnotes), bare URLs, attribute
/// references (`{name}`), inline anchors (`[[id]]`) and attribute lists bound
/// to a span (`[#id]#text#`) are all modelled. Anything that does not parse
/// stays text — the passthrough guarantee, never an error.
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

    /// The macro names recognised, the way Asciidoctor recognises only its
    /// registered macros: an unknown `name:target[...]` stays text, which is
    /// what keeps `ratio:3[citation-style]` prose from becoming markup.
    private static let macroNames: Set<String> = [
        "link", "mailto", "xref", "image", "icon", "kbd", "btn", "menu",
        "footnote", "pass", "stem", "latexmath", "asciimath", "anchor",
    ]

    private static let urlSchemes = ["https://", "http://", "ftp://", "irc://"]

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

            // An escaped markup character — a span delimiter, or the start of
            // something that would otherwise parse as a macro — is text. A
            // backslash before anything else is an ordinary backslash, so
            // `C:\name` keeps it.
            if current.character == "\\", index + 1 < characters.endIndex {
                let next = characters[index + 1]
                let escapesMacro =
                    matchXref(in: characters, at: index + 1) != nil
                    || matchURL(in: characters, at: index + 1) != nil
                    || matchMacro(in: characters, at: index + 1) != nil
                    || matchAttributeReference(in: characters, at: index + 1) != nil
                    || matchAnchor(in: characters, at: index + 1) != nil
                    || matchAttributedSpan(in: characters, at: index + 1) != nil

                if variants.keys.contains(next.character) || escapesMacro {
                    appendText(next)
                    index += 2
                    continue
                }
            }

            if current.character == "{",
                let match = matchAttributeReference(in: characters, at: index)
            {
                flushText()
                inlines.append(.attributeReference(name: match.name, range: match.range))
                index = match.next
                continue
            }

            if current.character == "[", let match = matchAnchor(in: characters, at: index) {
                flushText()
                inlines.append(
                    .anchor(id: match.id, reftext: match.reftext, range: match.range))
                index = match.next
                continue
            }

            if current.character == "[", let match = matchAttributedSpan(in: characters, at: index)
            {
                flushText()
                inlines.append(.span(match.span))
                index = match.next
                continue
            }

            if current.character == "<", let match = matchXref(in: characters, at: index) {
                flushText()
                inlines.append(.macro(match.macro))
                index = match.next
                continue
            }

            if current.character.isLetter,
                index == characters.startIndex || !isWord(characters[index - 1].character),
                let match = matchURL(in: characters, at: index)
                    ?? matchMacro(in: characters, at: index)
            {
                flushText()
                inlines.append(.macro(match.macro))
                index = match.next
                continue
            }

            guard variants[current.character] != nil,
                let match = matchSpan(in: characters, at: index, from: index)
            else {
                // Not a span here; the delimiter is just a character.
                appendText(current)
                index += 1
                continue
            }

            flushText()
            inlines.append(.span(match.span))
            index = match.next
        }

        flushText()
        return inlines
    }

    // MARK: - Spans

    private struct SpanMatch {
        let span: Inline.Span
        let next: Int
    }

    /// A formatting span opening at `index`. `start` is where the whole
    /// construct begins — the `[` of an attribute list when one precedes the
    /// delimiter — so the range covers that too.
    private static func matchSpan(
        in characters: ArraySlice<Positioned>,
        at index: Int,
        from start: Int,
        attributes: BlockAttributes = BlockAttributes()
    ) -> SpanMatch? {
        guard index < characters.endIndex,
            let variant = variants[characters[index].character]
        else {
            return nil
        }

        let delimiter = characters[index].character
        let doubled =
            !singleOnly.contains(delimiter)
            && index + 1 < characters.endIndex
            && characters[index + 1].character == delimiter

        if doubled, let close = closingPair(of: delimiter, in: characters, after: index + 2) {
            return SpanMatch(
                span: Inline.Span(
                    variant: variant,
                    form: .unconstrained,
                    inlines: parse(characters[(index + 2)..<close]),
                    range: SourceRange(
                        start: characters[start].location,
                        end: characters[close + 1].end
                    ),
                    attributes: attributes
                ),
                next: close + 2
            )
        }

        guard canOpenConstrained(delimiter, in: characters, at: index),
            let close = closingSingle(of: delimiter, in: characters, after: index + 1)
        else {
            return nil
        }

        return SpanMatch(
            span: Inline.Span(
                variant: variant,
                form: .constrained,
                inlines: parse(characters[(index + 1)..<close]),
                range: SourceRange(
                    start: characters[start].location,
                    end: characters[close].end
                ),
                attributes: attributes
            ),
            next: close + 1
        )
    }

    /// `[#id]#text#`, `[.role]*bold*` — an attribute list bound to the inline
    /// element written directly after it.
    ///
    /// Only the shorthand binds: an id, a role, or an option. A bracket pair
    /// holding anything else is prose — `[see figure]#5#` keeps its brackets —
    /// and the list must sit against the delimiter, with nothing between.
    private static func matchAttributedSpan(
        in characters: ArraySlice<Positioned>, at index: Int
    ) -> SpanMatch? {
        guard index < characters.endIndex, characters[index].character == "[",
            let list = attributeList(in: characters, openingAt: index)
        else {
            return nil
        }

        var attributes = BlockAttributes()
        AttributeListParser.parse(
            body: list.text, into: &attributes, firstPositionalIsStyle: false)

        guard attributes.id != nil || !attributes.roles.isEmpty || !attributes.options.isEmpty
        else {
            return nil
        }
        return matchSpan(in: characters, at: list.end, from: index, attributes: attributes)
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

    // MARK: - Macros

    private struct MacroMatch {
        let macro: Inline.Macro
        let next: Int
    }

    /// `name:target[attrlist]`, for a known name at a word boundary.
    /// `[[id]]` or `[[id,reftext]]` — an inline anchor. Ids follow the same
    /// shape references use; a bracket pair holding anything else — a
    /// citation-looking `[[1]]` is fine, prose is not — stays text.
    private static func matchAnchor(
        in characters: ArraySlice<Positioned>, at index: Int
    ) -> (id: String, reftext: String, range: SourceRange, next: Int)? {
        guard matches("[[", in: characters, at: index) else {
            return nil
        }
        var cursor = index + 2
        var inner = ""

        while cursor + 1 < characters.endIndex {
            if characters[cursor].character == "]", characters[cursor + 1].character == "]" {
                let comma = inner.firstIndex(of: ",")
                let id = trimmed(comma.map { String(inner[inner.startIndex..<$0]) } ?? inner)
                let reftext = trimmed(
                    comma.map { String(inner[inner.index(after: $0)...]) } ?? "")
                guard !id.isEmpty, id.allSatisfy(isIdentifier) else {
                    return nil
                }
                return (
                    id, reftext,
                    SourceRange(
                        start: characters[index].location,
                        end: characters[cursor + 1].end
                    ),
                    cursor + 2
                )
            }
            // An anchor never spans lines.
            guard characters[cursor].character != "\n" else {
                return nil
            }
            inner.append(characters[cursor].character)
            cursor += 1
        }
        return nil
    }

    /// The characters an id may hold: the same set attribute names use, plus
    /// the period and colon AsciiDoc allows inside ids.
    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
            || character == "." || character == ":"
    }

    /// `{name}` — an attribute reference. Names follow AsciiDoc's rules:
    /// they start with a letter, digit or underscore and continue with those
    /// plus hyphens; anything else (a brace in prose, `{ x }`) is ordinary
    /// text.
    private static func matchAttributeReference(
        in characters: ArraySlice<Positioned>, at index: Int
    ) -> (name: String, range: SourceRange, next: Int)? {
        guard index < characters.endIndex, characters[index].character == "{" else {
            return nil
        }
        var cursor = index + 1
        var name = ""
        while cursor < characters.endIndex {
            let character = characters[cursor].character
            if character == "}" {
                guard !name.isEmpty else {
                    return nil
                }
                return (
                    name,
                    SourceRange(
                        start: characters[index].location,
                        end: characters[cursor].end
                    ),
                    cursor + 1
                )
            }
            let valid =
                character.isLetter || character.isNumber || character == "_"
                || (!name.isEmpty && character == "-")
            guard valid else {
                return nil
            }
            name.append(character)
            cursor += 1
        }
        return nil
    }

    private static func matchMacro(
        in characters: ArraySlice<Positioned>,
        at index: Int
    ) -> MacroMatch? {
        var cursor = index
        var name = ""

        while cursor < characters.endIndex {
            let character = characters[cursor].character
            guard character.isLetter || character.isNumber || character == "-" else {
                break
            }
            name.append(character)
            cursor += 1
        }

        guard cursor < characters.endIndex, characters[cursor].character == ":",
            macroNames.contains(name)
        else {
            return nil
        }
        cursor += 1

        var target = ""
        while cursor < characters.endIndex {
            let character = characters[cursor].character
            guard !isSpace(character), character != "[" else {
                break
            }
            target.append(character)
            cursor += 1
        }

        guard cursor < characters.endIndex, characters[cursor].character == "[",
            let list = attributeList(in: characters, openingAt: cursor)
        else {
            return nil
        }

        return MacroMatch(
            macro: Inline.Macro(
                name: name,
                target: target,
                attributes: list.text,
                range: SourceRange(
                    start: characters[index].location,
                    end: characters[list.end - 1].end
                )
            ),
            next: list.end
        )
    }

    /// A bare URL, with or without `[text]`, normalised to a `link` macro.
    /// Trailing punctuation stays outside the link, so a sentence ending in a
    /// URL does not link its own full stop.
    private static func matchURL(
        in characters: ArraySlice<Positioned>,
        at index: Int
    ) -> MacroMatch? {
        guard
            let scheme = urlSchemes.first(where: { matches($0, in: characters, at: index) })
        else {
            return nil
        }

        var cursor = index + scheme.count
        var url = scheme

        while cursor < characters.endIndex {
            let character = characters[cursor].character
            guard !isSpace(character), character != "[", character != "]",
                character != "<", character != ">"
            else {
                break
            }
            url.append(character)
            cursor += 1
        }

        while let last = url.last, ".,;:!?".contains(last) {
            url.removeLast()
            cursor -= 1
        }

        guard url.count > scheme.count else {
            return nil
        }

        var attributes = ""
        var next = cursor
        if cursor < characters.endIndex, characters[cursor].character == "[",
            let list = attributeList(in: characters, openingAt: cursor)
        {
            attributes = list.text
            next = list.end
        }

        return MacroMatch(
            macro: Inline.Macro(
                name: "link",
                target: url,
                attributes: attributes,
                range: SourceRange(
                    start: characters[index].location,
                    end: characters[next - 1].end
                )
            ),
            next: next
        )
    }

    /// `<<target>>` or `<<target,text>>`, normalised to an `xref` macro.
    private static func matchXref(
        in characters: ArraySlice<Positioned>,
        at index: Int
    ) -> MacroMatch? {
        guard matches("<<", in: characters, at: index) else {
            return nil
        }

        var cursor = index + 2
        var inner = ""

        while cursor + 1 < characters.endIndex {
            if characters[cursor].character == ">", characters[cursor + 1].character == ">" {
                let comma = inner.firstIndex(of: ",")
                let target = comma.map { String(inner[inner.startIndex..<$0]) } ?? inner
                let text = comma.map { String(inner[inner.index(after: $0)...]) } ?? ""

                return MacroMatch(
                    macro: Inline.Macro(
                        name: "xref",
                        target: trimmed(target),
                        attributes: trimmed(text),
                        range: SourceRange(
                            start: characters[index].location,
                            end: characters[cursor + 1].end
                        )
                    ),
                    next: cursor + 2
                )
            }
            inner.append(characters[cursor].character)
            cursor += 1
        }

        return nil
    }

    /// The raw text between `[` and an unescaped `]`, and the index after the
    /// bracket.
    private static func attributeList(
        in characters: ArraySlice<Positioned>,
        openingAt open: Int
    ) -> (text: String, end: Int)? {
        var cursor = open + 1
        var text = ""

        while cursor < characters.endIndex {
            let character = characters[cursor].character
            if character == "\\", cursor + 1 < characters.endIndex,
                characters[cursor + 1].character == "]"
            {
                text.append("]")
                cursor += 2
                continue
            }
            if character == "]" {
                return (text, cursor + 1)
            }
            text.append(character)
            cursor += 1
        }

        return nil
    }

    private static func matches(
        _ literal: String,
        in characters: ArraySlice<Positioned>,
        at index: Int
    ) -> Bool {
        var cursor = index
        for character in literal {
            guard cursor < characters.endIndex, characters[cursor].character == character else {
                return false
            }
            cursor += 1
        }
        return true
    }

    private static func trimmed(_ text: String) -> String {
        var slice = text[...]
        while slice.first == " " { slice = slice.dropFirst() }
        while slice.last == " " { slice = slice.dropLast() }
        return String(slice)
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
