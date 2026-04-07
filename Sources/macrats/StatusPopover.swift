import SwiftUI
import MacRatsCore

/// "My Status" popover — lets the user pick online/unattended/offline,
/// set a free-form status message, and broadcast it via a T_STATUS
/// chat frame. Opens from the toolbar button in `MainView`.
///
/// Mirrors D-Rats's "My Status" field in the lower-right of the main
/// window, but packaged as a popover so the toolbar stays clean and
/// the field is still one Tab-away for keyboard / VoiceOver users.
struct StatusPopover: View {
    @Binding var status: StationStatus
    @Binding var message: String
    var onBroadcast: () -> Void

    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My Status")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Picker("Status", selection: $status) {
                Text("Online").tag(StationStatus.online)
                Text("Unattended").tag(StationStatus.unattended)
                Text("Offline").tag(StationStatus.offline)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Station status")
            .accessibilityHint("Choose the status to broadcast to other stations.")

            TextField("Status message (optional)", text: $message, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .focused($messageFocused)
                .accessibilityLabel("Status message")
                .accessibilityHint("Free-form text broadcast with your status. For example: K in Austin, or AFK for 5 minutes.")

            HStack {
                Spacer()
                Button("Broadcast") {
                    onBroadcast()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Broadcast status \(status.description)\(message.isEmpty ? "" : ", message: \(message)")")
            }

            Text("Status is also automatically broadcast after replying to a ping.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            // Put keyboard focus in the message field on open, so a
            // VoiceOver user lands right where they can type.
            messageFocused = true
        }
    }
}
