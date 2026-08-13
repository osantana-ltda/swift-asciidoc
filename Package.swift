// swift-tools-version: 6.3
// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

// No `platforms:` clause on purpose. This package is pure Swift with no
// dependency on Apple frameworks, so it should build everywhere the toolchain
// runs — including Linux, where the TCK adapter and CI need it.
let package = Package(
    name: "swift-asciidoc",
    products: [
        .library(name: "AsciiDoc", targets: ["AsciiDoc"]),
        .executable(name: "asciidoc-tck-adapter", targets: ["TCKAdapter"]),
    ],
    targets: [
        .target(name: "AsciiDoc"),
        .executableTarget(name: "TCKAdapter", dependencies: ["AsciiDoc"]),
        .testTarget(name: "AsciiDocTests", dependencies: ["AsciiDoc"]),
    ]
)
