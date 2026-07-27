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

# Every target: the app, the AliasBarCore module, the writer tests, and all three `ab`
# builds — build.sh's, test.sh's, and the one tools/release-cli.sh ships (which is two
# swiftc invocations of its own, one per architecture slice). `targeted` rather than
# `complete` because the SwiftUI/AppKit surface is not clean under `complete` yet;
# raising it is its own piece of work.
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
# Applied by all three `ab` builds, release included. It briefly was not, on the theory
# that build.sh and test.sh enforce the mode anyway so a regression is caught before a
# release can be cut. That theory rested on release-cli.sh's dirty-tree refusal meaning
# "this commit passed test.sh", and it does not: the check proves only that the build
# corresponds to *some* commit. There is no CI, no git hook and no Makefile in this tree
# connecting a commit to a test run. The gap it left ran the wrong way — `ab` would build
# and test clean under Swift 6, then fail to compile at release time on any construct the
# two modes disagree about (a bare-slash regex literal is enough). One flag list for one
# source set is the whole point of this file.
SWIFT_CLI_LANGUAGE_FLAGS=(
    -swift-version 6
)
