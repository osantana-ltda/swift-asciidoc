// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import AsciiDoc

// MARK: - Harness

private func apply(_ edit: SourceEdit, to source: String) -> String {
    let units = Array(source.utf16)
    let new =
        units[..<edit.start] + Array(edit.replacement.utf16)
        + units[(edit.start + edit.length)...]
    return String(decoding: new, as: UTF16.self)
}

/// The contract: the incremental result must equal the full parse of the
/// edited source — structurally, positionally, and in its retained lines.
private func assertMatchesFullParse(
    _ source: String,
    _ edit: SourceEdit,
    _ note: Comment? = nil
) -> IncrementalParser.Result {
    let previous = Parser.parse(source)
    let result = IncrementalParser.reparse(previous, applying: edit)
    let expected = Parser.parse(apply(edit, to: source))

    #expect(result.document == expected, note)
    return result
}

// MARK: - Sources for the edit matrix

private let matrixSources: [String] = [
    "One paragraph only.\n",
    "First paragraph.\n\nSecond paragraph.\n\nThird one\nthat wraps.\n",
    "= Title\nAuthor Here\n:toc: left\n\npreamble\n\n== One\n\nAlpha.\n\nBeta gamma.\n\n=== Deep\n\nDelta.\n\n== Two\n\nEpsilon.\n",
    "== Section\n\n[source,swift]\n----\nlet x = 1\nlet y = 2\n----\n\nAfter.\n",
    "* one\n* two\n\n____\nquoted\n____\n\nTIP: an admonition\n\n|===\n| a | b\n| c | d\n|===\n",
    "[[anchor]]\n.Titled\n[quote]\nStyled paragraph.\n\n// comment\n\nplain\n",
    "text 😀 with *bold* emoji\n\nmore 😀 text\n",
]

/// Every position that does not split a surrogate pair, at a stride.
private func editPositions(in source: String, stride: Int) -> [Int] {
    let units = Array(source.utf16)
    var positions: [Int] = []
    var offset = 0
    while offset <= units.count {
        let splitsPair = offset < units.count && (0xDC00...0xDFFF).contains(units[offset])
        if !splitsPair {
            positions.append(offset)
        }
        offset += stride
    }
    return positions
}

private func safeLength(_ length: Int, at offset: Int, in source: String) -> Int {
    let units = Array(source.utf16)
    var end = min(offset + length, units.count)
    if end < units.count, (0xDC00...0xDFFF).contains(units[end]) {
        end += 1
    }
    return end - offset
}

// MARK: - The matrix

@Test(arguments: matrixSources.indices)
func everyEditMatchesTheFullParse(_ sourceIndex: Int) {
    let source = matrixSources[sourceIndex]
    let insertions = ["x", "\n", "\n\n", "----\n", "== H\n", "* ", "[NOTE]\n", "|"]

    for start in editPositions(in: source, stride: 3) {
        for insertion in insertions {
            _ = assertMatchesFullParse(
                source,
                SourceEdit(start: start, length: 0, replacement: insertion),
                "insert \(insertion.debugDescription) at \(start) in source #\(sourceIndex)"
            )
        }

        for length in [1, 4] where start < source.utf16.count {
            let safe = safeLength(length, at: start, in: source)
            _ = assertMatchesFullParse(
                source,
                SourceEdit(start: start, length: safe, replacement: ""),
                "delete \(safe) at \(start) in source #\(sourceIndex)"
            )
            _ = assertMatchesFullParse(
                source,
                SourceEdit(start: start, length: safe, replacement: "ab\ncd"),
                "replace \(safe) at \(start) in source #\(sourceIndex)"
            )
        }
    }
}

@Test func wholeDocumentReplacementMatches() {
    let source = matrixSources[2]
    _ = assertMatchesFullParse(
        source,
        SourceEdit(start: 0, length: source.utf16.count, replacement: "= New\n\nBody.\n")
    )
    _ = assertMatchesFullParse(
        source,
        SourceEdit(start: 0, length: source.utf16.count, replacement: "")
    )
}

