import SwiftUI
import MacRatsCore

/// Primary window layout — a `NavigationSplitView` with the heard
/// stations list in the sidebar and the chat view as the main content.
/// A toolbar along the top shows connection status and offers quick
/// actions (Connect / Disconnect / Ping selected station).
///
/// The layout intentionally mirrors D-Rats's chat tab (list of stations
/// on one side, conversation on the other) rather than D-Rats's full
/// tab bar. v1.0 doesn't ship the Messages / Events / Files tabs — those
/// are v1.1+ per the feature parity matrix. A blind user opening
/// MacRats v1.0 should land on "I can see who's out there and I can
/// chat with them" with zero friction.
struct MainView: View {
    @EnvironmentObject private var store: MacRatsStore
    @State private var selectedStationID: String?

    var body: some View {
        NavigationSplitView {
            StationsView(selection: $selectedStationID)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            ChatView(pingTarget: selectedStationID)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                connectionStatusIndicator
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: togglePing) {
                    Label("Ping Selected", systemImage: "bolt.horizontal")
                }
                .disabled(selectedStationID == nil || store.connectionStatus != .connected)
                .help("Send a ping to the selected station (\(selectedStationID ?? "no selection"))")
                .accessibilityLabel(selectedStationID.map { "Ping station \($0)" } ?? "Ping selected station")

                Button(action: toggleConnection) {
                    if store.connectionStatus == .connected {
                        Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash")
                    } else {
                        Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .help(connectButtonHelp)
                .accessibilityLabel(connectButtonHelp)
            }
        }
        .alert("Error",
               isPresented: Binding(get: { store.lastErrorMessage != nil },
                                    set: { if !$0 { store.lastErrorMessage = nil } })) {
            Button("OK", role: .cancel) { store.lastErrorMessage = nil }
        } message: {
            Text(store.lastErrorMessage ?? "")
        }
    }

    // MARK: - Status indicator

    @ViewBuilder
    private var connectionStatusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true) // text alone is enough for VoiceOver
            Text(statusText)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(statusText)")
    }

    private var statusColor: Color {
        switch store.connectionStatus {
        case .connected:      return .green
        case .connecting:     return .orange
        case .disconnected:   return .gray
        case .failed:         return .red
        }
    }

    private var statusText: String {
        switch store.connectionStatus {
        case .connected:       return "Connected"
        case .connecting:      return "Connecting…"
        case .disconnected:    return "Disconnected"
        case .failed(let err): return "Failed: \(err)"
        }
    }

    // MARK: - Button actions

    private var connectButtonHelp: String {
        if store.connectionStatus == .connected {
            return "Disconnect from \(store.settings.connectionKind.displayName)"
        } else if let validation = store.settings.connectionValidationError() {
            return "Connect (\(validation))"
        } else {
            return "Connect to \(store.settings.connectionKind.displayName)"
        }
    }

    private func toggleConnection() {
        if store.connectionStatus == .connected {
            store.model.disconnect()
        } else {
            store.tryConnect()
        }
    }

    private func togglePing() {
        if let id = selectedStationID {
            store.pingStation(id)
        }
    }
}
