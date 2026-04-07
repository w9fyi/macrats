import SwiftUI
import MacRatsCore

/// Preferences / Settings sheet. Mirrors the v1.0 subset of D-Rats's
/// config panels identified in `memory/macrats_feature_parity.md`:
/// Preferences, Radio, GPS, Appearance, Chat.
///
/// All controls use SwiftUI's native accessibility by default, which
/// means TextField / Toggle / Picker produce correct NSAccessibility
/// labels out of the box. Where default labels aren't descriptive
/// enough, we override with `.accessibilityLabel(...)`.
///
/// This sheet is wired to the macOS `Settings` scene in `MacRatsApp`,
/// so it opens with `⌘,` and behaves like any other macOS preferences
/// window.
struct ConfigSheet: View {
    @EnvironmentObject private var store: MacRatsStore

    // A working copy the user edits. We commit back to the store on
    // every field change. This is simpler than a dedicated "Save"
    // button and matches standard macOS preferences pane behavior.
    @State private var working: MacRatsSettings = MacRatsSettings()
    @State private var availablePorts: [SerialPortDiscovery.Port] = []
    @State private var didInitialize = false

    var body: some View {
        TabView {
            preferencesTab
                .tabItem { Label("Preferences", systemImage: "person.circle") }

            radioTab
                .tabItem { Label("Radio", systemImage: "antenna.radiowaves.left.and.right") }

            gpsTab
                .tabItem { Label("GPS", systemImage: "location") }

            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            chatTab
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
        }
        .padding()
        .onAppear {
            if !didInitialize {
                working = store.settings
                availablePorts = SerialPortDiscovery.availablePorts()
                didInitialize = true
            }
        }
    }

    // MARK: - Preferences tab

    @ViewBuilder
    private var preferencesTab: some View {
        Form {
            TextField("Callsign", text: $working.callsign)
                .textCase(.uppercase)
                .autocorrectionDisabled()
                .onChange(of: working.callsign) { _, _ in commit() }
                .accessibilityHint("Your amateur radio callsign — required.")

            TextField("Sign-on message", text: $working.signOnMessage)
                .onChange(of: working.signOnMessage) { _, _ in commit() }
                .accessibilityHint("Automatic broadcast sent when you connect. Leave blank to disable.")

            TextField("Sign-off message", text: $working.signOffMessage)
                .onChange(of: working.signOffMessage) { _, _ in commit() }
                .accessibilityHint("Automatic broadcast sent when you disconnect. Leave blank to disable.")

            TextField("Ping reply text", text: $working.pingReplyText)
                .onChange(of: working.pingReplyText) { _, _ in commit() }
                .accessibilityHint("Text returned when another station pings you.")

            Toggle("Confirm before quitting", isOn: $working.confirmExit)
                .onChange(of: working.confirmExit) { _, _ in commit() }
        }
        .formStyle(.grouped)
        .navigationTitle("Preferences")
    }

    // MARK: - Radio tab

