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

let input = FileHandle.standardInput.readDataToEndOfFile()

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
        // Inline parsing is not implemented. Failing is the honest answer;
        // emitting an empty graph would report a pass that is not one.
        FileHandle.standardError.write(
            Data("asciidoc-tck-adapter: inline parsing is not implemented\n".utf8)
        )
        exit(1)
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
    case .listItem: "item"
    case .comment: "comment"
    case .attributeEntry: "attribute"
    case .unparsed: "unparsed"
    }
}

func dump(_ blocks: [Block], indent: Int) {
    for block in blocks {
        var line = String(repeating: "  ", count: indent) + describe(block.kind)
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
