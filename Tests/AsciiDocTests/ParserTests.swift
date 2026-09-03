// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
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

// MARK: - Nested lists, description lists, continuation

@Test func aDeeperMarkerNestsInsideTheItemBeforeIt() {
    let document = Parser.parse(
        """
        * one
        ** deep
        *** deeper
        ** back
        * two
        """
    )

    let list = document.blocks[0]
    #expect(list.blocks.count == 2)

    let nested = list.blocks[0].blocks[0]
    #expect(nested.kind == .unorderedList)
    #expect(nested.blocks.count == 2)
    #expect(nested.blocks[0].blocks[0].blocks.count == 1)
    // The outer item's range grew to cover everything under it.
    #expect(list.blocks[0].range.end.line == 4)
}

@Test func aDifferentMarkerFamilyNestsToo() {
    let document = Parser.parse(
        """
        . ordered
        * nested bullet
        . second ordered
        """
    )

    let list = document.blocks[0]
    #expect(list.kind == .orderedList)
    #expect(list.blocks.count == 2)
    #expect(list.blocks[0].blocks[0].kind == .unorderedList)
}

@Test func aBlankLineBetweenItemsKeepsTheListGoing() {
    let document = Parser.parse("* one\n\n* two\n\nA paragraph.\n")

    #expect(document.blocks.count == 2)
    #expect(document.blocks[0].blocks.count == 2)
    #expect(document.blocks[1].kind == .paragraph)
}

@Test func aBlankLineEndsTheListOnlyForSomethingThatIsNotAList() {
    // Probed against Asciidoctor: a list of a new signature after a blank
    // line nests inside the item above it rather than starting a sibling.
    // Counter-intuitive, and worth pinning.
    let nested = Parser.parse("* a\n\nTerm:: b\n")
    #expect(nested.blocks.count == 1)
    #expect(nested.blocks[0].blocks[0].blocks[0].kind == .descriptionList)

    // A paragraph there does end the list.
    let ended = Parser.parse("* a\n\nJust prose.\n")
    #expect(ended.blocks.count == 2)
    #expect(ended.blocks[1].kind == .paragraph)
}

@Test func descriptionListsCarryTheirTerms() {
    let document = Parser.parse(
        """
        Term:: A definition
        Other::
        On the next line
        """
    )

    let list = document.blocks[0]
    #expect(list.kind == .descriptionList)
    #expect(list.blocks.count == 2)
    #expect(list.blocks[0].title?.text == "Term")
    #expect(list.blocks[1].title?.text == "Other")
    #expect(list.blocks[1].lines.count == 2)
}

@Test func aDeeperTermNestsLikeAnyOtherMarker() {
    let document = Parser.parse("Outer:: One\nInner::: Two\nOuter2:: Three\n")

    let list = document.blocks[0]
    #expect(list.blocks.count == 2)
    #expect(list.blocks[0].blocks[0].kind == .descriptionList)
    #expect(list.blocks[0].blocks[0].blocks[0].title?.text == "Inner")
}

@Test func aTermsRangeLocatesItExactly() {
    let source = "The term:: A definition\n"
    let term = Parser.parse(source).blocks[0].blocks[0].title!
    let text = source as NSString

    #expect(
        text.substring(
            with: NSRange(
                location: term.range.start.offset,
                length: term.range.end.offset - term.range.start.offset
            )
        ) == "The term"
    )
}

@Test func aColonInsideAWordIsNotATerm() {
    // The marker must end the line or be followed by a space, which is what
    // leaves C++ scope operators and URLs alone.
    #expect(Parser.parse("Use std::vector here.\n").blocks[0].kind == .paragraph)
    #expect(Parser.parse("See https://x.io/a::b now.\n").blocks[0].kind == .paragraph)
    // An attribute entry has nothing before its colon, so it is no term.
    // (In the body: at the top of a document it would be the header.)
    #expect(Parser.parse("Body.\n\n:name: value\n").blocks[1].kind == .attributeEntry)
}

