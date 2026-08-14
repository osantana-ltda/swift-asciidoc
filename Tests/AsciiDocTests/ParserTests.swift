// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import AsciiDoc

// MARK: - Lines

@Test func linesCarryTheirPositions() {
    let lines = LineReader.lines(of: "one\ntwo\nthree")

    #expect(lines.count == 3)
    #expect(lines[0].range.start.offset == 0)
    #expect(lines[1].range.start.offset == 4)
    #expect(lines[1].range.start.line == 2)
    #expect(lines[2].text == "three")
    #expect(lines[2].range.end.offset == 13)
}

@Test func aTrailingNewlineDoesNotAddALine() {
    #expect(LineReader.lines(of: "one\ntwo\n").count == 2)
    #expect(LineReader.lines(of: "one\ntwo").count == 2)
    #expect(LineReader.lines(of: "one\n\n").count == 2)
}

@Test func offsetsCountUTF16CodeUnits() {
    // An emoji outside the basic plane is two UTF-16 code units, which is what
    // NSTextStorage counts and therefore what this has to agree with.
    let lines = LineReader.lines(of: "a😀b\nnext")

    #expect(lines[0].range.end.offset == 4)
    #expect(lines[1].range.start.offset == 5)
}

// MARK: - Header

@Test func parsesTheDocumentHeader() {
    let document = Parser.parse(
        """
        = Writing Technical Books
        Osvaldo Santana Neto
        :doctype: book
        :source-highlighter: highlight.js

        Body text.
        """
    )

    #expect(document.header?.title?.text == "Writing Technical Books")
    #expect(document.header?.authorLine == "Osvaldo Santana Neto")
    #expect(document.attributes["doctype"] == "book")
    #expect(document.attributes["source-highlighter"] == "highlight.js")
    #expect(document.blocks.count == 1)
    #expect(document.blocks[0].kind == .paragraph)
}

@Test func aDocumentNeedNotHaveAHeader() {
    let document = Parser.parse("Just a paragraph.")

    #expect(document.header == nil)
    #expect(document.blocks.count == 1)
}

@Test func unsetAttributesAreMarked() {
    let document = Parser.parse("= T\n:sectnums!:\n")
    let entry = document.header?.attributes.first

    #expect(entry?.name == "sectnums")
    #expect(entry?.isUnset == true)
}

// MARK: - Sections

@Test func sectionsNestByLevel() {
    let document = Parser.parse(
        """
        = Title

        == One

        Alpha.

        === One A

        Beta.

        == Two

        Gamma.
        """
    )

    #expect(document.blocks.count == 2)
    #expect(document.blocks[0].kind == .section(level: 1))
    #expect(document.blocks[0].title?.text == "One")
    // The paragraph and the nested section.
    #expect(document.blocks[0].blocks.count == 2)
    #expect(document.blocks[0].blocks[1].kind == .section(level: 2))
    #expect(document.blocks[1].title?.text == "Two")
}

@Test func aSectionCoversItsContent() {
    let source = """
        == One

        Alpha.
        """
    let document = Parser.parse(source)
    let section = document.blocks[0]

    #expect(section.range.start.offset == 0)
    #expect(section.range.end.offset == (source as NSString).length)
}

// MARK: - Delimited blocks

@Test func listingBlocksKeepTheirContentVerbatim() {
    let document = Parser.parse(
        """
        [source,swift]
        ----
        let answer = 42
        // not a comment here, it is code
        ----
        """
    )

    let block = document.blocks[0]
    #expect(block.kind == .listing)
    #expect(block.attributes.style == "source")
    #expect(block.attributes.positional == ["source", "swift"])
    #expect(block.lines.count == 2)
    #expect(block.text == "let answer = 42\n// not a comment here, it is code")
}

@Test func compoundBlocksParseTheirChildren() {
    let document = Parser.parse(
        """
        ====
        A paragraph inside an example.

        == Not a section, just text? No — a section.
        ====
        """
    )

    let block = document.blocks[0]
    #expect(block.kind == .example)
    #expect(block.blocks.count == 2)
    #expect(block.blocks[0].kind == .paragraph)
}

@Test func quoteBlocksAreCompound() {
    let document = Parser.parse(
        """
        ____
        Quoted prose.
        ____
        """
    )

    #expect(document.blocks[0].kind == .quote)
    #expect(document.blocks[0].blocks.count == 1)
}

@Test func aBlockRangeIncludesItsDelimiters() {
    let source = """
        ----
        code
        ----
        """
    let document = Parser.parse(source)

    #expect(document.blocks[0].range.start.offset == 0)
    #expect(document.blocks[0].range.end.offset == (source as NSString).length)
}

@Test func anUnterminatedBlockRunsToTheEnd() {
    let document = Parser.parse(
        """
        ----
        code
        """
    )

    #expect(document.blocks[0].kind == .listing)
    #expect(document.blocks[0].lines.count == 1)
}

// MARK: - Metadata

@Test func blockTitlesAndAnchorsAttach() {
    let document = Parser.parse(
        """
        [[the-anchor]]
        .A title
        [source,swift,linenums]
        ----
        code
        ----
        """
    )

    let block = document.blocks[0]
    #expect(block.title?.text == "A title")
    #expect(block.attributes.id == "the-anchor")
    #expect(block.attributes.named["linenums"] == nil)
    #expect(block.attributes.positional.contains("linenums"))
    // The range reaches back to the first metadata line.
    #expect(block.range.start.offset == 0)
}

