import SwiftUI
import MacRatsCore

/// First-run setup wizard.
///
/// Appears automatically when MacRats launches and the user's callsign
/// is empty (i.e., no settings have ever been configured). Walks the
/// user through the minimum fields needed to make their first QSO:
/// callsign, then connection kind, then per-kind details, then a
/// summary + Save button.
///
/// VoiceOver-first design principles applied:
///
/// - Every screen has a heading at the top and focuses the primary
///   input field on appearance, so a screen reader lands directly on
///   "type your callsign" without preamble.
/// - The Next button is always the default (Return key) action.
/// - Back and Next buttons are keyboard-reachable via Tab.
/// - There is no "Skip" option. If the user dismisses without
///   finishing, they can open Preferences later — MacRats refuses to
///   connect until a callsign is configured anyway, so there is no
///   way to end up in a broken state.
struct SetupWizard: View {
    @EnvironmentObject private var store: MacRatsStore
    @Environment(\.dismiss) private var dismiss

    /// Draft settings the user builds up through the wizard. Committed
    /// to the store on Finish.
    @State private var draft: MacRatsSettings
    @State private var step: Step = .welcome
    @State private var availablePorts: [SerialPortDiscovery.Port] = []

    @FocusState private var callsignFocused: Bool

    init(initialSettings: MacRatsSettings) {
        _draft = State(initialValue: initialSettings)
    }

    enum Step: Int, CaseIterable {
        case welcome
        case callsign
        case connection
        case serialDetails
        case tcpDetails
        case finish

