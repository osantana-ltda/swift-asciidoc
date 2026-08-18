# swift-asciidoc

An AsciiDoc parser and serializer in Swift, with source locations, incremental
reparsing, and conformance to the Eclipse AsciiDoc Language specification.

There is no native Swift AsciiDoc implementation today. This is intended to
become one, usable by any Swift project rather than only by the editor it is
being written for.

## Status

**Block structure parses, and the core inline spans do.**

`Parser.parse(_:)` returns a document of nested blocks, each carrying its exact
source range: document header with attribute entries, preambles, sections
nested by level, paragraphs, admonitions, delimited blocks (listing, literal,
quote, example, sidebar, passthrough, open, comment), tables with rows and
cells, block titles and attribute lists including shorthand, line and block
comments, and simple lists.

Inside paragraphs, admonitions, list items and table cells,
`InlineParser.parse(_:)` produces the inline tree: strong, emphasis, code, mark,
superscript and subscript, in both constrained and unconstrained forms, nested,
with escapes, across line breaks — plus the inline macros. `name:target[attrs]`
parses for the known names (`link`, `mailto`, `xref`, `image`, `icon`, `kbd`,
`btn`, `menu`, `footnote`, `pass`, `stem`, `latexmath`, `asciimath`), the way
Asciidoctor recognises only registered macros — an unknown name stays text.
Bare URLs become `link` macros with trailing punctuation left outside, and
`<<target,text>>` normalises to an `xref` macro. Every node extracts from the
source to exactly the text it claims to cover — the property the editor's
decoration consumes. Blocks keep their raw lines; the inline tree is derived on
demand.

Anything not modelled is kept as an `.unparsed` block rather than dropped or
guessed at, so a table survives a round trip through a parser that does not yet
understand tables.

### Not yet implemented

- Attribute references (`{name}`) and inline anchors — their syntax passes
  through as text.
- A macro's attribute list stays raw; splitting it into positional and named
  attributes is not done yet.
- Inline parsing of section and block titles.
- Table cell specifiers (`2+|`, `a|`, alignments) and the csv/dsv table
  flavours — a specifier stays as part of the cell's text.
- Description lists and list continuation (`+`).
- Nested lists: a deeper marker stays with the item that precedes it.
- `include::`, `ifdef::` and the rest of the preprocessor.
- Author and revision lines are captured verbatim, not split into fields.
- Incremental reparsing. The editor prototype has shown what that needs; this
  parser reparses from the top.

## Scope

This package knows AsciiDoc and nothing else:

| In | Out |
|---|---|
| Lexer and incremental parser | Anything about books, chapters or projects |
| Syntax tree with source ranges | Document identity, versioning, collaboration |
| Abstract Semantic Graph encoding | Rendering to HTML, PDF or other outputs |
| Deterministic serializer back to AsciiDoc | Editor concerns |

The boundary is deliberate. A consumer maps between its own document model and
this tree; nothing in the public API should be named for a particular use of
AsciiDoc.

## Layout

```
Sources/AsciiDoc/       The library
Sources/TCKAdapter/     asciidoc-tck-adapter, the conformance harness adapter
Tests/AsciiDocTests/    Tests, written with Swift Testing
```

## Building

```bash
swift build
```

```bash
swift test
```

## Conformance

Correctness is measured against the [AsciiDoc Technology Compatibility
Kit](https://gitlab.eclipse.org/eclipse/asciidoc-lang/asciidoc-tck), which is
runtime-agnostic: the harness invokes an adapter executable, passing a JSON
object on stdin with the document `contents`, a `path` and a `type` of `block` or
`inline`, and expects the Abstract Semantic Graph as JSON on stdout.

Point the harness at the adapter built here:

```bash
asciidoc-tck cli -c /path/to/.build/release/asciidoc-tck-adapter
```

**Current result: all 13 tests pass** — every block case and both inline cases.

### The TCK is small, so most coverage has to come from elsewhere

Its corpus is thirteen block cases and two inline ones. That is enough to anchor
the encoding and nothing like enough to trust a parser on. Three other sources
fill the gap:

1. **Our own fixtures, written in the TCK's format** (`Tests/AsciiDocTests/
   Fixtures/`), so a case can be contributed upstream rather than rewritten.
   These are *regression* fixtures: the expected files were generated from this
   parser and read once by eye. They make a change visible as a diff; they do
   not prove the behaviour is correct.
2. **Invariants over awkward input** — ranges inside the document, ranges running
   forwards, and parsing that terminates. These catch the arithmetic slips that
   otherwise surface as decoration drawn on the wrong characters.
3. **Asciidoctor as an oracle**, where the specification is silent:

   ```bash
   swift build -c release
   tools/compare-with-asciidoctor.py path/to/corpus
   ```

   `tools/asciidoctor-oracle.rb` walks Asciidoctor's own parse tree and emits
   the same graph; the Python script runs both over a corpus and prints the
   block outlines side by side wherever they disagree.

   Two caveats, both in the scripts' own comments. It is **not an authority**:
   Asciidoctor does not produce an ASG, so the mapping is *our reading* of how
   the two correspond, and a disagreement sometimes means the mapping is wrong.
   And it **cannot compare positions** — Asciidoctor's sourcemap records the
   line a block starts on and nothing else, so locations are checked separately.

   It earned its place immediately. Run against the TCK's own README, it found
   that a style in the attribute list outranks the delimiter: `[source]` over
   `....` is a listing rather than a literal, and `[source]` over bare lines is
   a listing rather than a paragraph. Both were wrong here and are now fixed.

   It has since found and closed four more gaps: content between the header and
   the first section becomes a `preamble` (only when the document has both a
   header and a section — established by probing Asciidoctor, since the
   specification does not say); `TIP:` and friends are admonitions, as is a
   `[NOTE]`-styled block; a style that turns a paragraph into a compound block
   nests the text as a child paragraph, so `[quote]` over a paragraph is a quote
   *containing* a paragraph; and Markdown's `>` blockquote is a quote block,
   which Asciidoctor accepts and the TCK has no case for.

   Tables closed the last of those gaps: rows and cells parse with exact
   ranges, with the rules probed rather than assumed — the column count comes
   from `cols` or from the first line's cell count, cells pool across lines and
   group into rows of that count, and the first row becomes the head on
   `%header` or when a blank line follows it. **The whole comparison corpus now
   agrees with Asciidoctor, 20 of 20 documents.**

A fourth, once a serializer exists: **round-trip testing needs no expected
output at all.** Parse any real AsciiDoc document, write it back, and require
the bytes to match. Every `.adoc` file in the world becomes a test case.

## Repository

This package currently lives inside the Bookled repository while the two change
together, and will be extracted into its own repository once that settles. It
must build, test and make sense on its own in the meantime — nothing here may
depend on the surrounding application.

## Licence

**AGPL-3.0-only.** See `LICENSE`. Copyright (C) 2026 Osvaldo Santana Neto.

The package is dual-licensed: it is published under AGPL-3.0, and the Bookled
application uses it under separate terms granted by the copyright holder.

**Contributions require a contributor licence agreement.** Dual licensing depends
on single ownership of the copyright — code merged without a CLA cannot be
relicensed, so it cannot be accepted. If you are planning a contribution, raise
it before writing it.
