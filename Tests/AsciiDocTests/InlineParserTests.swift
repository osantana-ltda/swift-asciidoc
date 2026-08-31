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
                #expect(extracted.count >= 2)
                check(span.inlines)
            case .macro:
                #expect(extracted.count >= 2)
            case .attributeReference(let name, _):
                #expect(extracted == "{\(name)}")
            case .anchor(let id, _, _):
                #expect(extracted.hasPrefix("[[\(id)"))
                #expect(extracted.hasSuffix("]]"))
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

// MARK: - Macros

private func macro(_ inline: Inline) -> Inline.Macro? {
    guard case .macro(let macro) = inline else {
        return nil
    }
    return macro
}

@Test func linkMacroParses() {
    let parsed = inlines("see link:https://x.io[the site] now")

    #expect(parsed.count == 3)
    let link = try! #require(macro(parsed[1]))
    #expect(link.name == "link")
    #expect(link.target == "https://x.io")
    #expect(link.attributes == "the site")
    #expect(link.plainTextIs("the site"))
}

@Test func bareURLsBecomeLinks() {
    let parsed = inlines("read https://example.com now")

    let link = try! #require(macro(parsed[1]))
    #expect(link.name == "link")
    #expect(link.target == "https://example.com")
    #expect(link.attributes.isEmpty)
}

@Test func aTrailingFullStopStaysOutsideTheLink() {
    let parsed = inlines("visit https://x.io.")

    let link = try! #require(macro(parsed[1]))
    #expect(link.target == "https://x.io")
    #expect(parsed[2].plainText == ".")
}

@Test func aURLWithTextTakesItsBrackets() {
    let parsed = inlines("https://example.com[the site]")

    #expect(parsed.count == 1)
    let link = try! #require(macro(parsed[0]))
    #expect(link.target == "https://example.com")
    #expect(link.attributes == "the site")
}

@Test func xrefShorthandParses() {
    let parsed = inlines("see <<intro>> and <<intro,the intro>>")

    let bare = try! #require(macro(parsed[1]))
    #expect(bare.name == "xref")
    #expect(bare.target == "intro")
    #expect(bare.attributes.isEmpty)

    let titled = try! #require(macro(parsed[3]))
    #expect(titled.target == "intro")
    #expect(titled.attributes == "the intro")
}

@Test func emptyTargetMacrosParse() {
    let parsed = inlines("press kbd:[F5] to run.footnote:[On most systems.]")

    let kbd = try! #require(macro(parsed[1]))
    #expect(kbd.name == "kbd")
    #expect(kbd.target.isEmpty)
    #expect(kbd.attributes == "F5")

    let footnote = try! #require(macro(parsed[3]))
    #expect(footnote.name == "footnote")
    #expect(footnote.attributes == "On most systems.")
}

@Test func unknownMacroNamesStayText() {
    let parsed = inlines("the ratio:3[citation] here")

    #expect(parsed.count == 1)
    #expect(parsed[0].plainText == "the ratio:3[citation] here")
}

@Test func aColonWithoutBracketsIsText() {
    let parsed = inlines("note: this matters")

    #expect(parsed.count == 1)
    #expect(parsed[0].plainText == "note: this matters")
}

@Test func escapedMacrosAreText() {
    let parsed = inlines("type \\link:x[y] literally")

    #expect(parsed.count == 1)
    #expect(parsed[0].plainText == "type link:x[y] literally")
}

@Test func backslashesInOrdinaryTextSurvive() {
    let parsed = inlines("the path C:\\name stays")

    #expect(parsed.count == 1)
    #expect(parsed[0].plainText == "the path C:\\name stays")
}

@Test func anEscapedBracketStaysInTheAttrlist() {
    let parsed = inlines("image:shot.png[a \\] bracket]")

    let image = try! #require(macro(parsed[0]))
    #expect(image.attributes == "a ] bracket")
}

@Test func macrosNestInsideSpans() {
    let parsed = inlines("*see link:x[y]*")

    guard case .span(let strong) = parsed[0] else {
        Issue.record("expected a span")
        return
    }
    #expect(strong.inlines.count == 2)
    #expect(macro(strong.inlines[1])?.name == "link")
}

@Test func macroRangesExtractFaithfully() {
    let source = "see link:https://x.io[site] and <<intro,text>> plus https://y.io."
    let text = source as NSString

    for inline in inlines(source) {
        let extracted = text.substring(
            with: NSRange(
                location: inline.range.start.offset,
                length: inline.range.end.offset - inline.range.start.offset
            )
        )

        if let m = macro(inline) {
            switch m.name {
            case "link" where !m.attributes.isEmpty:
                #expect(extracted == "link:https://x.io[site]")
            case "link":
                #expect(extracted == "https://y.io")
            case "xref":
                #expect(extracted == "<<intro,text>>")
            default:
                Issue.record("unexpected macro \(m.name)")
            }
        }
    }
}

