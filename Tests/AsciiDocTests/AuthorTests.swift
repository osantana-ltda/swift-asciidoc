// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

import Testing

@testable import AsciiDoc

@Test func oneNameAndAnAddressParse() {
    let authors = Author.parse(line: "Osvaldo Santana Neto <osvaldo@example.com>")

    #expect(authors.count == 1)
    #expect(authors[0].firstName == "Osvaldo")
    #expect(authors[0].middleName == "Santana")
    #expect(authors[0].lastName == "Neto")
    #expect(authors[0].email == "osvaldo@example.com")
    #expect(authors[0].fullName == "Osvaldo Santana Neto")
    #expect(authors[0].initials == "OSN")
}

@Test func shorterNamesKeepTheirShape() {
    let one = Author.parse(line: "Prince")[0]
    #expect(one.firstName == "Prince")
    #expect(one.middleName == nil)
    #expect(one.lastName == nil)
    #expect(one.initials == "P")

    let two = Author.parse(line: "Ada Lovelace")[0]
    #expect(two.firstName == "Ada")
    #expect(two.lastName == "Lovelace")
    #expect(two.middleName == nil)
    #expect(two.initials == "AL")
}

@Test func underscoresAreSpacesInsideANamePart() {
    let author = Author.parse(line: "Ana_Maria Silva")[0]

    #expect(author.firstName == "Ana Maria")
    #expect(author.lastName == "Silva")
    #expect(author.fullName == "Ana Maria Silva")
}

@Test func semicolonsSeparateAuthors() {
    let authors = Author.parse(line: "Ada Lovelace <ada@x.io>; Alan Turing <alan@x.io>")

    #expect(authors.count == 2)
    #expect(authors[0].fullName == "Ada Lovelace")
    #expect(authors[1].fullName == "Alan Turing")
    #expect(authors[1].email == "alan@x.io")
}

@Test func aLongNameKeepsEveryPart() {
    let author = Author.parse(line: "Jean Baptiste Emmanuel Zorg")[0]

    #expect(author.firstName == "Jean")
    #expect(author.middleName == "Baptiste Emmanuel")
    #expect(author.lastName == "Zorg")
    #expect(author.fullName == "Jean Baptiste Emmanuel Zorg")
}

@Test func theDocumentDerivesAuthorAttributes() {
    let document = Parser.parse(
        "= T\nAda Lovelace <ada@x.io>; Alan Turing <alan@x.io>\n\nText.\n")

    let attributes = document.attributes
    #expect(attributes["author"] == "Ada Lovelace")
    #expect(attributes["firstname"] == "Ada")
    #expect(attributes["lastname"] == "Lovelace")
    #expect(attributes["email"] == "ada@x.io")
    #expect(attributes["authorinitials"] == "AL")
    #expect(attributes["authorcount"] == "2")
    #expect(attributes["author_2"] == "Alan Turing")
    #expect(attributes["email_2"] == "alan@x.io")
}

@Test func aDeclaredAttributeOverridesTheDerivedOne() {
    // Writing `:author:` is how an author line is overridden.
    let document = Parser.parse("= T\nAda Lovelace\n:author: Someone Else\n\nText.\n")

    #expect(document.attributes["author"] == "Someone Else")
    // The line itself is untouched, and still reads as it was written.
    #expect(document.header?.authorLine == "Ada Lovelace")
    #expect(document.header?.authors.first?.fullName == "Ada Lovelace")
}
