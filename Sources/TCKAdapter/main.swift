import Foundation

// Adapter for the Eclipse AsciiDoc Technology Compatibility Kit.
//
// The harness runs this executable once per test case: a JSON object arrives on
// stdin carrying `contents`, `path` and a `type` of "block" or "inline"; the
// Abstract Semantic Graph is expected on stdout as JSON, with exit code 0.
//
// The parser is not implemented yet, so this exits non-zero, which the harness
// reads as a failed case. That is the honest result — reporting success without
// a parser would make the conformance report meaningless.

FileHandle.standardError.write(
    Data("asciidoc-tck-adapter: the parser is not implemented yet\n".utf8)
)
exit(1)