    @ViewBuilder
    private var radioTab: some View {
        Form {
            Picker("Connection type", selection: $working.connectionKind) {
                ForEach(MacRatsSettings.ConnectionKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .onChange(of: working.connectionKind) { _, _ in commit() }

            Group {
                switch working.connectionKind {
                case .disconnected:
                    Text("No connection type selected.")
                        .foregroundStyle(.secondary)

                case .serial:
                    serialSection

                case .tcpLoopback:
                    tcpLoopbackSection

                case .tcpRatflector:
                    tcpRatflectorSection
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Radio")
    }

    @ViewBuilder
    private var serialSection: some View {
        HStack {
            Picker("Serial device", selection: $working.serialDevicePath) {
                Text("— Select a device —").tag("")
                ForEach(availablePorts, id: \.path) { port in
                    Text("\(port.kind.displayName): \(port.leafName)").tag(port.path)
                }
            }
            .onChange(of: working.serialDevicePath) { _, _ in commit() }

            Button {
                availablePorts = SerialPortDiscovery.availablePorts()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Rescan for /dev/cu.* devices")
            .accessibilityLabel("Refresh list of serial devices")
        }

        Picker("Baud rate", selection: $working.serialBaudRate) {
            Text("1200").tag(Int32(1200))
            Text("2400").tag(Int32(2400))
            Text("4800").tag(Int32(4800))
            Text("9600 (TH-D75 normal)").tag(Int32(9600))
            Text("19200").tag(Int32(19200))
            Text("38400 (TH-D75 terminal mode)").tag(Int32(38400))
            Text("57600").tag(Int32(57600))
            Text("115200").tag(Int32(115200))
        }
        .onChange(of: working.serialBaudRate) { _, _ in commit() }
    }

    @ViewBuilder
    private var tcpLoopbackSection: some View {
        Text("Leave host blank to listen for an incoming connection; fill in a host to connect.")
            .font(.caption)
            .foregroundStyle(.secondary)
        TextField("Host (optional — blank = listen)", text: $working.tcpHost)
            .onChange(of: working.tcpHost) { _, _ in commit() }
        TextField("Port", value: $working.tcpPort, format: .number)
            .onChange(of: working.tcpPort) { _, _ in commit() }
    }

    @ViewBuilder
    private var tcpRatflectorSection: some View {
        Text("Ratflector connections are planned for v1.1.")
            .font(.caption)
            .foregroundStyle(.orange)
        TextField("Ratflector host", text: $working.tcpHost)
            .onChange(of: working.tcpHost) { _, _ in commit() }
        TextField("Port", value: $working.tcpPort, format: .number)
            .onChange(of: working.tcpPort) { _, _ in commit() }
    }

    // MARK: - GPS tab

    @ViewBuilder
    private var gpsTab: some View {
        Form {
            Section {
                Text("Fixed position beacon — broadcast your location with chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Latitude (e.g. 30.2672)", value: $working.fixedLatitude,
                          format: .number.precision(.fractionLength(0...6)))
                    .onChange(of: working.fixedLatitude) { _, _ in commit() }

                TextField("Longitude (e.g. -97.7431)", value: $working.fixedLongitude,
                          format: .number.precision(.fractionLength(0...6)))
                    .onChange(of: working.fixedLongitude) { _, _ in commit() }

                TextField("GPS comment", text: $working.gpsComment)
                    .onChange(of: working.gpsComment) { _, _ in commit() }
                    .accessibilityHint("Free-form text broadcast with your position fix.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("GPS")
    }

    // MARK: - Appearance tab

    @ViewBuilder
    private var appearanceTab: some View {
        Form {
            Section {
                TextField("Notice regex", text: $working.noticeRegex)
                    .onChange(of: working.noticeRegex) { _, _ in commit() }
                    .accessibilityHint("Messages matching this pattern are highlighted. Typical value: your callsign with (?i) for case-insensitivity.")

                Text("Typical: your callsign, e.g. \"AI5OS(?i)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Ignore regex", text: $working.ignoreRegex)
                    .onChange(of: working.ignoreRegex) { _, _ in commit() }
                    .accessibilityHint("Messages matching this pattern are dimmed in the chat view.")

                Text("Typical: \"[QST] [CQCQCQ]\" to de-emphasize beacons")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }

    // MARK: - Chat tab

    @ViewBuilder
    private var chatTab: some View {
        Form {
            Toggle("Show status updates in chat", isOn: $working.showStatusUpdatesInChat)
                .onChange(of: working.showStatusUpdatesInChat) { _, _ in commit() }
                .accessibilityHint("When on, joins, parts, and status announcements appear inline with regular chat messages.")
        }
        .formStyle(.grouped)
        .navigationTitle("Chat")
    }

    // MARK: - Commit

    private func commit() {
        store.updateSettings(working)
    }
}