@Test func shorthandAttributesAreUnpacked() {
    let document = Parser.parse(
        """
        [quote#epigraph.lead.wide]
        Some text.
        """
    )

    let attributes = document.blocks[0].attributes
    #expect(attributes.style == "quote")
    #expect(attributes.id == "epigraph")
    #expect(attributes.roles == ["lead", "wide"])
}

@Test func namedAttributesTakeQuotedValues() {
    let document = Parser.parse(
        """
        [source,swift,title="One, two"]
        ----
        code
        ----
        """
    )

    #expect(document.blocks[0].attributes.named["title"] == "One, two")
}

// MARK: - Comments and lists

@Test func lineCommentsAreTheirOwnBlock() {
    let document = Parser.parse(
        """
        // one
        // two

        Text.
        """
    )

    #expect(document.blocks[0].kind == .comment)
    #expect(document.blocks[0].lines.count == 2)
    #expect(document.blocks[1].kind == .paragraph)
}

@Test func commentBlocksAreDelimited() {
    let document = Parser.parse(
        """
        ////
        Hidden.
        ////
        """
    )

    #expect(document.blocks[0].kind == .comment)
}

@Test func unorderedListsCollectTheirItems() {
    let document = Parser.parse(
        """
        * One
        * Two that wraps
          onto another line
        * Three
        """
    )

    let list = document.blocks[0]
    #expect(list.kind == .unorderedList)
    #expect(list.blocks.count == 3)
    #expect(list.blocks[1].lines.count == 2)
}

@Test func orderedListsAreDistinguished() {
    let document = Parser.parse(
        """
        . One
        . Two
        """
    )

    #expect(document.blocks[0].kind == .orderedList)
    #expect(document.blocks[0].blocks.count == 2)
}

@Test func numberedListsAreOrderedToo() {
    let document = Parser.parse(
        """
        1. One
        2. Two
        """
    )

    #expect(document.blocks[0].kind == .orderedList)
}

// MARK: - Tables

@Test func tablesGroupCellsByTheFirstLine() {
    let document = Parser.parse(
        """
        |===
        | a | b
        | c | d
        |===
        """
    )

    let table = document.blocks[0]
    #expect(table.kind == .table)
    #expect(table.blocks.count == 2)
    #expect(table.blocks[0].kind == .tableRow(header: false))
    #expect(table.blocks[0].blocks.map(\.text) == ["a", "b"])
    #expect(table.blocks[1].blocks.map(\.text) == ["c", "d"])
}

@Test func aBlankLineAfterTheFirstRowMakesItTheHead() {
    let document = Parser.parse(
        """
        |===
        | h1 | h2

        | a | b
        |===
        """
    )

    let table = document.blocks[0]
    #expect(table.blocks[0].kind == .tableRow(header: true))
    #expect(table.blocks[0].blocks.map(\.text) == ["h1", "h2"])
    #expect(table.blocks[1].kind == .tableRow(header: false))
}

@Test func theHeaderOptionMakesTheFirstRowTheHead() {
    let document = Parser.parse(
        """
        [%header]
        |===
        | h1 | h2
        | a | b
        |===
        """
    )

    #expect(document.blocks[0].blocks[0].kind == .tableRow(header: true))
}

@Test func theColsAttributeSetsTheColumnCount() {
    let document = Parser.parse(
        """
        [cols="1,2,3"]
        |===
        | a | b | c | d | e | f
        |===
        """
    )

    let table = document.blocks[0]
    #expect(table.blocks.count == 2)
    #expect(table.blocks[0].blocks.count == 3)
    #expect(table.blocks[1].blocks.map(\.text) == ["d", "e", "f"])
}

@Test func oneCellPerLineIsASingleColumn() {
    let document = Parser.parse(
        """
        |===
        | a
        | b
        | c
        |===
        """
    )

    let table = document.blocks[0]
    #expect(table.blocks.count == 3)
    #expect(table.blocks.allSatisfy { $0.blocks.count == 1 })
}

@Test func escapedPipesStayInsideTheirCell() {
    let document = Parser.parse(
        """
        |===
        | a \\| b | c
        |===
        """
    )

    let row = document.blocks[0].blocks[0]
    #expect(row.blocks.map(\.text) == ["a | b", "c"])
}

@Test func tableCellsCarryExactRanges() {
    let source = """
        |===
        | alpha | beta
        |===
        """
    let document = Parser.parse(source)
    let cells = document.blocks[0].blocks[0].blocks
    let text = source as NSString

    for cell in cells {
        let extracted = text.substring(
            with: NSRange(
                location: cell.range.start.offset,
                length: cell.range.end.offset - cell.range.start.offset
            )
        )
        #expect(extracted == cell.text)
    }
}

@Test func everyBlockIsCoveredByItsRange() {
    let source = """
        = Title
        :attr: value

        == One

        A paragraph.

        ----
        code
        ----

        * item
        """
    let document = Parser.parse(source)

    // No block may claim text outside the document, and ranges must run
    // forwards. Cheap invariants, but they catch arithmetic slips that only
    // show up as decoration landing on the wrong characters.
    let length = (source as NSString).length
    func check(_ blocks: [Block]) {
        for block in blocks {
            #expect(block.range.start.offset >= 0)
            #expect(block.range.end.offset <= length)
            #expect(block.range.start.offset <= block.range.end.offset)
            check(block.blocks)
        }
    }
    check(document.blocks)
}

import Foundation
