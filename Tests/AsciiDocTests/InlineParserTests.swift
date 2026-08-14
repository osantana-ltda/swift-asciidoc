// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import AsciiDoc

private func inlines(_ source: String) -> [Inline] {
    InlineParser.parse(LineReader.lines(of: source))
}

@Test func plainTextIsOneRun() {
    let parsed = inlines("hello")

    #expect(parsed.count == 1)
    #expect(parsed[0] == .text(value: "hello", range: parsed[0].range))
    #expect(parsed[0].range.start.offset == 0)
    #expect(parsed[0].range.end.offset == 5)
}

@Test func constrainedStrongParses() {
    let parsed = inlines("*s*")

    guard case .span(let span) = parsed[0] else {
        Issue.record("expected a span")
        return
    }

    #expect(span.variant == .strong)
    #expect(span.form == .constrained)
    #expect(span.range.start.offset == 0)
    #expect(span.range.end.offset == 3)
    #expect(span.inlines == [.text(value: "s", range: span.inlines[0].range)])
    #expect(span.inlines[0].range.start.offset == 1)
}

@Test func aDelimiterInsideAWordIsText() {
    let parsed = inlines("a*b*c")

    #expect(parsed.count == 1)
    #expect(parsed[0].plainText == "a*b*c")
}

@Test func unconstrainedStrongWorksInsideAWord() {
    let parsed = inlines("un**believable**s")

    #expect(parsed.count == 3)
    #expect(parsed[0].plainText == "un")
    guard case .span(let span) = parsed[1] else {
        Issue.record("expected a span")
        return
    }
    #expect(span.variant == .strong)
    #expect(span.form == .unconstrained)
    #expect(span.plainTextEquals("believable"))
    #expect(parsed[2].plainText == "s")
}

@Test func spansNest() {
    let parsed = inlines("*bold _both_*")

    guard case .span(let strong) = parsed[0] else {
        Issue.record("expected a span")
        return
    }

    #expect(strong.variant == .strong)
    #expect(strong.inlines.count == 2)
    guard case .span(let emphasis) = strong.inlines[1] else {
        Issue.record("expected a nested span")
        return
    }
    #expect(emphasis.variant == .emphasis)
    #expect(emphasis.plainTextEquals("both"))
}

@Test func anEscapedDelimiterIsText() {
    let parsed = inlines("\\*not strong*")

    #expect(parsed.count == 1)
    #expect(parsed[0].plainText == "*not strong*")
}

@Test func codeAndMarkAndEmphasisParse() {
    for (source, variant) in [
        ("`code`", Inline.Span.Variant.code),
        ("#mark#", .mark),
        ("_emphasis_", .emphasis),
    ] {
        let parsed = inlines(source)
        guard case .span(let span) = parsed[0] else {
            Issue.record("expected a span in \(source)")
            continue
        }
        #expect(span.variant == variant)
    }
}

@Test func superscriptWorksInsideAWord() {
    let parsed = inlines("E=mc^2^ then")

    #expect(parsed.count == 3)
    guard case .span(let span) = parsed[1] else {
        Issue.record("expected a span")
        return
    }
    #expect(span.variant == .superscriptText)
    #expect(span.plainTextEquals("2"))
}

@Test func superscriptTakesNoSpaces() {
    let parsed = inlines("a ^not a sup^ b")

    #expect(parsed.count == 1)
    #expect(parsed[0].plainText == "a ^not a sup^ b")
}

@Test func anUnclosedDelimiterIsText() {
    let parsed = inlines("*just an asterisk at the start")

    #expect(parsed.count == 1)
    #expect(parsed[0].plainText == "*just an asterisk at the start")
}

@Test func spansCrossLineBreaks() {
    let parsed = inlines("before *strong\nacross* after")

    #expect(parsed.count == 3)
    guard case .span(let span) = parsed[1] else {
        Issue.record("expected a span")
        return
    }
    #expect(span.plainTextEquals("strong\nacross"))
    #expect(span.range.start.line == 1)
    #expect(span.inlines[0].range.end.line == 2)
}

@Test func snakeCaseIdentifiersAreNotEmphasis() {
    let parsed = inlines("the foo_bar_baz identifier")

    #expect(parsed.count == 1)
    #expect(parsed[0].plainText == "the foo_bar_baz identifier")
}

/// Every inline's range must extract from the source to exactly the text it
/// claims to cover — for text runs the value itself, for spans the delimited
/// region. This is the property decoration will consume.
@Test(
    arguments: [
        "plain",
        "*s*",
        "a **b** c",
        "*bold _both_* and `code`",
        "E=mc^2^ and H~2~O",
        "line one *spanning\nlines* two",
    ]
)
func rangesExtractFaithfully(_ source: String) {
    let text = source as NSString

    func check(_ inlines: [Inline]) {
        for inline in inlines {
            let extracted = text.substring(
                with: NSRange(
                    location: inline.range.start.offset,
                    length: inline.range.end.offset - inline.range.start.offset
                )
            )

            switch inline {
            case .text(let value, _):
                #expect(extracted == value)
            case .span(let span):
                #expect(extracted.hasPrefix(String(extracted.first ?? " ")))
                #expect(extracted.count >= 2)
                check(span.inlines)
            }
        }
    }

    check(inlines(source))
}

extension Inline.Span {
    fileprivate func plainTextEquals(_ expected: String) -> Bool {
        inlines.map(\.plainText).joined() == expected
    }
}
