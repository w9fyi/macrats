import Foundation
import SwiftUI
import Combine
import MacRatsCore

/// SwiftUI-facing `@ObservedObject` wrapper around `MacRatsAppModel`.
///
/// Why this exists: `MacRatsAppModel` lives in `MacRatsCore` and does
/// not import SwiftUI (it's testable under `swift test` without any UI
/// runtime). But SwiftUI needs an `ObservableObject` to drive view
/// updates. This thin wrapper bridges the two — it subscribes to the
/// model's `onStateChanged` callback and fires `objectWillChange` on
/// the main actor.
///
/// The wrapper is intentionally small: it forwards reads straight to
/// the model and delegates mutations to the model's methods. SwiftUI
/// views talk to this class (`@EnvironmentObject var store: MacRatsStore`)
/// and never import MacRatsCore's internal types directly.
@MainActor
final class MacRatsStore: ObservableObject {

    /// The underlying view-model. Exposed so SwiftUI views can call its
    /// methods (send, ping, etc.) and bind to its properties.
    let model: MacRatsAppModel

    /// Published snapshot the views bind to. Updated on the main actor
    /// every time the model fires `onStateChanged`.
    @Published private(set) var snapshot: MacRatsAppModel.Snapshot

    /// Last error the user should see (from `tryConnect()`). Nil when
    /// cleared. Used by the UI to drive an error banner.
    @Published var lastErrorMessage: String?

    /// Rolling debug log buffer — populated from `model.logHandler`.
    @Published private(set) var debugLog: [String] = []

    init(model: MacRatsAppModel) {
        self.model = model
        self.snapshot = model.snapshot()

        // Wire the model's observation callback through to @Published.
        // The callback can fire from any thread — we hop to the main
        // actor before touching published state.
        model.onStateChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.snapshot = self.model.snapshot()
            }
        }
        model.logHandler = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.debugLog.append(message)
                // Keep the buffer bounded so the debug view doesn't
                // balloon in long sessions.
                if self.debugLog.count > 500 {
                    self.debugLog.removeFirst(self.debugLog.count - 500)
                }
            }
        }
    }

    /// Convenience initializer that loads settings from disk.
    static func loadFromDisk() -> MacRatsStore {
        let loadedSettings = MacRatsSettings.load()
        let model = MacRatsAppModel(settings: loadedSettings)
        return MacRatsStore(model: model)
    }

    // MARK: - Convenience read accessors

    var settings: MacRatsSettings { snapshot.settings }
    var connectionStatus: TransportStatus { snapshot.connectionStatus }
    var chatMessages: [ChatMessage] { snapshot.chatMessages }
    var heardStations: [HeardStation] { snapshot.stations }

    // MARK: - Intents

    func updateSettings(_ settings: MacRatsSettings) {
        model.updateSettings(settings)
    }

    /// Attempt to connect, capturing any thrown error into
    /// `lastErrorMessage` so a SwiftUI alert can display it.
    func tryConnect() {
        // Validation preflight before we even touch the session layer.
        if let validation = model.settings.connectionValidationError() {
            lastErrorMessage = validation
            return
        }
        do {
            try model.connect()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func sendChatMessage(_ text: String, to dest: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try model.sendChatMessage(text, to: dest)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func pingStation(_ callsign: String) {
        guard !callsign.isEmpty else { return }
        do {
            try model.pingStation(callsign)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func broadcastStatus(_ status: StationStatus, message: String) {
        do {
            try model.broadcastStatus(status, message: message)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}
