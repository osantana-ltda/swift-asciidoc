// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// One edit to the source: `length` UTF-16 units at `start` replaced by
/// `replacement`. The shape of what a text view reports.
public struct SourceEdit: Hashable, Sendable {
    public let start: Int
    public let length: Int
    public let replacement: String

    public init(start: Int, length: Int, replacement: String) {
        self.start = start
        self.length = length
        self.replacement = replacement
    }
}

/// Reparses a document after an edit, doing work proportional to the damage
/// rather than to the document — the discipline the editor prototype proved,
/// applied to the real parser.
///
/// The contract is exact: the result must equal `Parser.parse` of the edited
/// source, structurally and positionally, and the tests enforce that over a
/// generated matrix of edits. Three paths, cheapest first:
///
/// 1. **Shift-only.** An edit that touches nothing but blank lines between
///    blocks changes positions, never structure.
/// 2. **Convergent reparse.** Parsing restarts at the damaged block — widened
///    to its metadata lines and to any adjacent block it could merge with —
///    and stops the moment it lands exactly on a following block boundary that
///    the edit did not touch. Everything after is shifted, not reparsed.
/// 3. **Full reparse over the spliced lines**, whenever the edit could change
///    structure beyond the damage: edits in or adjacent to the header, section
///    headings created, removed or changed, a delimiter left open and
///    swallowing the rest of the document. Correct by construction, and it
///    still skips re-splitting the string into lines.
///
/// Offsets are UTF-16 against an LF document. A document whose line positions
/// are not contiguous — CRLF survives in offsets even though text is
/// normalised — is reparsed from its normalised reconstruction as a best
/// effort, and noted as such in the result.
public enum IncrementalParser {
    public struct Result {
        public let document: Document
        /// True when one of the bounded paths applied; false means a full
        /// reparse ran.
        public let incremental: Bool
        /// The line numbers (new numbering, 1-based, half-open) whose content
        /// was re-derived. Empty for a shift-only edit; the whole document for
        /// a full reparse.
        public let reparsedLines: Range<Int>
    }

    public static func reparse(_ previous: Document, applying edit: SourceEdit) -> Result {
        precondition(
            !previous.sourceLines.isEmpty || previous.sourceLength == 0,
            "incremental reparse needs a document that came from Parser.parse"
        )
        precondition(
            edit.start >= 0 && edit.start + edit.length <= previous.sourceLength,
            "edit outside the document"
        )

        guard let splice = splice(previous.sourceLines, length: previous.sourceLength, edit: edit)
        else {
            // Irregular offsets (a CRLF document): best effort on the
            // normalised reconstruction.
            let reconstructed = reconstruct(previous)
            let edited = apply(edit, to: reconstructed)
            let document = Parser.parse(edited)
            return Result(
                document: document,
                incremental: false,
                reparsedLines: 1..<(document.sourceLineCount + 1)
            )
        }

        if let result = shiftOnly(previous, splice) {
            return result
        }

        if let result = convergentReparse(previous, splice) {
            return result
        }

        let document = Parser.parse(lines: splice.lines, sourceLength: splice.length)
        return Result(
            document: document,
            incremental: false,
            reparsedLines: 1..<(splice.lines.count + 1)
        )
    }

    // MARK: - Line splice

    struct Splice {
        var lines: [SourceLine]
        var length: Int
        /// Old line numbers touched by the edit (1-based, half-open).
        var oldDamage: Range<Int>
        /// New line numbers the fragment occupies (1-based, half-open).
        var newDamage: Range<Int>
        var deltaOffset: Int
        var deltaLines: Int
        var fragmentIsBlank: Bool
        var replacedWasBlank: Bool
    }

