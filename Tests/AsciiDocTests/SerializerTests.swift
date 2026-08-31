// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import AsciiDoc

private func roundTrip(_ source: String) -> String {
    Serializer.serialize(Parser.parse(source))
}

// MARK: - Round-trip identity

/// One source per construct the parser understands, plus the awkward cases.
/// Byte identity, not resemblance.
private let roundTripSources: [String] = [
    // Plain paragraphs, wrapping, and blank-line gaps.
    "One line\nand another.",
    "First paragraph.\n\nSecond paragraph.\n",
    "Gap of three\n\n\n\nparagraphs apart.\n",
    // Header forms.
    "= Title\nAuthor Name <a@b.c>\n:toc: left\n:sectnums!:\n\nBody.\n",
    "= Just A Title\n\nBody.\n",
    ":attr: value\n:other: thing\n\nBody.\n",
    // Sections, nesting, preamble.
    "= T\n\npreamble\n\n== One\n\nAlpha.\n\n=== Deep\n\nBeta.\n\n== Two\n\nGamma.\n",
    // Delimited blocks, verbatim and compound, odd delimiter lengths.
    "[source,swift]\n----\nlet x = 1\n\n// kept verbatim\n----\n",
    "------\nlonger delimiter\n------\n",
    "____\nQuoted prose.\n\nMore.\n____\n",
    "====\nAn example.\n====\n",
    "****\nSidebar.\n****\n",
    "--\nOpen block.\n--\n",
    "++++\nraw <b>html</b>\n++++\n",
    "....\nliteral text\n....\n",
    // Unterminated stays unterminated.
    "----\nnever closed\n",
    // Styled paragraphs.
    "[source,sh]\nnpm ci\nnpm test\n",
    "[quote]\nA styled quote paragraph.\n",
    "[NOTE]\nStyled admonition, no label.\n",
    // Prefix admonitions.
    "TIP: An admonition, wrapped\nonto a second line.\n",
    "NOTE: Short.\n",
    // Markdown quote.
    "> Quoted the Markdown way,\n> across two lines.\n",
    // Metadata: anchors, titles, attribute lists, blank lines between them.
    "[[anchor]]\n.A Title\n[source,swift,linenums]\n----\ncode\n----\n",
    ".Titled paragraph\nBody of it.\n",
    "[quote#epigraph.lead%hardbreaks]\nStyled every which way.\n",
    // Comments.
    "// one\n// two\n\nText.\n",
    "////\nHidden block.\n////\n",
    // Lists.
    "* One\n* Two that wraps\n  onto another line\n* Three\n",
    ". First\n. Second\n",
    "1. Numbered\n2. Also numbered\n",
    // Tables, with and without header, cols, escaped pipes.
    "|===\n| a | b\n| c | d\n|===\n",
    "|===\n| h1 | h2\n\n| a | b\n|===\n",
    "[cols=\"1,2\"]\n|===\n| a | b | c | d\n|===\n",
    "|===\n| a \\| pipe | c\n|===\n",
    // Attribute entry in the body.\n
    "Body.\n\n:name: value\n\nMore body.\n",
    // Attribute references: defined, unknown and escaped all stay verbatim.
    "= T\n:product: Bookled\n\nBuilt with {product}, not {unknown} or \\{escaped}.\n",
    // Inline anchors, their reference text, and cross-references to them.
    "Mark [[spot]] and [[fig.1,Figure 1]] here.\n\nSee <<spot>> or \\[[escaped]].\n",
    // Table cell specifiers: spans, repeats, alignments, styles.
    "|===\n| a | b\n2+| wide\n.2+| tall | first\n| second\n3*| same\n|===\n",
    "|===\n| a | b\n^| centred | >.^m| right\nh| head | a| * list\n|===\n",
    // Trailing shapes.
    "No trailing newline",
    "Trailing blanks.\n\n\n",
    "\n\nLeading blanks.\n",
    "\n",
    "",
    // Unicode: multi-code-unit characters through every offset path.
    "= Título 😀\n\nParágrafo com acentuação — e emoji 😀 no meio.\n",
    // The kitchen sink, roughly the probe document used against Asciidoctor.
    """
    = Writing Technical Books
    Osvaldo Santana Neto <osvaldo@example.com>
    :doctype: book
    :toc: left

    A preamble paragraph.

    == Getting started

    Some prose with *bold* and `code`.

    .Installing
    [source,bash]
    ----
    brew install asciidoctor
    ----

    TIP: An admonition.

    [[the-list]]
    .Steps
    . First
    . Second that wraps
      onto a second line

    === Deeper

    |===
    | Column | Column

    | a | b
    |===

    ****
    A sidebar containing:

    * a list
    * inside a compound block
    ****

    // A trailing comment.

    """,
]