        var title: String {
            switch self {
            case .welcome:       return "Welcome to MacRats"
            case .callsign:      return "Your Callsign"
            case .connection:    return "How Will You Connect?"
            case .serialDetails: return "Serial Device"
            case .tcpDetails:    return "Local TCP Peer"
            case .finish:        return "All Set"
            }
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Text(step.title)
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            // Step content
            Group {
                switch step {
                case .welcome:       welcomeStep
                case .callsign:      callsignStep
                case .connection:    connectionStep
                case .serialDetails: serialStep
                case .tcpDetails:    tcpStep
                case .finish:        finishStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // Navigation buttons
            HStack {
                if step != .welcome {
                    Button("Back") {
                        goBack()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Go back to the previous step.")
                }
                Spacer()
                Button(primaryButtonTitle) {
                    goNext()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
                .accessibilityHint(step == .finish
                                   ? "Save settings and dismiss the setup wizard."
                                   : "Continue to the next step.")
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 360)
        .onAppear {
            availablePorts = SerialPortDiscovery.availablePorts()
        }
    }

    // MARK: - Welcome step

    @ViewBuilder
    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacRats is an accessible, VoiceOver-first client for the D-Rats protocol.")
            Text("This quick setup will get you on the air in about a minute.")
            Text("You can change any of these settings later in the Preferences window.")
                .foregroundStyle(.secondary)
            Text("The wizard will ask for:")
                .padding(.top, 8)
            Text("• Your amateur radio callsign")
            Text("• How you want to connect (USB serial, local TCP, or Bluetooth)")
            Text("• Device-specific details like port and baud rate")
        }
        .font(.body)
    }

    // MARK: - Callsign step

    @ViewBuilder
    private var callsignStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter your amateur radio callsign. MacRats stamps this into every outgoing message, and uses it to route direct messages to you.")
                .foregroundStyle(.secondary)

            TextField("Callsign", text: $draft.callsign)
                .textFieldStyle(.roundedBorder)
                .font(.title2.monospaced())
                .textCase(.uppercase)
                .autocorrectionDisabled()
                .focused($callsignFocused)
                .accessibilityLabel("Your amateur radio callsign")
                .accessibilityHint("Type your callsign. This is required.")
                .onSubmit { goNext() }
                .onAppear { callsignFocused = true }

            Text("Example: AI5OS, W9FYI, 2E0ABC")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Connection step

    @ViewBuilder
    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose how MacRats will talk to other D-Rats stations.")
                .foregroundStyle(.secondary)

            Picker("Connection type", selection: $draft.connectionKind) {
                Text("Serial / USB (to a real radio)").tag(MacRatsSettings.ConnectionKind.serial)
                Text("Ratflector (Internet, no radio needed)").tag(MacRatsSettings.ConnectionKind.tcpRatflector)
                Text("Local TCP (for testing with another instance)").tag(MacRatsSettings.ConnectionKind.tcpLoopback)
                Text("Disconnected (configure later)").tag(MacRatsSettings.ConnectionKind.disconnected)
            }
            .pickerStyle(.radioGroup)
            .accessibilityLabel("Connection type")

            switch draft.connectionKind {
            case .serial:
                Text("Best for: Kenwood TH-D75, Icom ID-51, and other radios with a USB or serial data port.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .tcpRatflector:
                Text("Best for: chatting with other D-Rats users over the Internet without a radio. MacRats will fetch the public ratflector list so you can pick one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .tcpLoopback:
                Text("Best for: testing two MacRats instances on the same Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .disconnected:
                Text("You can set this up later. MacRats will not be able to send or receive until you do.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Serial step

    @ViewBuilder
    private var serialStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick the serial device for your radio. If you don't see your radio, plug it in and click Refresh.")
                .foregroundStyle(.secondary)

            HStack {
                Picker("Device", selection: $draft.serialDevicePath) {
                    Text("— Select a device —").tag("")
                    ForEach(availablePorts, id: \.path) { port in
                        Text("\(port.kind.displayName): \(port.leafName)").tag(port.path)
                    }
                }
                .accessibilityLabel("Serial device")

                Button {
                    availablePorts = SerialPortDiscovery.availablePorts()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh list of serial devices")
            }

            Picker("Baud rate", selection: $draft.serialBaudRate) {
                Text("9600 (TH-D75 normal CAT)").tag(Int32(9600))
                Text("38400 (TH-D75 terminal mode)").tag(Int32(38400))
                Text("115200").tag(Int32(115200))
            }
            .accessibilityLabel("Baud rate")
            .accessibilityHint("The TH-D75 uses 9600 for normal CAT commands or 38400 for terminal mode.")

            if draft.serialDevicePath.isEmpty {
                Text("Select a device to continue.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - TCP step

    @ViewBuilder
    private var tcpStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("For local testing with a second MacRats instance, leave the host blank on one side (which makes it listen) and fill in 127.0.0.1 on the other (which makes it connect).")
                .foregroundStyle(.secondary)

            TextField("Host (blank = listen)", text: $draft.tcpHost)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("TCP host")
                .accessibilityHint("Leave blank to listen for an incoming connection. Fill in to connect to a peer.")

            TextField("Port", value: $draft.tcpPort, format: .number)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("TCP port")
        }
    }

    // MARK: - Finish step

    @ViewBuilder
    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Everything is set. Here's what you configured:")
                .foregroundStyle(.secondary)

            SummaryRow(label: "Callsign", value: draft.callsign)
            SummaryRow(label: "Connection", value: draft.connectionKind.displayName)

            if draft.connectionKind == .serial {
                SummaryRow(label: "Device", value: draft.serialDevicePath.isEmpty ? "(none)" : draft.serialDevicePath)
                SummaryRow(label: "Baud rate", value: "\(draft.serialBaudRate)")
            } else if draft.connectionKind == .tcpLoopback {
                SummaryRow(label: "Host", value: draft.tcpHost.isEmpty ? "(listen)" : draft.tcpHost)
                SummaryRow(label: "Port", value: "\(draft.tcpPort)")
            }

            Text("Click Finish to save these settings. You can open Preferences (⌘,) any time to change them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    // MARK: - Navigation logic

    private var primaryButtonTitle: String {
        step == .finish ? "Finish" : "Next"
    }

    private var canAdvance: Bool {
        switch step {
        case .welcome:
            return true
        case .callsign:
            return !draft.callsign.trimmingCharacters(in: .whitespaces).isEmpty
        case .connection:
            return true
        case .serialDetails:
            return !draft.serialDevicePath.isEmpty && draft.serialBaudRate > 0
        case .tcpDetails:
            return draft.tcpPort > 0
        case .finish:
            return true
        }
    }

    private func goNext() {
        guard canAdvance else { return }
        switch step {
        case .welcome:
            step = .callsign
        case .callsign:
            // Normalize callsign to uppercase without whitespace.
            draft.callsign = draft.callsign
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            step = .connection
        case .connection:
            switch draft.connectionKind {
            case .serial:
                step = .serialDetails
            case .tcpLoopback, .tcpRatflector:
                step = .tcpDetails
            case .disconnected:
                step = .finish
            }
        case .serialDetails, .tcpDetails:
            step = .finish
        case .finish:
            finish()
        }
    }

    private func goBack() {
        switch step {
        case .welcome:
            break
        case .callsign:
            step = .welcome
        case .connection:
            step = .callsign
        case .serialDetails, .tcpDetails:
            step = .connection
        case .finish:
            switch draft.connectionKind {
            case .serial:                   step = .serialDetails
            case .tcpLoopback, .tcpRatflector: step = .tcpDetails
            case .disconnected:             step = .connection
            }
        }
    }

    private func finish() {
        store.updateSettings(draft)
        dismiss()
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label + ":")
                .frame(width: 100, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body).monospaced())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
