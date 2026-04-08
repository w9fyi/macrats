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
    @State private var pairedBluetoothRadios: [BluetoothPairedRadioRow] = []
    @State private var bluetoothStatus: String = ""

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
            .onChange(of: working.connectionKind) { _, _ in
                commit()
                // Auto-load the directory the first time the user
                // switches to ratflector mode.
                if working.connectionKind == .tcpRatflector,
                   ratflectorEntries == nil,
                   !isLoadingRatflectors {
                    loadRatflectorDirectory()
                }
                // Auto-scan paired Bluetooth radios when the user
                // switches to Bluetooth mode.
                if working.connectionKind == .bluetooth && pairedBluetoothRadios.isEmpty {
                    refreshBluetoothRadios()
                }
            }

            Group {
                switch working.connectionKind {
                case .disconnected:
                    Text("No connection type selected.")
                        .foregroundStyle(.secondary)

                case .serial:
                    serialSection

                case .bluetooth:
                    bluetoothSection

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

        // MARK: - Warmup frame tuning (radio-specific)
        Section {
            Stepper("Warmup length: \(working.warmupLength) bytes",
                    value: $working.warmupLength,
                    in: 0...64)
                .onChange(of: working.warmupLength) { _, _ in commit() }
                .accessibilityHint("Number of filler bytes prefixed to the first frame after an idle period, to wake up the receiving radio. D-Rats recommends 16 for radio. Set to 0 to disable warmup entirely.")

            Stepper("Warmup idle timeout: \(Self.formatSeconds(working.warmupTimeoutSeconds))",
                    value: $working.warmupTimeoutSeconds,
                    in: 0...30,
                    step: 1)
                .onChange(of: working.warmupTimeoutSeconds) { _, _ in commit() }
                .accessibilityHint("Seconds of idle before the next transmission gets a warmup prefix. 3 seconds is the D-Rats default. 0 disables warmup.")

            Stepper("Force TX delay: \(Self.formatSeconds(working.forceDelaySeconds))",
                    value: $working.forceDelaySeconds,
                    in: 0...10,
                    step: 0.5)
                .onChange(of: working.forceDelaySeconds) { _, _ in commit() }
                .accessibilityHint("Fixed delay inserted before each transmission batch. 0 disables.")

            Toggle("Log wire traffic to ~/Downloads/MacRats/wire.log",
                   isOn: $working.wireLoggingEnabled)
                .onChange(of: working.wireLoggingEnabled) { _, _ in commit() }
                .accessibilityHint("When enabled, every byte sent to and received from the radio is written to a log file you can tail in Terminal. Useful for bench testing. Off by default.")
        } header: {
            Text("Transport tuning")
        } footer: {
            Text("These settings control the low-level wire behavior toward the radio. Defaults match D-Rats's recommended values for radio connections. TCP loopback connections ignore these settings and disable warmup automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Format a TimeInterval as a short human-readable string for a
    /// Stepper label.
    private static func formatSeconds(_ value: TimeInterval) -> String {
        if value == 0 { return "disabled" }
        // Round to one decimal if fractional, else integer.
        if value == floor(value) {
            return "\(Int(value)) s"
        }
        return String(format: "%.1f s", value)
    }

    // MARK: - Bluetooth section

    /// Lightweight row model for the Bluetooth picker. We don't want to
    /// leak `BluetoothCoordinator.PairedRadio` into SwiftUI state because
    /// it pulls in IOBluetooth; this struct is trivially Sendable.
    struct BluetoothPairedRadioRow: Identifiable, Equatable {
        let id: String   // the MAC address — unique per radio
        let name: String
        let address: String
        let isLinked: Bool
    }

    @ViewBuilder
    private var bluetoothSection: some View {
        Section {
            HStack {
                Picker("Paired radio", selection: $working.bluetoothRadioAddress) {
                    Text("— Select a radio —").tag("")
                    ForEach(pairedBluetoothRadios) { row in
                        Text(bluetoothRowLabel(row)).tag(row.address)
                    }
                }
                .onChange(of: working.bluetoothRadioAddress) { _, newAddress in
                    if let row = pairedBluetoothRadios.first(where: { $0.address == newAddress }) {
                        working.bluetoothRadioName = row.name
                    } else if newAddress.isEmpty {
                        working.bluetoothRadioName = ""
                    }
                    commit()
                }
                .accessibilityLabel("Paired Bluetooth radio")

                Button {
                    refreshBluetoothRadios()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-scan paired Bluetooth devices")
                .accessibilityLabel("Refresh list of paired Bluetooth radios")
            }

            if !bluetoothStatus.isEmpty {
                Text(bluetoothStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Bluetooth status: \(bluetoothStatus)")
            }

            Text("Pair your TH-D74 or TH-D75 in System Settings → Bluetooth before picking it here. The first time MacRats opens the radio's Bluetooth link, macOS may ask you to allow Bluetooth access — say yes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Bluetooth radio")
        }

        // The Bluetooth path reuses the same warmup / force-delay / wire
        // log controls as the serial path, because the bytes ultimately
        // flow through USBSerialTransport once BluetoothCoordinator has
        // brought up the RFCOMM link.
        transportTuningSection
    }

    /// Pull paired TH-D74/D75 radios from `BluetoothCoordinator` and
    /// populate `pairedBluetoothRadios`. Main-actor-safe.
    private func refreshBluetoothRadios() {
        let radios = BluetoothCoordinator.pairedRadios()
        pairedBluetoothRadios = radios.map { radio in
            BluetoothPairedRadioRow(
                id: radio.address,
                name: radio.name,
                address: radio.address,
                isLinked: radio.existingPortPath != nil || radio.isCurrentlyConnected
            )
        }
        if pairedBluetoothRadios.isEmpty {
            bluetoothStatus = "No paired TH-D74 or TH-D75 found. Pair one in System Settings → Bluetooth, then click Refresh."
        } else {
            bluetoothStatus = "Found \(pairedBluetoothRadios.count) paired radio\(pairedBluetoothRadios.count == 1 ? "" : "s")."
        }
    }

    private func bluetoothRowLabel(_ row: BluetoothPairedRadioRow) -> String {
        if row.isLinked {
            return "\(row.name) (\(row.address)) — linked"
        }
        return "\(row.name) (\(row.address))"
    }

    /// Shared transport-tuning section used by both the serial and
    /// Bluetooth paths (they both end up driving a USBSerialTransport).
    @ViewBuilder
    private var transportTuningSection: some View {
        Section {
            Stepper("Warmup length: \(working.warmupLength) bytes",
                    value: $working.warmupLength,
                    in: 0...64)
                .onChange(of: working.warmupLength) { _, _ in commit() }
                .accessibilityHint("Number of filler bytes prefixed to the first frame after an idle period, to wake up the receiving radio.")

            Stepper("Warmup idle timeout: \(Self.formatSeconds(working.warmupTimeoutSeconds))",
                    value: $working.warmupTimeoutSeconds,
                    in: 0...30,
                    step: 1)
                .onChange(of: working.warmupTimeoutSeconds) { _, _ in commit() }

            Stepper("Force TX delay: \(Self.formatSeconds(working.forceDelaySeconds))",
                    value: $working.forceDelaySeconds,
                    in: 0...10,
                    step: 0.5)
                .onChange(of: working.forceDelaySeconds) { _, _ in commit() }

            Toggle("Log wire traffic to ~/Downloads/MacRats/wire.log",
                   isOn: $working.wireLoggingEnabled)
                .onChange(of: working.wireLoggingEnabled) { _, _ in commit() }
        } header: {
            Text("Transport tuning")
        } footer: {
            Text("These settings control the low-level wire behavior toward the radio. Defaults match D-Rats's recommended values for radio connections.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    // MARK: - Ratflector section

    /// Entries fetched from the public directory. `nil` = not yet
    /// loaded; empty array = loaded but failed or empty.
    @State private var ratflectorEntries: [RatflectorDirectory.Entry]? = nil
    @State private var ratflectorFetchError: String? = nil
    @State private var isLoadingRatflectors = false

    @ViewBuilder
    private var tcpRatflectorSection: some View {
        Text("Ratflectors are D-Rats servers that relay chat over the Internet. Pick one from the public directory, or enter a host manually.")
            .font(.caption)
            .foregroundStyle(.secondary)

        // Directory picker (from the public upstream YAML list)
        HStack {
            Picker("Public ratflector", selection: ratflectorPickerBinding) {
                Text("— Choose a ratflector —").tag(String?.none)
                if let ratflectorEntries {
                    ForEach(ratflectorEntries) { entry in
                        Text(entry.displayLabel).tag(String?.some(entry.hostname))
                    }
                }
            }
            .disabled(ratflectorEntries == nil || isLoadingRatflectors)
            .accessibilityLabel("Public ratflector directory picker")
            .accessibilityHint("Choose a server from the public D-Rats ratflector directory.")

            Button {
                loadRatflectorDirectory()
            } label: {
                if isLoadingRatflectors {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isLoadingRatflectors)
            .help("Fetch the public ratflector list from github.com/ham-radio-software/ratflectors")
            .accessibilityLabel("Refresh ratflector directory")
        }

        if let error = ratflectorFetchError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
        }

        // Manual entry fallback for private / unlisted servers
        Section {
            TextField("Ratflector host", text: $working.tcpHost)
                .onChange(of: working.tcpHost) { _, _ in commit() }
                .accessibilityHint("DNS name or IP of the ratflector. If you pick from the directory above, this fills in automatically.")
            TextField("Port", value: $working.tcpPort, format: .number)
                .onChange(of: working.tcpPort) { _, _ in commit() }
                .accessibilityHint("TCP port. Default is 9000, which all public ratflectors use.")
            TextField("Password (only if the ratflector requires auth)", text: $working.ratflectorPassword)
                .onChange(of: working.ratflectorPassword) { _, _ in commit() }
                .accessibilityHint("Leave blank unless the ratflector operator gave you a password. Most public ratflectors don't require authentication.")
        } header: {
            Text("Manual entry")
        }
    }

    /// Two-way binding between the directory picker and the
    /// underlying `working.tcpHost` + port + label fields. When the
    /// user picks an entry, we fill in all three; when they type a
    /// host manually, the picker deselects.
    private var ratflectorPickerBinding: Binding<String?> {
        Binding(
            get: {
                // Picker shows the currently-set host if it matches
                // one of the directory entries, otherwise "nothing
                // selected" so the manual fields are authoritative.
                if let entries = ratflectorEntries,
                   entries.contains(where: { $0.hostname == working.tcpHost }) {
                    return working.tcpHost
                }
                return nil
            },
            set: { newHost in
                guard let newHost, let entries = ratflectorEntries,
                      let entry = entries.first(where: { $0.hostname == newHost }) else {
                    return
                }
                working.tcpHost = entry.hostname
                working.tcpPort = entry.port
                working.ratflectorLabel = "\(entry.name) — \(entry.description)"
                commit()
            }
        )
    }

    /// Kick off a fetch of the ratflector directory. Safe to call
    /// multiple times; concurrent fetches are deduped via
    /// `isLoadingRatflectors`.
    private func loadRatflectorDirectory() {
        guard !isLoadingRatflectors else { return }
        isLoadingRatflectors = true
        ratflectorFetchError = nil
        Task {
            do {
                let entries = try await RatflectorDirectory.fetch()
                await MainActor.run {
                    self.ratflectorEntries = entries.filter { $0.active }
                    self.isLoadingRatflectors = false
                }
            } catch {
                await MainActor.run {
                    self.ratflectorFetchError = "Failed to load directory: \(error.localizedDescription)"
                    self.isLoadingRatflectors = false
                }
            }
        }
    }

    // MARK: - GPS tab

    @ViewBuilder
    private var gpsTab: some View {
        Form {
            Section {
                Text("Fixed position beacon — broadcast your location to other D-Rats stations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Latitude (e.g. 30.2672)", value: $working.fixedLatitude,
                          format: .number.precision(.fractionLength(0...6)))
                    .onChange(of: working.fixedLatitude) { _, _ in commit() }
                    .accessibilityHint("Decimal degrees. Negative values are south of the equator.")

                TextField("Longitude (e.g. -97.7431)", value: $working.fixedLongitude,
                          format: .number.precision(.fractionLength(0...6)))
                    .onChange(of: working.fixedLongitude) { _, _ in commit() }
                    .accessibilityHint("Decimal degrees. Negative values are west of the prime meridian.")

                TextField("Comment", text: $working.gpsComment)
                    .onChange(of: working.gpsComment) { _, _ in commit() }
                    .accessibilityHint("Free-form text broadcast with your position fix. Clipped to 43 characters on the wire.")
            }

            Section {
                Button("Send beacon now") {
                    store.broadcastGPSBeacon()
                }
                .disabled(working.fixedLatitude == nil
                          || working.fixedLongitude == nil
                          || store.connectionStatus != .connected)
                .accessibilityHint("Transmit your configured fixed position as a D-Rats APRS beacon. Requires an active connection and a fixed latitude and longitude.")
            } footer: {
                Text("Broadcasts as a D-Rats $$CRC position report inside a regular chat frame. Other MacRats and upstream D-Rats stations will see your location in their station list.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
