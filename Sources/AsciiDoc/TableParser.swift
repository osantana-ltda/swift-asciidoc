// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// Builds rows and cells from the content of a `|===` table.
///
/// The rules here were established by probing Asciidoctor rather than assumed,
/// since the specification has not reached tables:
///
/// - The column count comes from the `cols` attribute when present, otherwise
///   from the number of cells on the first line.
/// - Cells from all lines pool together and are laid into a grid of that
///   width; a line holding one cell and a line holding four are the same to
///   the layout.
/// - The first row becomes the head when the `header` option is set, and also
///   when the first line is followed by a blank line.
/// - A line with no `|` continues the previous cell.
///
/// Cell specifiers — `2+|` to span columns, `.3+|` to span rows, `3*|` to
/// repeat a cell, `a|` and its siblings to set a style, `<|` `^|` `>|` to
/// align — are read into the cell's attributes, where the renderer acts on
/// them. Spans lay the grid out: a cell that spans two columns consumes two,
/// and a cell that spans two rows keeps its columns occupied in the next.
///
/// The csv and dsv table flavours are still not interpreted.
enum TableParser {
    /// Where a parsed specifier lands on the cell's attributes. The style
    /// letter uses `attributes.style`, which is what that field means.
    enum AttributeKey {
        public static let colspan = "colspan"
        public static let rowspan = "rowspan"
        public static let horizontalAlign = "halign"
        public static let verticalAlign = "valign"
    }

    static func rows(of lines: [SourceLine], attributes: BlockAttributes) -> [Block] {
        let content = lines.drop { $0.isBlank }
        guard let first = content.first else {
            return []
        }

        let columns =
            attributes.named["cols"].map(columnCount(from:))
            ?? max(cells(of: first).count, 1)

        let headerByOption = attributes.options.contains("header")
        let headerByBlank = content.dropFirst().first?.isBlank ?? false

        var all: [Block] = []
        for line in content {
            if line.isBlank {
                continue
            }

            let segments = cells(of: line)
            if segments.isEmpty {
                // No marker at all: the line continues the previous cell.
                if let last = all.last {
                    all[all.count - 1] = extend(last, with: line)
                }
                continue
            }
            all += segments
        }

        return grid(of: all, columns: columns, header: headerByOption || headerByBlank)
    }

    /// Lays the pooled cells into rows, honouring spans: a cell claims
    /// `colspan` columns of its row, and keeps them occupied for `rowspan - 1`
    /// rows after it.
    private static func grid(of cells: [Block], columns: Int, header: Bool) -> [Block] {
        var rows: [Block] = []
        var occupied = [Int](repeating: 0, count: columns)
        var index = 0
        var isHeader = header

        while index < cells.count {
            var rowCells: [Block] = []
            var column = 0

            while column < columns {
                if occupied[column] > 0 {
                    occupied[column] -= 1
                    column += 1
                    continue
                }
                guard index < cells.count else {
                    break
                }
                let cell = cells[index]
                index += 1
                rowCells.append(cell)

                let spanned = span(of: cell, key: AttributeKey.colspan)
                let rowsSpanned = span(of: cell, key: AttributeKey.rowspan)
                for claimed in column..<min(column + spanned, columns) {
                    occupied[claimed] = max(occupied[claimed], rowsSpanned - 1)
                }
                column += spanned
            }

            guard !rowCells.isEmpty else {
                break
            }

            rows.append(
                Block(
                    kind: .tableRow(header: isHeader),
                    range: rowCells.dropFirst().reduce(rowCells[0].range) {
                        $0.union($1.range)
                    },
                    blocks: rowCells
                )
            )
            isHeader = false
        }

        return rows
    }

    private static func span(of cell: Block, key: String) -> Int {
        max(cell.attributes.named[key].flatMap(Int.init) ?? 1, 1)
    }

    /// `1,2,3` is three columns; `3*` is three columns; anything else counts
    /// one per comma-separated entry.
    static func columnCount(from cols: String) -> Int {
        var count = 0
        for specifier in cols.split(separator: ",") {
            let trimmed = specifier.drop { $0 == " " }
            if let star = trimmed.firstIndex(of: "*"),
                let repeats = Int(trimmed[trimmed.startIndex..<star])
            {
                count += max(repeats, 1)
            } else {
                count += 1
            }
        }
        return max(count, 1)
    }

    // MARK: - Cell specifiers

    /// A cell specifier, as written directly before the `|` it belongs to.
    struct CellSpec: Equatable {
        var repeatCount = 1
        var colspan = 1
        var rowspan = 1
        var horizontal: String?
        var vertical: String?
        var style: String?

        var isEmpty: Bool {
            self == CellSpec()
        }

        var attributes: BlockAttributes {
            var named: [String: String] = [:]
            if colspan > 1 {
                named[AttributeKey.colspan] = String(colspan)
            }
            if rowspan > 1 {
                named[AttributeKey.rowspan] = String(rowspan)
            }
            if let horizontal {
                named[AttributeKey.horizontalAlign] = horizontal
            }
            if let vertical {
                named[AttributeKey.verticalAlign] = vertical
            }
            return BlockAttributes(style: style, named: named)
        }
    }

