// swift-tools-version: 6.1
// Copyright (C) 2026 Osvaldo Santana Neto
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

// No `platforms:` clause on purpose. This package is pure Swift with no
// dependency on Apple frameworks, so it builds everywhere the toolchain runs —
// including Linux, where the TCK adapter and CI need it. Verified rather than
// assumed: the suite passes under swift:6.1, 6.2 and 6.3 on Linux.
//
// The tools version is the floor that was measured, not the one the package
// happened to be written on. It said 6.3 for no reason, which locked out every
// toolchain older than a few weeks — including the newest Xcode on GitHub's
// macOS runners. A library nobody can adopt is not much of a library.
let package = Package(
    name: "swift-asciidoc",
    products: [
        .library(name: "AsciiDoc", targets: ["AsciiDoc"]),
        .executable(name: "asciidoc-tck-adapter", targets: ["TCKAdapter"]),
    ],
    targets: [
        .target(name: "AsciiDoc"),
        .executableTarget(name: "TCKAdapter", dependencies: ["AsciiDoc"]),
        .testTarget(
            name: "AsciiDocTests",
            dependencies: ["AsciiDoc"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
