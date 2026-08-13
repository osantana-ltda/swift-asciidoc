// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import AsciiDoc

/// Fixtures in the AsciiDoc TCK's own layout — `name-input.adoc` beside
/// `name-output.json` — run through the same Abstract Semantic Graph encoder
/// the TCK adapter uses.
///
/// Two reasons for the format. The TCK's own corpus is small (13 block cases at
/// the time of writing), so most of the coverage has to come from somewhere;
/// and writing ours in its currency means a case can be contributed upstream
/// rather than rewritten.
///
/// **These are regression fixtures, not conformance ones.** The expected files
/// were generated from this parser and read once by eye. They lock behaviour in
/// place so that a change shows up as a diff; they do not prove the behaviour is
/// what the specification requires. Only the TCK's own cases do that, and those
/// are run separately:
///
/// ```
/// asciidoc-tck cli -c .build/release/asciidoc-tck-adapter
/// ```
enum Fixture {
    static let all: [String] = {
        guard let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil),
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else {
            return []
        }

        return walker.compactMap { entry in
            guard let url = entry as? URL, url.lastPathComponent.hasSuffix("-input.adoc") else {
                return nil
            }
            return String(url.path.dropLast("-input.adoc".count))
        }
        .sorted()
    }()
}

@Test(arguments: Fixture.all)
func fixtureMatchesItsExpectedGraph(_ base: String) throws {
    let source = try String(contentsOfFile: base + "-input.adoc", encoding: .utf8)
    let expectedData = try Data(contentsOf: URL(fileURLWithPath: base + "-output.json"))

    let produced = AbstractSemanticGraph.encode(Parser.parse(source), source: source)
    let expected = try JSONSerialization.jsonObject(with: expectedData)

    // Round-tripping ours through JSON normalises number and string types so the
    // comparison is of content rather than of Swift's boxing.
    let normalised = try JSONSerialization.jsonObject(
        with: JSONSerialization.data(withJSONObject: produced)
    )

    #expect(
        NSDictionary(dictionary: normalised as! [String: Any])
            .isEqual(to: expected as! [String: Any]),
        "\(URL(fileURLWithPath: base).lastPathComponent) does not match its expected graph"
    )
}

@Test func thereAreFixturesToRun() {
    #expect(!Fixture.all.isEmpty)
}

/// Invariants that must hold for *any* input, checked over every fixture plus a
/// few inputs chosen to be awkward. Ranges landing outside the document, or
/// running backwards, show up here rather than as decoration drawn in the wrong
/// place three layers up.
@Test(
    arguments: [
        "",
        "\n\n\n",
        "= Only a title",
        "----\nunterminated",
        "[source,swift]",
        ".Title with no block",
        "* a\n** b\n*** c",
        "|===\n| a\n|===",
        "= T\n:a: 1\n:b!:\n\ntext\n\n== S\n\n____\nq\n____\n",
        "a😀b\n\n== 😀\n\ntext",
    ]
)
func rangesStayInsideTheDocument(_ source: String) {
    let document = Parser.parse(source)
    let length = (source as NSString).length

    func check(_ blocks: [Block]) {
        for block in blocks {
            #expect(block.range.start.offset >= 0)
            #expect(block.range.end.offset <= length)
            #expect(block.range.start.offset <= block.range.end.offset)
            #expect(block.range.start.line >= 1)

            for line in block.lines {
                #expect(line.range.end.offset <= length)
            }

            check(block.blocks)
        }
    }

    check(document.blocks)
}

/// Parsing must terminate. A block kind that consumes nothing would spin
/// forever, and the failure mode is a hung editor rather than a wrong tree.
@Test(
    arguments: [
        "[",
        "[]",
        "..",
        "...",
        "--",
        "+++",
        ":",
        "::",
        "*",
        ". ",
        "= ",
        "//",
    ]
)
func awkwardInputTerminates(_ source: String) {
    _ = Parser.parse(source)
    _ = Parser.parse(source + "\n" + source)
}