@Test(arguments: roundTripSources.indices)
func roundTripIsByteIdentical(_ index: Int) {
    let source = roundTripSources[index]
    let output = roundTrip(source)

    #expect(
        output == source,
        "round trip diverged for source #\(index):\n---source---\n\(source)\n---output---\n\(output)"
    )
}

@Test func fixturesRoundTripByteIdentically() throws {
    for base in Fixture.all {
        let source = try String(contentsOfFile: base + "-input.adoc", encoding: .utf8)
        #expect(
            roundTrip(source) == source,
            "fixture \(URL(fileURLWithPath: base).lastPathComponent) diverged"
        )
    }
}

// MARK: - Documented normalizations

@Test func whitespaceOnlyBlankLinesNormalizeToEmpty() {
    #expect(roundTrip("a\n \nb\n") == "a\n\nb\n")
}

@Test func crlfNormalizesToLF() {
    #expect(roundTrip("one\r\ntwo\r\n") == "one\ntwo\n")
}

// MARK: - Idempotence and determinism

@Test(arguments: roundTripSources.indices)
func serializationIsIdempotent(_ index: Int) {
    let once = roundTrip(roundTripSources[index])
    #expect(roundTrip(once) == once)
}

@Test func builtDocumentsSerializeCanonically() {
    let document = Document(
        header: DocumentHeader(
            title: Title(
                text: "Built",
                range: SourceRange(
                    start: SourceLocation(offset: 0, line: 0, column: 1),
                    end: SourceLocation(offset: 0, line: 0, column: 1)
                )
            ),
            titleRange: nil,
            authorLine: nil,
            attributes: [],
            range: SourceRange(
                start: SourceLocation(offset: 0, line: 0, column: 1),
                end: SourceLocation(offset: 0, line: 0, column: 1)
            )
        ),
        blocks: [
            Block(
                kind: .paragraph,
                range: SourceRange(
                    start: SourceLocation(offset: 0, line: 0, column: 1),
                    end: SourceLocation(offset: 0, line: 0, column: 1)
                ),
                lines: [.synthetic("A paragraph.")]
            ),
            Block(
                kind: .listing,
                range: SourceRange(
                    start: SourceLocation(offset: 0, line: 0, column: 1),
                    end: SourceLocation(offset: 0, line: 0, column: 1)
                ),
                lines: [.synthetic("let x = 1")]
            ),
        ],
        range: SourceRange(
            start: SourceLocation(offset: 0, line: 0, column: 1),
            end: SourceLocation(offset: 0, line: 0, column: 1)
        )
    )

    let expected = """
        = Built

        A paragraph.

        ----
        let x = 1
        ----

        """

    #expect(Serializer.serialize(document) == expected)
    #expect(Serializer.serialize(document) == Serializer.serialize(document))
}

@Test func builtAttributesEmitDeterministically() {
    var attributes = BlockAttributes()
    attributes.style = "source"
    attributes.named = ["title": "One, two", "linenums": ""]
    attributes.id = "snippet"

    let document = Document(
        header: nil,
        blocks: [
            Block(
                kind: .listing,
                range: SourceRange(
                    start: SourceLocation(offset: 0, line: 0, column: 1),
                    end: SourceLocation(offset: 0, line: 0, column: 1)
                ),
                attributes: attributes,
                lines: [.synthetic("code")]
            )
        ],
        range: SourceRange(
            start: SourceLocation(offset: 0, line: 0, column: 1),
            end: SourceLocation(offset: 0, line: 0, column: 1)
        )
    )

    // Named attributes sorted, quoted only when needed, style carrying the id.
    let expected = """
        [source#snippet,linenums=,title="One, two"]
        code

        """

    #expect(Serializer.serialize(document) == expected)
}

// MARK: - The round trip must also keep the parse equal

/// Serializing and reparsing must yield the same semantic tree — blocks, kinds,
/// text — not just the same bytes when the bytes were already ours.
@Test(arguments: roundTripSources.indices)
func reparsingTheOutputPreservesTheTree(_ index: Int) {
    let source = roundTripSources[index]
    let first = Parser.parse(source)
    let second = Parser.parse(Serializer.serialize(first))

    func outline(_ blocks: [Block]) -> [String] {
        blocks.flatMap { block in
            ["\(block.kind)|\(block.text)"] + outline(block.blocks)
        }
    }

    #expect(outline(first.blocks) == outline(second.blocks))
}
