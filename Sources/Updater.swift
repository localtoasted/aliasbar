import Foundation
import Sparkle

/// The one Sparkle surface the rest of the app talks to.
///
/// A single shared instance rather than something owned by the delegate, because both
/// App.swift (start at launch) and the settings window (toggle + manual check) need it,
/// and Sparkle itself already persists its state in UserDefaults — there is nothing per-
/// window about it.
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    /// Mirrors Sparkle's own persisted setting so SwiftUI has something to observe.
    /// Sparkle stores the truth in UserDefaults (`SUEnableAutomaticChecks`); this is a
    /// view of it, not a second copy.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    private init() {
        // `startingUpdater: true` schedules the background check cycle. The first actual
        // network request only happens if automatic checks are enabled, or when the user
        // presses "Check now".
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    /// Called from App.swift at launch purely to force the lazy singleton into existence,
    /// so the scheduled check cycle starts even if the settings window is never opened.
    func start() {}

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