@Test func aContinuationAttachesTheBlockAfterIt() {
    let document = Parser.parse(
        """
        * item
        +
        ----
        code
        ----
        +
        Attached paragraph.
        * next
        """
    )

    let list = document.blocks[0]
    #expect(list.blocks.count == 2)

    let attached = list.blocks[0].blocks
    #expect(attached.count == 2)
    #expect(attached[0].kind == .listing)
    #expect(attached[1].kind == .paragraph)
    // The `+` rides on the attached block, which is what puts it back.
    #expect(attached[0].prelude.first?.text == "+")
}

// MARK: - Includes

@Test func anIncludeRecordsItsTargetAndAttributes() {
    let document = Parser.parse("Before.\n\ninclude::code/sample.swift[lines=1..5,indent=0]\n")

    let include = document.blocks[1]
    #expect(include.kind == .include(target: "code/sample.swift"))
    #expect(include.attributes.named["lines"] == "1..5")
    #expect(include.attributes.named["indent"] == "0")
    // The line itself is kept, which is what writes it back out.
    #expect(include.lines.first?.text == "include::code/sample.swift[lines=1..5,indent=0]")
}

@Test func anEscapedIncludeIsOrdinaryText() {
    let document = Parser.parse("\\include::literal.adoc[]\n")
    #expect(document.blocks[0].kind == .paragraph)
}

