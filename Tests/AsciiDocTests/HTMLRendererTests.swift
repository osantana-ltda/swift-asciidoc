// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import AsciiDoc

private func html(_ source: String) -> String {
    HTMLRenderer.render(Parser.parse(source))
}

@Test func headerAndSectionsBecomeHeadings() {
    let out = html("= Book Title\nAn Author\n\n== Chapter\n\nText.\n\n=== Deep\n")
    #expect(out.contains("<h1>Book Title</h1>"))
    #expect(out.contains("<p class=\"author\">An Author</p>"))
    #expect(out.contains("<h2>Chapter</h2>"))
    #expect(out.contains("<h3>Deep</h3>"))
    #expect(out.contains("<p>Text.</p>"))
}

@Test func inlineFormattingRenders() {
    let out = html("= T\n\nSome *bold*, _italic_ and `mono` text.\n")
    #expect(out.contains("<strong>bold</strong>"))
    #expect(out.contains("<em>italic</em>"))
    #expect(out.contains("<code>mono</code>"))
}

@Test func linksBecomeAnchors() {
    let out = html("= T\n\nSee https://example.com[the site] and https://bare.example.\n")
    #expect(out.contains("<a href=\"https://example.com\">the site</a>"))
    #expect(out.contains("<a href=\"https://bare.example\">https://bare.example</a>"))
}

@Test func listingsEscapeAndCarryTheirLanguage() {
    let out = html("= T\n\n[source,swift]\n----\nlet a = b < c\n----\n")
    #expect(out.contains("<pre><code class=\"language-swift\">let a = b &lt; c</code></pre>"))
}

@Test func quotesListsAndAdmonitionsRender() {
    let out = html(
        "= T\n\n____\nQuoted words.\n____\n\n* First item\n* Second item\n\nNOTE: Mind this.\n")
    #expect(out.contains("<blockquote><p>Quoted words.</p>\n</blockquote>"))
    #expect(out.contains("<li>First item</li>"))
    #expect(out.contains("<li>Second item</li>"))
    #expect(out.contains("class=\"admonition note\""))
    #expect(out.contains("Mind this."))
}

@Test func listItemsRenderTheirInlineFormattingOnce() {
    let out = html("= T\n\n* A *bold* item\n* Plain item\n")
    #expect(out.contains("<li>A <strong>bold</strong> item</li>"))
    #expect(!out.contains("&lt;strong&gt;"))
}

@Test func passthroughIsRawAndUnparsedIsEscaped() {
    let out = html("= T\n\n++++\n<video controls></video>\n++++\n")
    #expect(out.contains("<video controls></video>"))
    #expect(!out.contains("&lt;video"))
}

@Test func tablesRenderRowsAndCells() {
    let out = html("= T\n\n|===\n| A | B\n\n| one | two\n|===\n")
    #expect(out.contains("<table>"))
    #expect(out.contains("<td>one</td>"))
    #expect(out.contains("</table>"))
}

@Test func commentsAndAttributeEntriesLeaveNoTrace() {
    let out = html("= T\n:toc: left\n\n// a note to authors\n\nVisible.\n")
    #expect(!out.contains("note to authors"))
    #expect(!out.contains("toc"))
    #expect(out.contains("<p>Visible.</p>"))
}

@Test func textIsEscaped() {
    let out = html("= T\n\nMind a < b & c > d.\n")
    #expect(out.contains("Mind a &lt; b &amp; c &gt; d."))
}
