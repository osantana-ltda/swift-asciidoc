// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// Builds rows and cells from the content of a `|===` table.
///
/// The rules here were established by probing Asciidoctor rather than assumed,
/// since the specification has not reached tables:
///
/// - The column count comes from the `cols` attribute when present, otherwise
///   from the number of cells on the first line.
/// - Cells from all lines pool together and are grouped into rows of that
///   count; a line holding one cell and a line holding four are the same to
///   the grouping.
/// - The first row becomes the head when the `header` option is set, and also
///   when the first line is followed by a blank line.
/// - A line with no `|` continues the previous cell.
///
/// Cell specifiers (`2+|`, `a|`, alignments) and the csv/dsv flavours are not
/// interpreted yet; a specifier stays as part of the cell's text.
enum TableParser {
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

        var rows: [Block] = []
        var index = 0
        var isHeader = headerByOption || headerByBlank

        while index < all.count {
            let slice = Array(all[index..<min(index + columns, all.count)])
            rows.append(
                Block(
                    kind: .tableRow(header: isHeader),
                    range: slice.dropFirst().reduce(slice[0].range) { $0.union($1.range) },
                    blocks: slice
                )
            )
            isHeader = false
            index += columns
        }

        return rows
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

    /// Splits one line into cell blocks on unescaped `|`, locating each cell's
    /// trimmed text exactly. Text before the first `|` is not a cell — the
    /// caller treats the line as continuing the previous one.
    private static func cells(of line: SourceLine) -> [Block] {
        var cells: [Block] = []
        var text = ""
        // Column (1-based, UTF-16) where the current cell's raw text begins.
        var start = 1
        var column = 1
        var insideCell = false
        var escaped = false

        func close() {
            guard insideCell else {
                return
            }
            cells.append(cell(text, in: line, startColumn: start))
        }

        for character in line.text {
            let width = String(character).utf16.count
            if escaped {
                text.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                close()
                insideCell = true
                text = ""
                start = column + width
            } else {
                text.append(character)
            }
            column += width
        }
        close()

        return cells
    }

    private static func cell(_ raw: String, in line: SourceLine, startColumn: Int) -> Block {
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
            lines: [SourceLine(text: text, range: range, number: line.number)]
        )
    }

    private static func extend(_ cell: Block, with line: SourceLine) -> Block {
        let trimmedText = String(line.trimmed)
        let continuation = SourceLine(text: trimmedText, range: line.range, number: line.number)

        return Block(
            kind: cell.kind,
            range: cell.range.union(line.range),
            blocks: cell.blocks,
            lines: cell.lines + [continuation]
        )
    }
}