@Test func aMalformedIncludeIsNotOne() {
    // No brackets, no target, and a colon run that is a description term.
    #expect(Parser.parse("include::no-brackets.adoc\n").blocks[0].kind == .paragraph)
    #expect(Parser.parse("include::[]\n").blocks[0].kind == .paragraph)
    #expect(Parser.parse("include:: with a space\n").blocks[0].kind == .descriptionList)
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

@Test func cellSpecifiersParseTheirParts() {
    // Spans, repeats, alignments and styles, alone and combined.
    #expect(TableParser.specifier("2+")?.colspan == 2)
    #expect(TableParser.specifier(".3+")?.rowspan == 3)
    let both = TableParser.specifier("2.3+")
    #expect(both?.colspan == 2)
    #expect(both?.rowspan == 3)
    #expect(TableParser.specifier("3*")?.repeatCount == 3)
    #expect(TableParser.specifier("a")?.style == "a")
    #expect(TableParser.specifier("^")?.horizontal == "center")
    #expect(TableParser.specifier(">")?.horizontal == "right")
    #expect(TableParser.specifier(".^")?.vertical == "center")
    let mixed = TableParser.specifier("2+^.>m")
    #expect(mixed?.colspan == 2)
    #expect(mixed?.horizontal == "center")
    #expect(mixed?.vertical == "right")
    #expect(mixed?.style == "m")
}

@Test func ordinaryTextIsNotASpecifier() {
    // The parts must appear in order, digits need their span marker, and
    // anything left over disqualifies the whole token.
    #expect(TableParser.specifier("") == nil)
    #expect(TableParser.specifier("2") == nil)
    #expect(TableParser.specifier("item") == nil)
    #expect(TableParser.specifier("a2+") == nil)
    #expect(TableParser.specifier("+2") == nil)
}

@Test func aSpecifierBindsToTheCellAfterIt() {
    let document = Parser.parse(
        """
        |===
        | plain | 2+| spans two
        |===
        """
    )

    let cells = document.blocks[0].blocks[0].blocks
    #expect(cells.map(\.text) == ["plain", "spans two"])
    #expect(cells[0].attributes.named["colspan"] == nil)
    #expect(cells[1].attributes.named["colspan"] == "2")
}

@Test func cellTextEndingInASpecifierLetterSurvives() {
    // `d` and `a` are style letters; at the end of a line, and separated
    // from the next `|` by a space, they are ordinary content.
    let document = Parser.parse(
        """
        |===
        | c | d
        | item a | next
        |===
        """
    )

    let rows = document.blocks[0].blocks
    #expect(rows[0].blocks.map(\.text) == ["c", "d"])
    #expect(rows[1].blocks.map(\.text) == ["item a", "next"])
}

@Test func spansLayOutTheGrid() {
    // The spanning cell claims both columns of its row, so the next row
    // starts fresh rather than inheriting a stray cell.
    let document = Parser.parse(
        """
        |===
        | a | b
        2+| wide
        | c | d
        |===
        """
    )

    let rows = document.blocks[0].blocks
    #expect(rows.count == 3)
    #expect(rows[0].blocks.map(\.text) == ["a", "b"])
    #expect(rows[1].blocks.map(\.text) == ["wide"])
    #expect(rows[2].blocks.map(\.text) == ["c", "d"])
}

@Test func aRowSpanKeepsItsColumnOccupied() {
    // The tall cell holds column one for the second row, which therefore
    // takes a single cell.
    let document = Parser.parse(
        """
        |===
        .2+| tall | first
        | second
        | a | b
        |===
        """
    )

    let rows = document.blocks[0].blocks
    #expect(rows[0].blocks.map(\.text) == ["tall", "first"])
    #expect(rows[1].blocks.map(\.text) == ["second"])
    #expect(rows[2].blocks.map(\.text) == ["a", "b"])
}

@Test func aRepeatSpecifierDuplicatesItsCell() {
    let document = Parser.parse(
        """
        |===
        | a | b
        3*| same
        |===
        """
    )

    let rows = document.blocks[0].blocks
    #expect(rows[1].blocks.map(\.text) == ["same", "same"])
    #expect(rows[2].blocks.map(\.text) == ["same"])
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

// MARK: - Delimiter-separated tables

@Test func aCommaDelimiterMakesEveryLineACsvRow() {
    let document = Parser.parse(
        """
        ,===
        Name,Role
        Ada,Analyst
        ,===
        """
    )

    let table = document.blocks[0]
    #expect(table.kind == .table)
    #expect(table.blocks.count == 2)
    #expect(table.blocks[0].blocks.map(\.text) == ["Name", "Role"])
    #expect(table.blocks[1].blocks.map(\.text) == ["Ada", "Analyst"])
}

@Test func quotedCsvFieldsKeepTheirSeparatorsAndQuotes() {
    // Written flat: the source holds a run of three quotes, which a Swift
    // multi-line literal cannot carry.
    let document = Parser.parse(",===\na,\"b,c\",\"say \"\"hi\"\"\"\n,===\n")

    let row = document.blocks[0].blocks[0]
    #expect(row.blocks.map(\.text) == ["a", "b,c", "say \"hi\""])
}

@Test func aColonDelimiterMakesADsvTableWithEscapableSeparators() {
    let document = Parser.parse(
        """
        :===
        key:value
        a\\:b:plain
        :===
        """
    )

    let table = document.blocks[0]
    #expect(table.blocks[0].blocks.map(\.text) == ["key", "value"])
    #expect(table.blocks[1].blocks.map(\.text) == ["a:b", "plain"])
}

@Test func theFormatAttributeOverridesThePipeDelimiter() {
    let document = Parser.parse(
        """
        [format=csv]
        |===
        one,two
        |===
        """
    )

    #expect(document.blocks[0].blocks[0].blocks.map(\.text) == ["one", "two"])
}

@Test func aChosenSeparatorReplacesTheFormatsOwn() {
    let document = Parser.parse(
        """
        [format=dsv,separator=;]
        |===
        one;two
        |===
        """
    )

    #expect(document.blocks[0].blocks[0].blocks.map(\.text) == ["one", "two"])
}

@Test func csvHeadersFollowTheSameBlankLineRule() {
    let document = Parser.parse(
        """
        ,===
        Name,Role

        Ada,Analyst
        ,===
        """
    )

    let table = document.blocks[0]
    #expect(table.blocks[0].kind == .tableRow(header: true))
    #expect(table.blocks[1].kind == .tableRow(header: false))
}

@Test func separatedCellsCarryExactRanges() {
    let source = """
        ,===
        alpha, "b,c" ,gamma
        ,===
        """
    let document = Parser.parse(source)
    let text = source as NSString

    // The range covers the field as written — quotes included — so it stays
    // exact even where the decoded text is shorter.
    let written = document.blocks[0].blocks[0].blocks.map { cell in
        text.substring(
            with: NSRange(
                location: cell.range.start.offset,
                length: cell.range.end.offset - cell.range.start.offset
            )
        )
    }

    #expect(written == ["alpha", "\"b,c\"", "gamma"])
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