    /// Reads a specifier token — the whitespace-delimited run written
    /// immediately before a `|`. Nil when the token is ordinary cell text,
    /// which is the common case and must stay cheap to conclude.
    ///
    /// Grammar, every part optional but the order fixed:
    /// `[repeat*]` or `[colspan[.rowspan]+]`, then `[<^>]` horizontal, then
    /// `[.<^>]` vertical, then one style letter.
    static func specifier(_ token: some StringProtocol) -> CellSpec? {
        let characters = Array(token)
        guard !characters.isEmpty else {
            return nil
        }

        var index = 0
        var spec = CellSpec()

        func digits() -> Int? {
            let start = index
            while index < characters.count, characters[index].isNumber {
                index += 1
            }
            guard index > start else {
                return nil
            }
            return Int(String(characters[start..<index]))
        }

        // [repeat*] or [colspan[.rowspan]+]
        let leading = digits()
        var rowsSpanned: Int?
        if index < characters.count, characters[index] == "." {
            let mark = index
            index += 1
            rowsSpanned = digits()
            if rowsSpanned == nil {
                // A lone dot belongs to the vertical alignment below.
                index = mark
            }
        }
        if index < characters.count, characters[index] == "*" || characters[index] == "+" {
            if characters[index] == "*" {
                spec.repeatCount = max(leading ?? 1, 1)
            } else {
                spec.colspan = max(leading ?? 1, 1)
                spec.rowspan = max(rowsSpanned ?? 1, 1)
            }
            index += 1
        } else if leading != nil || rowsSpanned != nil {
            // Digits with no span marker: ordinary text, not a specifier.
            return nil
        }

        if index < characters.count, let align = alignment(characters[index]) {
            spec.horizontal = align
            index += 1
        }
        if index + 1 < characters.count, characters[index] == ".",
            let align = alignment(characters[index + 1])
        {
            spec.vertical = align
            index += 2
        }
        if index < characters.count, styles.contains(characters[index]) {
            spec.style = String(characters[index])
            index += 1
        }

        // Anything left over means this was never a specifier.
        guard index == characters.count, !spec.isEmpty else {
            return nil
        }
        return spec
    }

    private static let styles: Set<Character> = ["a", "d", "e", "h", "l", "m", "s", "v"]

    private static func alignment(_ character: Character) -> String? {
        switch character {
        case "<": return "left"
        case "^": return "center"
        case ">": return "right"
        default: return nil
        }
    }

    /// Splits the trailing specifier off a cell's raw text. A specifier sits
    /// directly against the `|` that follows it and is separated from the
    /// cell's own words by whitespace, so ordinary prose ending in a letter —
    /// `| item a | next` — keeps its text.
    private static func splitSpecifier(from raw: String) -> (text: String, spec: CellSpec?) {
        guard let last = raw.last, last != " ", last != "\t" else {
            return (raw, nil)
        }
        let tokenStart =
            raw.lastIndex(where: { $0 == " " || $0 == "\t" })
            .map { raw.index(after: $0) } ?? raw.startIndex
        guard let spec = specifier(raw[tokenStart...]) else {
            return (raw, nil)
        }
        return (String(raw[raw.startIndex..<tokenStart]), spec)
    }

    // MARK: - Splitting

    /// Splits one line into cell blocks on unescaped `|`, locating each cell's
    /// trimmed text exactly. Text before the first `|` is not a cell — the
    /// caller treats the line as continuing the previous one — but it may be
    /// the first cell's specifier.
    private static func cells(of line: SourceLine) -> [Block] {
        var cells: [Block] = []
        var text = ""
        // Column (1-based, UTF-16) where the current cell's raw text begins.
        var start = 1
        var column = 1
        var insideCell = false
        var escaped = false
        // The specifier read before the cell now being accumulated.
        var pending: CellSpec?

        /// `beforePipe` is what makes a specifier possible at all: one is
        /// written directly against the `|` it describes, so the text ending
        /// a line — `| c | d` — is always cell content, never a style letter.
        func close(beforePipe: Bool, nextSpec: inout CellSpec?) {
            let split = beforePipe ? splitSpecifier(from: text) : (text: text, spec: nil)
            nextSpec = split.spec
            guard insideCell else {
                return
            }
            // A segment holding nothing but a specifier — `| a | 2+| wide` —
            // is not a cell of its own: the specifier describes the cell
            // after it. A genuinely empty cell (`| a || b`) has no specifier
            // and still counts.
            if split.spec != nil, split.text.allSatisfy({ $0 == " " || $0 == "\t" }) {
                return
            }
            let built = cell(split.text, in: line, startColumn: start, spec: pending)
            cells += Array(repeating: built, count: max(pending?.repeatCount ?? 1, 1))
        }

        for character in line.text {
            let width = String(character).utf16.count
            if escaped {
                text.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                var next: CellSpec?
                close(beforePipe: true, nextSpec: &next)
                pending = next
                insideCell = true
                text = ""
                start = column + width
            } else {
                text.append(character)
            }
            column += width
        }
        var unused: CellSpec?
        close(beforePipe: false, nextSpec: &unused)

        return cells
    }

    private static func cell(
        _ raw: String, in line: SourceLine, startColumn: Int, spec: CellSpec?
    ) -> Block {
        let leading = raw.prefix { $0 == " " || $0 == "\t" }.count
        var text = String(raw.dropFirst(leading))
        while let last = text.last, last == " " || last == "\t" {
            text.removeLast()
        }

        let column = startColumn + leading
        let offset = line.range.start.offset + column - 1
        let range = SourceRange(
            start: SourceLocation(offset: offset, line: line.number, column: column),
            end: SourceLocation(
                offset: offset + text.utf16.count,
                line: line.number,
                column: column + text.utf16.count
            )
        )

        return Block(
            kind: .tableCell,
            range: range,
            attributes: spec?.attributes ?? BlockAttributes(),
            lines: [SourceLine(text: text, range: range, number: line.number)]
        )
    }

    private static func extend(_ cell: Block, with line: SourceLine) -> Block {
        let trimmedText = String(line.trimmed)
        let continuation = SourceLine(text: trimmedText, range: line.range, number: line.number)

        return Block(
            kind: cell.kind,
            range: cell.range.union(line.range),
            attributes: cell.attributes,
            blocks: cell.blocks,
            lines: cell.lines + [continuation]
        )
    }
}