    /// Splices the edit into the retained line array without touching the rest
    /// of the source. Returns nil when the line offsets are not contiguous and
    /// the region cannot be reconstructed faithfully.
    static func splice(
        _ old: [SourceLine],
        length oldLength: Int,
        edit: SourceEdit
    ) -> Splice? {
        let replacementLength = edit.replacement.utf16.count
        let deltaOffset = replacementLength - edit.length

        guard !old.isEmpty else {
            let fresh = LineReader.lines(of: edit.replacement)
            return Splice(
                lines: fresh,
                length: replacementLength,
                oldDamage: 1..<1,
                newDamage: 1..<(fresh.count + 1),
                deltaOffset: deltaOffset,
                deltaLines: fresh.count,
                fragmentIsBlank: fresh.allSatisfy(\.isBlank),
                replacedWasBlank: true
            )
        }

        let editEnd = edit.start + edit.length
        let first = index(ofLineContaining: edit.start, in: old)
        let last = index(ofLineContaining: editEnd, in: old)

        // The region is rebuilt from line texts joined by single newlines, so
        // the lines must actually sit one unit apart in the source.
        for i in first..<last
        where old[i + 1].range.start.offset != old[i].range.end.offset + 1 {
            return nil
        }
        let isFinal = last == old.count - 1
        if isFinal, editEnd > old[last].range.end.offset,
            oldLength != old[last].range.end.offset + 1
        {
            return nil
        }

        let regionStart = old[first].range.start.offset
        var units = Array(old[first...last].map(\.text).joined(separator: "\n").utf16)

        // An edit reaching into the document-final terminator absorbs it, so
        // text typed after it lands on a new line.
        if isFinal, editEnd > old[last].range.end.offset {
            units.append(0x0A)
        }

        // The fragment follows whole-document trailing rules only when the
        // region truly reaches the end of the source: covering the last line
        // is not enough if the document's final newline sits after the edit,
        // untouched — the fragment is interior in the byte sense, and a
        // trailing newline it produces is a real empty line before it.
        let reachesEnd =
            isFinal
            && (editEnd > old[last].range.end.offset
                || oldLength == old[last].range.end.offset)

        let localStart = min(edit.start - regionStart, units.count)
        let localEnd = min(max(editEnd - regionStart, localStart), units.count)
        let rebuilt = String(
            decoding: units[..<localStart] + Array(edit.replacement.utf16) + units[localEnd...],
            as: UTF16.self
        )

        var fragment = LineReader.lines(of: rebuilt)
        if !reachesEnd {
            if rebuilt.isEmpty {
                fragment = [
                    SourceLine(
                        text: "",
                        range: SourceRange(
                            start: SourceLocation(offset: 0, line: 1, column: 1),
                            end: SourceLocation(offset: 0, line: 1, column: 1)
                        ),
                        number: 1
                    )
                ]
            } else if rebuilt.utf16.last == 0x0A {
                let offset = rebuilt.utf16.count
                fragment.append(
                    SourceLine(
                        text: "",
                        range: SourceRange(
                            start: SourceLocation(offset: offset, line: fragment.count + 1, column: 1),
                            end: SourceLocation(offset: offset, line: fragment.count + 1, column: 1)
                        ),
                        number: fragment.count + 1
                    )
                )
            }
        }

        let placed = fragment.map { shift($0, offsetBy: regionStart, linesBy: first) }
        let deltaLines = placed.count - (last - first + 1)
        let tail = old[(last + 1)...].map { shift($0, offsetBy: deltaOffset, linesBy: deltaLines) }

        return Splice(
            lines: Array(old[..<first]) + placed + tail,
            length: oldLength + deltaOffset,
            oldDamage: (first + 1)..<(last + 2),
            newDamage: (first + 1)..<(first + 1 + placed.count),
            deltaOffset: deltaOffset,
            deltaLines: deltaLines,
            fragmentIsBlank: placed.allSatisfy(\.isBlank),
            replacedWasBlank: old[first...last].allSatisfy(\.isBlank)
        )
    }

    /// The last line whose start is at or before `offset`.
    private static func index(ofLineContaining offset: Int, in lines: [SourceLine]) -> Int {
        var low = 0
        var high = lines.count - 1
        var found = 0

        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].range.start.offset <= offset {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }

