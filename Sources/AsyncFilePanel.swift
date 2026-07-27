import AppKit

/// Bridges AppKit's callback-based file panels into structured concurrency without
/// entering a blocking modal event loop.
@MainActor
enum AsyncFilePanel {
    private static var isPresenting = false

    static func begin(_ panel: NSSavePanel) async -> URL? {
        guard !isPresenting else { return nil }
        isPresenting = true
        defer { isPresenting = false }

        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let parent = NSApp.keyWindow {
                panel.beginSheetModal(for: parent) { response in
                    continuation.resume(returning: response)
                }
            } else {
                panel.begin { response in
                    continuation.resume(returning: response)
                }
            }
        }
        return response == .OK ? panel.url : nil
    }
}