@Test func editsOnAnEmptyDocumentMatch() {
    _ = assertMatchesFullParse("", SourceEdit(start: 0, length: 0, replacement: "hello\n"))
    _ = assertMatchesFullParse("", SourceEdit(start: 0, length: 0, replacement: ""))
}

@Test func editsAroundTheFinalNewlineMatch() {
    _ = assertMatchesFullParse("a\n", SourceEdit(start: 2, length: 0, replacement: "b"))
    _ = assertMatchesFullParse("a\n", SourceEdit(start: 1, length: 1, replacement: ""))
    _ = assertMatchesFullParse("a", SourceEdit(start: 1, length: 0, replacement: "\n"))
    _ = assertMatchesFullParse("a\n\nb", SourceEdit(start: 3, length: 1, replacement: ""))
}

// MARK: - The bounded paths actually engage

private let chapter = """
    = Chapter
    :toc: left

    A preamble paragraph for the chapter.

    == First Section

    Alpha paragraph with some prose in it.

    Beta paragraph, also prose.

    == Second Section

    Gamma paragraph sits here.

    [source,swift]
    ----
    let value = 42
    ----

    Delta closes the chapter.
    """

@Test func typingInAParagraphIsIncremental() {
    // Inside "Beta paragraph".
    let offset = (chapter as NSString).range(of: "Beta").location + 2
    let result = assertMatchesFullParse(
        chapter,
        SourceEdit(start: offset, length: 0, replacement: "x")
    )

    #expect(result.incremental)
    #expect(result.reparsedLines.count <= 3)
}

@Test func pressingEnterInAGapIsShiftOnly() {
    // The blank line between the two Alpha/Beta paragraphs.
    let offset = (chapter as NSString).range(of: "\n\nBeta").location + 1
    let result = assertMatchesFullParse(
        chapter,
        SourceEdit(start: offset, length: 0, replacement: "\n")
    )

    #expect(result.incremental)
    #expect(result.reparsedLines.isEmpty)
}

@Test func editingInsideAListingIsIncremental() {
    let offset = (chapter as NSString).range(of: "42").location
    let result = assertMatchesFullParse(
        chapter,
        SourceEdit(start: offset, length: 2, replacement: "99")
    )

    #expect(result.incremental)
}

@Test func editingAHeadingFallsBackToAFullParse() {
    let offset = (chapter as NSString).range(of: "First").location
    let result = assertMatchesFullParse(
        chapter,
        SourceEdit(start: offset, length: 0, replacement: "x")
    )

    #expect(!result.incremental)
}

@Test func openingADelimiterFallsBackToAFullParse() {
    let offset = (chapter as NSString).range(of: "Gamma").location
    let result = assertMatchesFullParse(
        chapter,
        SourceEdit(start: offset, length: 0, replacement: "----\n")
    )

    #expect(!result.incremental)
}

@Test func editingTheHeaderFallsBackToAFullParse() {
    let offset = (chapter as NSString).range(of: ":toc:").location
    let result = assertMatchesFullParse(
        chapter,
        SourceEdit(start: offset + 1, length: 0, replacement: "x")
    )

    #expect(!result.incremental)
}

@Test func mergingTwoParagraphsMatches() {
    // Delete the blank line between Alpha and Beta, merging them.
    let gap = (chapter as NSString).range(of: "it.\n\nBeta")
    _ = assertMatchesFullParse(
        chapter, SourceEdit(start: gap.location + 4, length: 1, replacement: ""))
}

@Test func splittingAParagraphIsIncremental() {
    let offset = (chapter as NSString).range(of: "with some").location
    let result = assertMatchesFullParse(
        chapter,
        SourceEdit(start: offset, length: 0, replacement: "\n\n")
    )

    #expect(result.incremental)
}
