// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

import AsciiDoc
import Foundation

// Two modes:
//
// `--tree` reads AsciiDoc on stdin and prints the block tree. Useful while the
// parser is being built, and the quickest way to see what it makes of a real
// document.
//
// The default mode is the adapter for the Eclipse AsciiDoc Technology
// Compatibility Kit: the harness sends a JSON object on stdin and expects the
// Abstract Semantic Graph on stdout. That encoding is not implemented yet, so
// the adapter exits non-zero — reporting success without it would make a
// conformance report meaningless.

// Benchmark: full parse against incremental reparse at book scale, on a
// generated document. Needs no input.
if CommandLine.arguments.contains("--bench-reparse") {
    var chapters = 400
    if let index = CommandLine.arguments.firstIndex(of: "--chapters"),
        index + 1 < CommandLine.arguments.count,
        let requested = Int(CommandLine.arguments[index + 1])
    {
        chapters = requested
    }

    let source = (1...chapters).map { number in
        """
        == Chapter \(number)

        A paragraph of ordinary prose, long enough to be worth parsing but not so long that it dominates the measurement, sitting in chapter \(number).

        [source,swift]
        ----
        let value = \(number)
        ----

        * a list item
        * another list item

        A closing paragraph for chapter \(number).

        """
    }.joined(separator: "\n")

    // The package sets no platform floor, so it predates ContinuousClock;
    // Date is precise enough at these magnitudes.
    func milliseconds(_ body: () -> Void) -> Double {
        let started = Date()
        body()
        return -started.timeIntervalSinceNow * 1000
    }

    var document = Parser.parse(source)
    print(
        "Document: \(chapters) chapters, \(source.utf16.count) UTF-16 units, \(document.sourceLineCount) lines, ~\(source.utf16.count / 2000) pages"
    )

    let full = milliseconds { document = Parser.parse(source) }
    print(String(format: "Full parse                     %8.2f ms", full))

    // Typing in a paragraph in the middle of the document.
    let caret = source.utf16.count / 2
    var samples: [Double] = []
    var incrementalCount = 0
    for step in 0..<25 {
        let edit = SourceEdit(start: caret + step, length: 0, replacement: "x")
        var result: IncrementalParser.Result?
        samples.append(
            milliseconds { result = IncrementalParser.reparse(document, applying: edit) })
        if let result {
            document = result.document
            if result.incremental { incrementalCount += 1 }
        }
    }
    samples.sort()
    print(
        String(
            format: "Keystroke, incremental — median%8.2f ms   (%d/25 on the fast path)",
            samples[samples.count / 2], incrementalCount))
    print(String(format: "Keystroke, incremental — worst %8.2f ms", samples[samples.count - 1]))

    let enter = milliseconds {
        _ = IncrementalParser.reparse(
            document, applying: SourceEdit(start: caret, length: 0, replacement: "\n----\n"))
    }
    print(String(format: "Opening a delimiter (fallback) %8.2f ms", enter))

    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()

// Round-trip mode: AsciiDoc on stdin, parse → serialize → stdout. With it,
// any corpus on disk verifies the round trip:
//
//     diff <(asciidoc-tck-adapter --roundtrip < doc.adoc) doc.adoc
if CommandLine.arguments.contains("--roundtrip") {
    let source = String(decoding: input, as: UTF8.self)
    FileHandle.standardOutput.write(Data(Serializer.serialize(Parser.parse(source)).utf8))
    exit(0)
}

guard CommandLine.arguments.contains("--tree") else {
    // TCK mode: a JSON request in, an Abstract Semantic Graph out.
    guard
        let request = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
        let contents = request["contents"] as? String
    else {
        FileHandle.standardError.write(Data("asciidoc-tck-adapter: bad request\n".utf8))
        exit(1)
    }

    if request["type"] as? String == "inline" {
        let inlines = InlineParser.parse(LineReader.lines(of: contents))
            .map(AbstractSemanticGraph.encodeInline)
        guard
            let encoded = try? JSONSerialization.data(
                withJSONObject: inlines,
                options: [.sortedKeys]
            )
        else {
            FileHandle.standardError.write(Data("asciidoc-tck-adapter: encoding failed\n".utf8))
            exit(1)
        }

        FileHandle.standardOutput.write(encoded)
        exit(0)
    }

    let graph = AbstractSemanticGraph.encode(Parser.parse(contents), source: contents)
    guard
        let encoded = try? JSONSerialization.data(
            withJSONObject: graph,
            options: [.sortedKeys]
        )
    else {
        FileHandle.standardError.write(Data("asciidoc-tck-adapter: encoding failed\n".utf8))
        exit(1)
    }

    FileHandle.standardOutput.write(encoded)
    exit(0)
}

let document = Parser.parse(String(decoding: input, as: UTF8.self))

func describe(_ kind: Block.Kind) -> String {
    switch kind {
    case .section(let level): "section \(level)"
    case .paragraph: "paragraph"
    case .preamble: "preamble"
    case .admonition(let variant): "admonition (\(variant))"
    case .listing: "listing"
    case .literal: "literal"
    case .quote: "quote"
    case .example: "example"
    case .sidebar: "sidebar"
    case .passthrough: "passthrough"
    case .open: "open"
    case .table: "table"
    case .tableRow(let header): header ? "row (head)" : "row"
    case .tableCell: "cell"
    case .unorderedList: "ulist"
    case .orderedList: "olist"
    case .descriptionList: "dlist"
    case .listItem: "item"
    case .comment: "comment"
    case .attributeEntry: "attribute"
    case .include(let target): "include \(target)"
    case .unparsed: "unparsed"
    }
}

func dump(_ blocks: [Block], indent: Int) {
    for block in blocks {
        // Metadata with no block to attach to — an anchor or title at the end
        // of a file — is kept whole, but it is not a construct the parser
        // failed to model, and the corpus census must not count it as one.
        let orphan = block.kind == .unparsed && block.lines.isEmpty && !block.prelude.isEmpty
        let label = orphan ? "orphan" : describe(block.kind)
        var line = String(repeating: "  ", count: indent) + label
        line += "  [\(block.range.start.line)–\(block.range.end.line)]"

        if let title = block.title {
            line += "  title=\(title)"
        }
        if let id = block.attributes.id {
            line += "  id=\(id)"
        }
        if let style = block.attributes.style {
            line += "  style=\(style)"
        }
        if !block.lines.isEmpty {
            line += "  \(block.lines.count) line\(block.lines.count == 1 ? "" : "s")"
        }

        print(line)
        dump(block.blocks, indent: indent + 1)
    }
}

if let header = document.header {
    print("header  [\(header.range.start.line)–\(header.range.end.line)]")
    if let title = header.title {
        print("  title: \(title)")
    }
    if let author = header.authorLine {
        print("  author: \(author)")
    }
    for attribute in header.attributes {
        print("  :\(attribute.name)\(attribute.isUnset ? "!" : ""): \(attribute.value)")
    }
}

dump(document.blocks, indent: 0)
