import Testing

@testable import AsciiDoc

@Test func locationsOrderByOffset() {
    let first = SourceLocation(offset: 0, line: 1, column: 1)
    let second = SourceLocation(offset: 7, line: 2, column: 3)

    #expect(first < second)
}

@Test func rangeExcludesItsEndLocation() {
    let start = SourceLocation(offset: 4, line: 1, column: 5)
    let end = SourceLocation(offset: 9, line: 1, column: 10)
    let range = SourceRange(start: start, end: end)

    #expect(range.contains(start))
    #expect(!range.contains(end))
    #expect(!range.isEmpty)
}
