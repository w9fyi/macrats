import AppKit
import MacRatsCore

/// Helper for the `File Transfer` menu bar commands in MacRatsApp.
///
/// File transfer needs two user inputs before it can start: a path
/// (source file when sending, destination directory when receiving)
/// and a remote callsign. The simplest, most accessible way to get
/// both is a pair of dialogs — one native open panel from AppKit and
/// one plain text input alert. We intentionally avoid a custom SwiftUI
/// sheet because:
///
/// 1. SwiftUI modal sheets on macOS still have rough VoiceOver edges.
/// 2. Native `NSOpenPanel` is fully accessible and remembered by the
///    user — they already know how it behaves.
/// 3. `NSAlert` with a `NSTextField` accessory view is the simplest
///    AppKit idiom for "ask a one-line question", and it's cleanly
///    audited by VoiceOver.
///
/// The dialogs run synchronously on the main thread. The store
/// intent (`sendFile` / `prepareToReceiveFile`) is called after both
/// inputs have been collected.
@MainActor
enum FileTransferCommands {

    // MARK: - Send

    /// Prompt the user for a file to send, then a destination callsign,
    /// then hand the resulting pair to `store.sendFile(url:to:)`.
    static func runSendFile(store: MacRatsStore) {
        // Step 1: pick the file. NSOpenPanel is modal and blocks the
        // main run loop until the user clicks Cancel or Open.
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick a file to send"
        panel.prompt = "Send"
        panel.title = "Send File"
        // No file-type restriction — any file can be transferred.

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            return
        }

        // Step 2: ask for the destination callsign. Prefill with the
        // last selected heard station if available — saves typing in
        // the common case of talking back to whoever just replied.
        let defaultCall = store.heardStations.first?.callsign ?? ""
        guard let callsign = promptForCallsign(
            title: "Send \(fileURL.lastPathComponent)",
            message: "Enter the callsign of the station to send this file to.",
            defaultValue: defaultCall
        ) else {
            return
        }

        store.sendFile(url: fileURL, to: callsign)
    }

    // MARK: - Receive

    /// Prompt the user for a destination directory and a sender
    /// callsign, then arm the receiver via `store.prepareToReceiveFile`.
    static func runReceiveFile(store: MacRatsStore) {
        // Step 1: pick the destination directory. Default to the
        // user's Downloads folder because that's where files go on
        // macOS and the directory picker remembers the last location.
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick a folder to save the incoming file into"
        panel.prompt = "Save Here"
        panel.title = "Receive File"
        if let downloads = try? FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            panel.directoryURL = downloads
        }

        guard panel.runModal() == .OK, let dirURL = panel.url else {
            return
        }

        // Step 2: ask for the expected sender callsign.
        let defaultCall = store.heardStations.first?.callsign ?? ""
        guard let callsign = promptForCallsign(
            title: "Receive File",
            message: "Enter the callsign of the station that will send the file.",
            defaultValue: defaultCall
        ) else {
            return
        }

        store.prepareToReceiveFile(from: callsign, saveTo: dirURL)
    }

    // MARK: - Callsign prompt

    /// Minimal modal text-input dialog. Returns the user's input
    /// (trimmed and uppercased) or nil on cancel / empty.
    private static func promptForCallsign(title: String,
                                           message: String,
                                           defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultValue
        input.placeholderString = "W9FYI"
        // The accessory view is AppKit's standard pattern for
        // attaching a text field to an alert. VoiceOver reads the
        // messageText + informativeText as the dialog's description
        // and then focuses the text field automatically.
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let trimmed = input.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