        return found
    }

    // MARK: - Path 1: shift only

    private static func shiftOnly(_ previous: Document, _ splice: Splice) -> Result? {
        guard splice.fragmentIsBlank, splice.replacedWasBlank else {
            return nil
        }
        guard splice.oldDamage.lowerBound > headerFloor(of: previous) else {
            return nil
        }
        guard !damageTouchesContent(previous.blocks, splice.oldDamage) else {
            return nil
        }

        let blocks = shiftSpanning(
            previous.blocks,
            damage: splice.oldDamage,
            offsetBy: splice.deltaOffset,
            linesBy: splice.deltaLines
        )

        return Result(
            document: assemble(previous, blocks: blocks, splice: splice),
            incremental: true,
            reparsedLines: splice.newDamage.lowerBound..<splice.newDamage.lowerBound
        )
    }

    // MARK: - Path 2: convergent reparse

    private static func convergentReparse(_ previous: Document, _ splice: Splice) -> Result? {
        guard splice.oldDamage.lowerBound > headerFloor(of: previous) else {
            return nil
        }

        guard var site = locate(in: previous.blocks, damage: splice.oldDamage, path: []) else {
            return nil
        }

        let parent = container(at: site.path, in: previous.blocks)

        // Widen upward: a non-blank line directly above the restart belongs to
        // the previous sibling, and the edit could merge into it.
        while site.children.lowerBound > 0 {
            let restartOld = replacedStartLine(parent, site, splice)
            guard restartOld > 1 else {
                break
            }
            let above = previous.sourceLines[restartOld - 2]
            let sibling = parent[site.children.lowerBound - 1]
            guard !above.isBlank, sibling.range.end.line == above.number else {
                break
            }
            site.children = (site.children.lowerBound - 1)..<site.children.upperBound
        }

        // The replaced children must be plain blocks; structure changes fall
        // back.
        for child in parent[site.children] {
            switch child.kind {
            case .section, .preamble:
                return nil
            default:
                break
            }
        }

        // A non-empty fragment at the top level of a headered document would
        // need preamble bookkeeping; the full parser owns that.
        if site.path.isEmpty, previous.header != nil {
            return nil
        }

        // Convergence targets: following siblings, then the first boundary
        // owned by an ancestor.
        let siblingTargets: [(oldLine: Int, index: Int)] = parent[site.children.upperBound...]
            .enumerated()
            .map { ($0.element.range.start.line, site.children.upperBound + $0.offset) }
        let ancestorTarget = boundaryAfter(path: site.path, in: previous.blocks)

        // Parse from the restart line until convergence.
        let restartNew = replacedStartLine(parent, site, splice)
        var state = Parser.State(lines: splice.lines)
        state.index = restartNew - 1

        var fragment: [Block] = []
        var replacedUpper: Int?
        var consumedThroughNew = 0

        while true {
            state.skipBlankLines()

            guard let line = state.current else {
                if siblingTargets.isEmpty, ancestorTarget == nil {
                    replacedUpper = parent.count
                    consumedThroughNew = splice.lines.count + 1
                }
                break
            }

            // Line numbers map back to old numbering only past the fragment.
            if line.number >= splice.newDamage.upperBound {
                let oldLine = line.number - splice.deltaLines

                if let hit = siblingTargets.first(where: { $0.oldLine == oldLine }) {
                    replacedUpper = hit.index
                    consumedThroughNew = line.number
                    break
                }
                if oldLine == ancestorTarget {
                    replacedUpper = parent.count
                    consumedThroughNew = line.number
                    break
                }
                if let ancestor = ancestorTarget, oldLine > ancestor {
                    return nil
                }
            }

            guard let block = state.parseBlock() else {
                continue
            }

            switch block.kind {
            case .section, .preamble:
                return nil
            default:
                fragment.append(block)
            }
        }

        guard let upper = replacedUpper else {
            return nil
        }

        // Emptying a preamble removes it; that is the full parser's decision.
        if isPreamble(at: site.path, in: previous.blocks), fragment.isEmpty,
            site.children.lowerBound == 0, upper == parent.count
        {
            return nil
        }

        let blocks = rebuild(
            previous.blocks,
            path: site.path[...],
            replacing: site.children.lowerBound..<upper,
            with: fragment,
            offsetBy: splice.deltaOffset,
            linesBy: splice.deltaLines
        )

        return Result(
            document: assemble(previous, blocks: blocks, splice: splice),
            incremental: true,
            reparsedLines: restartNew..<consumedThroughNew
        )
    }

    /// Where reparsing starts, in new line numbering: the first replaced
    /// child's start line (unchanged, since it precedes the damage) or the
    /// fragment itself for an insertion into a gap.
    private static func replacedStartLine(
        _ parent: [Block],
        _ site: Site,
        _ splice: Splice
    ) -> Int {
        guard site.children.lowerBound < site.children.upperBound else {
            return splice.newDamage.lowerBound
        }
        return min(
            parent[site.children.lowerBound].range.start.line,
            splice.newDamage.lowerBound
        )
    }

    // MARK: - Damage location

    private struct Site {
        var path: [Int]
        var children: Range<Int>
    }

    private static func locate(in blocks: [Block], damage: Range<Int>, path: [Int]) -> Site? {
        var first: Int?
        var last: Int?

        for (index, block) in blocks.enumerated() {
            let span = block.range.start.line..<(block.range.end.line + 1)
            if span.overlaps(damage) {
                first = first ?? index
                last = index
            }
        }

        guard let firstIndex = first, let lastIndex = last else {
            // The damage sits in a gap. Content there continues the preceding
            // container, when there is one.
            let insertion =
                blocks.firstIndex { $0.range.start.line >= damage.upperBound } ?? blocks.count
            if insertion > 0, isContainer(blocks[insertion - 1].kind) {
                return locate(
                    in: blocks[insertion - 1].blocks,
                    damage: damage,
                    path: path + [insertion - 1]
                )
            }
            return Site(path: path, children: insertion..<insertion)
        }

        // Damage inside a single container's children descends into it, as
        // long as the container's own lines are untouched.
        if firstIndex == lastIndex, isContainer(blocks[firstIndex].kind),
            !ownLinesTouched(blocks[firstIndex], damage)
        {
            return locate(in: blocks[firstIndex].blocks, damage: damage, path: path + [firstIndex])
        }

        return Site(path: path, children: firstIndex..<(lastIndex + 1))
    }

    private static func isContainer(_ kind: Block.Kind) -> Bool {
        switch kind {
        case .section, .preamble: true
        default: false
        }
    }

    private static func ownLinesTouched(_ block: Block, _ damage: Range<Int>) -> Bool {
        if let opening = block.opening, damage.contains(opening.number) {
            return true
        }
        return block.prelude.contains { damage.contains($0.number) }
    }

    private static func damageTouchesContent(_ blocks: [Block], _ damage: Range<Int>) -> Bool {
        for block in blocks {
            let span = block.range.start.line..<(block.range.end.line + 1)
            guard span.overlaps(damage) else {
                continue
            }
            guard isContainer(block.kind) else {
                return true
            }
            if ownLinesTouched(block, damage) || damageTouchesContent(block.blocks, damage) {
                return true
            }
        }
        return false
    }

    private static func container(at path: [Int], in blocks: [Block]) -> [Block] {
        var current = blocks
        for index in path {
            current = current[index].blocks
        }
        return current
    }

    private static func isPreamble(at path: [Int], in blocks: [Block]) -> Bool {
        guard let lastIndex = path.last else {
            return false
        }
        var current = blocks
        for index in path.dropLast() {
            current = current[index].blocks
        }
        return current[lastIndex].kind == .preamble
    }

    /// The start line of the first old block owned by an ancestor after the
    /// parent — where a tail-consuming reparse is allowed to stop.
    private static func boundaryAfter(path: [Int], in blocks: [Block]) -> Int? {
        var levels: [[Block]] = [blocks]
        var current = blocks
        for index in path {
            current = current[index].blocks
            levels.append(current)
        }

        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let siblings = levels[depth]
            let next = path[depth] + 1
            if next < siblings.count {
                return siblings[next].range.start.line
            }
        }

        return nil
    }

    // MARK: - Tree rebuild

    private static func rebuild(
        _ blocks: [Block],
        path: ArraySlice<Int>,
        replacing: Range<Int>,
        with fragment: [Block],
        offsetBy deltaOffset: Int,
        linesBy deltaLines: Int
    ) -> [Block] {
        guard let step = path.first else {
            return Array(blocks[..<replacing.lowerBound])
                + fragment
                + blocks[replacing.upperBound...].map {
                    shift($0, offsetBy: deltaOffset, linesBy: deltaLines)
                }
        }

        var result = Array(blocks[..<step])
        var updated = blocks[step]
        updated.blocks = rebuild(
            updated.blocks,
            path: path.dropFirst(),
            replacing: replacing,
            with: fragment,
            offsetBy: deltaOffset,
            linesBy: deltaLines
        )
        updated.range = SourceRange(
            start: updated.range.start,
            end: updated.blocks.last?.range.end
                ?? updated.opening?.range.end
                ?? updated.range.start
        )
        result.append(updated)
        result += blocks[(step + 1)...].map {
            shift($0, offsetBy: deltaOffset, linesBy: deltaLines)
        }
        return result
    }

    /// For shift-only edits: containers spanning the blank gap keep their
    /// start, shift what follows, and recompute their end.
    private static func shiftSpanning(
        _ blocks: [Block],
        damage: Range<Int>,
        offsetBy deltaOffset: Int,
        linesBy deltaLines: Int
    ) -> [Block] {
        blocks.map { block in
            if block.range.end.line < damage.lowerBound {
                return block
            }
            if block.range.start.line >= damage.upperBound {
                return shift(block, offsetBy: deltaOffset, linesBy: deltaLines)
            }
            var updated = block
            updated.blocks = shiftSpanning(
                block.blocks,
                damage: damage,
                offsetBy: deltaOffset,
                linesBy: deltaLines
            )
            updated.range = SourceRange(
                start: block.range.start,
                end: updated.blocks.last?.range.end ?? block.range.end
            )
            return updated
        }
    }

    // MARK: - Assembly

    private static func headerFloor(of document: Document) -> Int {
        if let header = document.header {
            return (header.lines.last?.number ?? 0) + 1
        }
        return document.blocks.first?.range.start.line ?? Int.max
    }

    private static func assemble(
        _ previous: Document,
        blocks: [Block],
        splice: Splice
    ) -> Document {
        let start = previous.header?.range.start ?? blocks.first?.range.start
        let end = blocks.last?.range.end ?? previous.header?.range.end

        return Document(
            header: previous.header,
            blocks: blocks,
            range: SourceRange(
                start: start ?? SourceLocation(offset: 0, line: 1, column: 1),
                end: end ?? SourceLocation(offset: 0, line: 1, column: 1)
            ),
            endsInNewline: (splice.lines.last?.range.end.offset ?? 0) < splice.length,
            sourceLineCount: splice.lines.count,
            sourceLines: splice.lines,
            sourceLength: splice.length
        )
    }

    private static func reconstruct(_ document: Document) -> String {
        document.sourceLines.map(\.text).joined(separator: "\n")
            + (document.endsInNewline && !document.sourceLines.isEmpty ? "\n" : "")
    }

    private static func apply(_ edit: SourceEdit, to source: String) -> String {
        let units = Array(source.utf16)
        let start = min(edit.start, units.count)
        let end = min(edit.start + edit.length, units.count)
        return String(
            decoding: units[..<start] + Array(edit.replacement.utf16) + units[end...],
            as: UTF16.self
        )
    }

    // MARK: - Shifting

    private static func shift(_ location: SourceLocation, offsetBy dOffset: Int, linesBy dLines: Int)
        -> SourceLocation
    {
        SourceLocation(
            offset: location.offset + dOffset,
            line: location.line + dLines,
            column: location.column
        )
    }

    private static func shift(_ range: SourceRange, offsetBy dOffset: Int, linesBy dLines: Int)
        -> SourceRange
    {
        SourceRange(
            start: shift(range.start, offsetBy: dOffset, linesBy: dLines),
            end: shift(range.end, offsetBy: dOffset, linesBy: dLines)
        )
    }

    private static func shift(_ line: SourceLine, offsetBy dOffset: Int, linesBy dLines: Int)
        -> SourceLine
    {
        SourceLine(
            text: line.text,
            range: shift(line.range, offsetBy: dOffset, linesBy: dLines),
            number: line.number + dLines
        )
    }

    private static func shift(_ title: Title, offsetBy dOffset: Int, linesBy dLines: Int) -> Title {
        Title(text: title.text, range: shift(title.range, offsetBy: dOffset, linesBy: dLines))
    }

    private static func shift(_ block: Block, offsetBy dOffset: Int, linesBy dLines: Int) -> Block {
        var attributes = block.attributes
        attributes.range = attributes.range.map {
            shift($0, offsetBy: dOffset, linesBy: dLines)
        }

        return Block(
            kind: block.kind,
            range: shift(block.range, offsetBy: dOffset, linesBy: dLines),
            title: block.title.map { shift($0, offsetBy: dOffset, linesBy: dLines) },
            attributes: attributes,
            blocks: block.blocks.map { shift($0, offsetBy: dOffset, linesBy: dLines) },
            lines: block.lines.map { shift($0, offsetBy: dOffset, linesBy: dLines) },
            prelude: block.prelude.map { shift($0, offsetBy: dOffset, linesBy: dLines) },
            opening: block.opening.map { shift($0, offsetBy: dOffset, linesBy: dLines) },
            closing: block.closing.map { shift($0, offsetBy: dOffset, linesBy: dLines) }
        )
    }
}
