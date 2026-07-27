#!/bin/bash
# The Swift compiler flags every swiftc invocation in this repo builds under.
#
# Sourced (never executed directly) by build.sh, test.sh and tools/release-cli.sh.
# There used to be one independent copy of the array in each of them. Three separate
# declarations of a single contract is a ratchet that loosens by accident: bump two and
# forget the third and the shipped `ab` binary is built under a weaker check than the
# one test.sh proved. Change the flags here, once, and every path moves together.
#
# Package.swift declares the same set for SwiftPM (`concurrencySwiftSettings`). A
# manifest is Swift, not shell, so it cannot source this file — that one copy is
# unavoidable and is the only place that has to be edited alongside this one.
#
# Usage:
#   source "${PROJECT_DIR}/tools/swift-flags.sh"
#   swiftc "${SWIFT_CONCURRENCY_FLAGS[@]}" ...

# Every target: the app, the AliasBarCore module, the writer tests, and both `ab`
# builds. `targeted` rather than `complete` because the SwiftUI/AppKit surface is not
# clean under `complete` yet; raising it is its own piece of work.
SWIFT_CONCURRENCY_FLAGS=(
    -warn-concurrency
    -strict-concurrency=targeted
)

# The `ab` CLI only — Model.swift + AliasWriter.swift + Sources/CLI, which is
# Foundation-only and measured at 0 errors / 0 warnings under the full Swift 6 language
# mode. So the strongest check the compiler offers is free on exactly the code that
# rewrites ~/.zshrc, which is the code that can least afford to be wrong. Applied on top
# of SWIFT_CONCURRENCY_FLAGS, not instead of it.
#
# Deliberately NOT applied by tools/release-cli.sh, and this is a decision rather than
# an oversight: the language mode is enforced on this source set by both build.sh and
# test.sh, so a regression is caught before a release can be cut (release-cli.sh refuses
# a dirty tree, i.e. it only ever builds a commit test.sh has run against), and the
# shipped binary keeps building in the same language mode it always has.
SWIFT_CLI_LANGUAGE_FLAGS=(
    -swift-version 6
)