extension Inline.Macro {
    fileprivate func plainTextIs(_ expected: String) -> Bool {
        Inline.macro(self).plainText == expected
    }
}

// MARK: - Attribute references

@Test func anAttributeReferenceParses() {
    let parsed = inlines("built with {product-name} today")

    #expect(parsed.count == 3)
    guard case .attributeReference(let name, let range) = parsed[1] else {
        Issue.record("expected an attribute reference")
        return
    }
    #expect(name == "product-name")
    #expect(range.start.offset == 11)
    #expect(range.end.offset == 25)
    #expect(parsed[1].plainText == "{product-name}")
}

@Test func bracesInProseStayText() {
    // A space, an empty pair, a leading hyphen: none of these are names.
    #expect(inlines("a { x } b").count == 1)
    #expect(inlines("empty {} pair").count == 1)
    #expect(inlines("odd {-name} start").count == 1)
    #expect(inlines("unclosed {name").count == 1)
}

@Test func anEscapedReferenceIsLiteralText() {
    let parsed = inlines("keep \\{name} literal")

    #expect(parsed.count == 1)
    #expect(parsed[0].plainText == "keep {name} literal")
}

@Test func referencesNestInsideSpans() {
    let parsed = inlines("*bold {v}*")

    guard case .span(let span) = parsed[0] else {
        Issue.record("expected a span")
        return
    }
    let hasReference = span.inlines.contains { inline in
        if case .attributeReference(let name, _) = inline {
            return name == "v"
        }
        return false
    }
    #expect(hasReference)
}

// MARK: - Inline anchors

@Test func anInlineAnchorParses() {
    let parsed = inlines("before [[the-spot]] after")

    #expect(parsed.count == 3)
    guard case .anchor(let id, let reftext, let range) = parsed[1] else {
        Issue.record("expected an anchor")
        return
    }
    #expect(id == "the-spot")
    #expect(reftext.isEmpty)
    #expect(range.start.offset == 7)
    #expect(range.end.offset == 19)
}

@Test func anAnchorCarriesItsReferenceText() {
    let parsed = inlines("[[fig.1,Figure 1]] shows it")

    guard case .anchor(let id, let reftext, _) = parsed[0] else {
        Issue.record("expected an anchor")
        return
    }
    #expect(id == "fig.1")
    #expect(reftext == "Figure 1")
    #expect(parsed[0].plainText == "Figure 1")
}

@Test func bracketPairsAroundProseStayText() {
    // A space, an empty pair, an unclosed one, a line break inside.
    #expect(inlines("see [[not an id]] here").count == 1)
    #expect(inlines("empty [[]] pair").count == 1)
    #expect(inlines("unclosed [[id").count == 1)
    #expect(inlines("split [[id\nacross]] lines").count == 1)
}

@Test func anEscapedAnchorIsLiteralText() {
    let parsed = inlines("keep \\[[id]] literal")

    #expect(parsed.count == 1)
    #expect(parsed[0].plainText == "keep [[id]] literal")
}

@Test func theAnchorMacroFormParses() {
    let parsed = inlines("here anchor:spot[] and on")

    let anchors = parsed.compactMap { inline -> Inline.Macro? in
        if case .macro(let macro) = inline, macro.name == "anchor" {
            return macro
        }
        return nil
    }
    #expect(anchors.count == 1)
    #expect(anchors[0].target == "spot")
}

// MARK: - Macro attribute lists

@Test func aMacroAttributeListReadsItsFields() {
    let parsed = inlines("image:x.png[A logo,width=200,height=100]")

    let image = try! #require(macro(parsed[0]))
    // The raw string stays exactly as written — serialization depends on it.
    #expect(image.attributes == "A logo,width=200,height=100")

    let list = image.attributeList
    #expect(list.positional == ["A logo"])
    #expect(list.named["width"] == "200")
    #expect(list.named["height"] == "100")
    // A macro's first positional is its own argument, never a block style.
    #expect(list.style == nil)
}

@Test func macroShorthandCarriesIdAndRoles() {
    let parsed = inlines("link:https://x.io[#home.external.big]")

    let list = try! #require(macro(parsed[0])).attributeList
    #expect(list.id == "home")
    #expect(list.roles == ["external", "big"])
}

@Test func quotedValuesSurviveTheirCommas() {
    let parsed = inlines("image:x.png[Alt,title=\"One, two\"]")

    let list = try! #require(macro(parsed[0])).attributeList
    #expect(list.positional == ["Alt"])
    #expect(list.named["title"] == "One, two")
}

@Test func namedRoleAndOptionsAggregate() {
    let parsed = inlines("link:https://x.io[Text,role=\"a b\",opts=nofollow]")

    let list = try! #require(macro(parsed[0])).attributeList
    #expect(list.roles == ["a", "b"])
    #expect(list.options == ["nofollow"])
}
