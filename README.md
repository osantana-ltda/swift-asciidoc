# swift-asciidoc

An AsciiDoc parser and serializer in Swift, with source locations, incremental
reparsing, and conformance to the Eclipse AsciiDoc Language specification.

There is no native Swift AsciiDoc implementation today. This is intended to
become one, usable by any Swift project rather than only by the editor it is
being written for.

## Status

**Skeleton.** The package builds and its structure is in place; the parser is not
implemented. The TCK adapter deliberately exits non-zero until it is.

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
ASCIIDOC_TCK_ADAPTER=.build/debug/asciidoc-tck-adapter asciidoc-tck
```

Two things the TCK does not do: it does not cover conversion to HTML or DocBook,
and it cannot certify behaviour the specification does not yet define. Where the
specification is silent, Asciidoctor's behaviour is the reference. Gaps in
coverage are to be recorded rather than discovered by someone else's document.

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
