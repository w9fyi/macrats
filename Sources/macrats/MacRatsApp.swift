import SwiftUI
import MacRatsCore

/// MacRats main entry point — a SwiftUI `@main` App that owns a single
/// shared `MacRatsAppModel` and hosts the main window.
///
/// The app is intentionally minimal — all real work happens in
/// `MacRatsCore`. This file exists to stand up the SwiftUI shell, wire
/// the observable view-model into the scene, and own the menu bar.
@main
struct MacRatsApp: App {

    @StateObject private var store = MacRatsStore.loadFromDisk()

    var body: some Scene {
        WindowGroup("MacRats") {
            MainView()
                .environmentObject(store)
                .frame(minWidth: 780, minHeight: 520)
                .onDisappear {
                    store.disconnect()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Connect") {
                    store.tryConnect()
                }
                .disabled(store.settings.connectionValidationError() != nil
                          || store.connectionStatus == .connected)
                .keyboardShortcut("k", modifiers: [.command])

                Button("Disconnect") {
                    store.disconnect()
                }
                .disabled(store.connectionStatus == .disconnected)
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) { }
            CommandMenu("File Transfer") {
                Button("Send File…") {
                    FileTransferCommands.runSendFile(store: store)
                }
                .disabled(store.connectionStatus != .connected)
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Prepare to Receive File…") {
                    FileTransferCommands.runReceiveFile(store: store)
                }
                .disabled(store.connectionStatus != .connected)
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Cancel File Transfer") {
                    store.cancelFileTransfer()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }

        Settings {
            ConfigSheet()
                .environmentObject(store)
                .frame(minWidth: 480, minHeight: 380)
        }
    }
}
