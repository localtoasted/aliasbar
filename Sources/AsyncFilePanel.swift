import AppKit

/// Bridges AppKit's callback-based file panels into structured concurrency without
/// entering a blocking modal event loop.
@MainActor
enum AsyncFilePanel {
    static func begin(_ panel: NSSavePanel) async -> URL? {
        await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
