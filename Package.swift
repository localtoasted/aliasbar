// swift-tools-version:5.9

import PackageDescription

// The .app is built by build.sh with raw swiftc, and that stays the canonical build:
// it compiles every file in Sources/ against SwiftUI/AppKit, fetches and signs Sparkle,
// and assembles the bundle. SwiftPM is deliberately not asked to do any of that.
//
// What this manifest does own is the Foundation-only core seam — the same file set
// test.sh emits as the AliasBarCore module to prove the core compiles with no app-owned
// source behind it. Declaring it here buys per-test runs, `swift test` coverage, CI, and
// working SourceKit/LSP in editors, none of which the shell scripts can offer.
//
// The sources live flat in Sources/ alongside the app's SwiftUI files, so the target
// points at that directory and names its files explicitly rather than moving anything.
//
// Two things to know before running this:
//   - build.sh clears .build/ on every run, and SwiftPM builds into the same directory.
//     Nothing breaks, but an app build costs the next `swift build` a full rebuild.
//     `swift build --scratch-path .build/spm` avoids that if it becomes annoying.
//   - The test target needs XCTest, which ships with Xcode. Command Line Tools alone
//     are enough for build.sh and test.sh but not for `swift test`.
let package = Package(
    name: "AliasBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AliasBarCore", targets: ["AliasBarCore"]),
    ],
    targets: [
        .target(
            name: "AliasBarCore",
            path: "Sources",
            sources: [
                "Model.swift",
                "ContentHash.swift",
                "SensitiveContentClassifier.swift",
                "ClipboardCapture.swift",
                "ClipTransforms.swift",
                "AliasWriter.swift",
                "Shortcut.swift",
                "PromptStore.swift",
                "PromptCompiler.swift",
                "AuditPrompt.swift",
                "PromptInbox.swift",
                "SharedDocument.swift",
                "SnippetCore.swift",
                "SuggestionEngine.swift",
            ]
        ),
        .testTarget(
            name: "AliasBarCoreTests",
            dependencies: ["AliasBarCore"],
            path: "Tests/AliasBarCoreTests"
        ),
    ]
)
