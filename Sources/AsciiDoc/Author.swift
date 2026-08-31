// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

/// One author of a document, as the header's author line names them.
///
/// AsciiDoc gives a name up to three parts and an optional address:
/// `Firstname Middlename Lastname <email>`, several authors separated by
/// semicolons. An underscore inside a part is a space that must not be read
/// as a separator — `Ana_Maria Silva` is one first name, not two names.
public struct Author: Hashable, Sendable {
    public var firstName: String
    public var middleName: String?
    public var lastName: String?
    public var email: String?

    public init(
        firstName: String,
        middleName: String? = nil,
        lastName: String? = nil,
        email: String? = nil
    ) {
        self.firstName = firstName
        self.middleName = middleName
        self.lastName = lastName
        self.email = email
    }

    /// The name as written, parts rejoined by spaces.
    public var fullName: String {
        [firstName, middleName, lastName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// One letter per name part, AsciiDoc's `authorinitials`.
    public var initials: String {
        [firstName, middleName, lastName]
            .compactMap { $0 }
            .compactMap { $0.first.map(String.init) }
            .joined()
    }

    // MARK: - Parsing

    /// Reads an author line into its authors. The line stays the source of
    /// truth — this is a reading of it, computed on demand, so the header
    /// still round-trips exactly as written.
    public static func parse(line: String) -> [Author] {
        line.split(separator: ";")
            .compactMap { parse(entry: String($0)) }
    }

    static func parse(entry: String) -> Author? {
        var name = entry
        var email: String?

        // `<address>` closes the entry; anything after it is ignored, as
        // Asciidoctor does.
        if let open = name.firstIndex(of: "<"),
            let close = name[open...].firstIndex(of: ">")
        {
            email = String(name[name.index(after: open)..<close]).trimmed
            name = String(name[name.startIndex..<open])
        }

        let parts =
            name
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.replacingUnderscoresWithSpaces }
            .filter { !$0.isEmpty }

        guard let first = parts.first else {
            // An entry with an address but no name is still an author.
            return email.map { Author(firstName: "", email: $0) }
        }

        switch parts.count {
        case 1:
            return Author(firstName: first, email: email)
        case 2:
            return Author(firstName: first, lastName: parts[1], email: email)
        default:
            // Everything between the first and last part is the middle name,
            // so a four-part name keeps all of itself.
            return Author(
                firstName: first,
                middleName: parts[1..<(parts.count - 1)].joined(separator: " "),
                lastName: parts[parts.count - 1],
                email: email
            )
        }
    }
}

extension StringProtocol {
    /// Trimmed of spaces and tabs at both ends.
    var trimmed: String {
        var slice = self[...]
        while let first = slice.first, first == " " || first == "\t" {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == " " || last == "\t" {
            slice = slice.dropLast()
        }
        return String(slice)
    }

    /// AsciiDoc writes a space inside a name part as an underscore.
    var replacingUnderscoresWithSpaces: String {
        String(map { $0 == "_" ? " " : $0 })
    }
}
