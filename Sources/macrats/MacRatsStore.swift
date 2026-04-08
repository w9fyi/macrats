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

    /// Long-lived `BluetoothCoordinator` instance. Held here (not in the
    /// AppModel) because IOBluetooth is a macOS-only framework and the
    /// core model is intentionally UI-free. The coordinator's RFCOMM
    /// channel reference must outlive the `USBSerialTransport` that uses
    /// the virtual serial port — holding it on the Store (which lives
    /// for the lifetime of the app) guarantees that.
    let bluetoothCoordinator = BluetoothCoordinator()

    /// True while a Bluetooth link bring-up is in progress. The UI uses
    /// this to disable the Connect button and show a progress hint.
    @Published private(set) var isBringingUpBluetooth = false

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
    ///
    /// For `.bluetooth` kind this is a two-step process: first bring up
    /// the IOBluetooth RFCOMM link via `BluetoothCoordinator`, then hand
    /// the resolved `/dev/cu.*` path to `model.connect(bluetoothPortPath:)`.
    /// The UI shows `isBringingUpBluetooth = true` during the async
    /// bring-up so the Connect button can be disabled.
    func tryConnect() {
        // Validation preflight before we even touch the session layer.
        if let validation = model.settings.connectionValidationError() {
            lastErrorMessage = validation
            return
        }

        if model.settings.connectionKind == .bluetooth {
            tryConnectBluetooth()
            return
        }

        do {
            try model.connect()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func tryConnectBluetooth() {
        let address = model.settings.bluetoothRadioAddress
        guard !address.isEmpty else {
            lastErrorMessage = "Pair a TH-D74 or TH-D75 in System Settings → Bluetooth, then pick it in Preferences → Radio."
            return
        }
        guard !isBringingUpBluetooth else { return }
        isBringingUpBluetooth = true
        let coordinator = bluetoothCoordinator

        // Stream every trace line from the coordinator into the debug
        // log as it happens, so the user can tail the bring-up live
        // instead of waiting for a success or failure to see anything.
        coordinator.onDiagnosticLine = { [weak self] line in
            guard let self else { return }
            Task { @MainActor in
                self.debugLog.append("[BT] " + line)
                if self.debugLog.count > 500 {
                    self.debugLog.removeFirst(self.debugLog.count - 500)
                }
            }
        }

        Task { @MainActor in
            defer {
                self.isBringingUpBluetooth = false
                coordinator.onDiagnosticLine = nil
            }
            do {
                let path = try await coordinator.bringUpLink(addressString: address)
                // Write the success trace too — useful to confirm which
                // RFCOMM channel actually worked on the user's hardware.
                Self.writeBluetoothLog(
                    header: "SUCCESS — resolved path: \(path)",
                    trace: coordinator.lastDiagnosticTrace
                )
                try self.model.connect(bluetoothPortPath: path)
            } catch {
                let logPath = Self.writeBluetoothLog(
                    header: "FAILED — \(error.localizedDescription)",
                    trace: coordinator.lastDiagnosticTrace
                )
                let logHint = logPath.map { "\n\nFull bring-up trace written to \($0) — please include that file if reporting this as a bug." } ?? ""
                self.lastErrorMessage = error.localizedDescription + logHint
                coordinator.tearDownLink()
            }
        }
    }

    /// Write a Bluetooth bring-up trace to `~/Downloads/MacRats/bluetooth.log`,
    /// appending to any existing file. Returns the path on success.
    @discardableResult
    private static func writeBluetoothLog(header: String,
                                          trace: [String]) -> String? {
        let fm = FileManager.default
        guard let downloads = try? fm.url(for: .downloadsDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true) else {
            return nil
        }
        let dir = downloads.appendingPathComponent("MacRats", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let logURL = dir.appendingPathComponent("bluetooth.log")

        var text = "\n=== \(ISO8601DateFormatter().string(from: Date())) ===\n"
        text += header + "\n"
        for line in trace {
            text += line + "\n"
        }
        text += "=== end ===\n"

        guard let data = text.data(using: .utf8) else { return nil }
        if fm.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
        return logURL.path
    }

    /// Disconnect MacRats and tear down the Bluetooth link if one is up.
    /// Called by the UI Disconnect button. For non-Bluetooth connections
    /// this is equivalent to `model.disconnect()`.
    func disconnect() {
        model.disconnect()
        if model.settings.connectionKind == .bluetooth {
            bluetoothCoordinator.tearDownLink()
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
