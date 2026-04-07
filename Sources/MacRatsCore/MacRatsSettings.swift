import Foundation

/// Persistent user-facing settings for a MacRats installation. Matches
/// the v1.0 subset of D-Rats's config panels as inventoried in
/// `memory/macrats_feature_parity.md`.
///
/// Stored as JSON at `~/Library/Application Support/MacRats/settings.json`
/// (per Apple HIG — NOT at `~/.d-rats-ev/` or similar). This matches the
/// "MacRats uses ~/Library/Application Support/MacRats/" decision in the
/// feature parity doc.
///
/// Changes to this struct's JSON shape must be backwards-compatible —
/// use optional fields with defaults. MacRats ships as soon as v1.0 is
/// working, and users will have settings files from day one.
public struct MacRatsSettings: Codable, Equatable, Sendable {

    // MARK: - Preferences panel (v1.0)

    /// This station's callsign. The only required field.
    public var callsign: String = ""

    /// Chat message automatically broadcast when MacRats comes online.
    /// Empty string disables the auto-send.
    public var signOnMessage: String = "Online via MacRats"

    /// Chat message automatically broadcast when MacRats is closing.
    /// Empty string disables the auto-send.
    public var signOffMessage: String = "Signing off"

    /// Free-form text returned in ping responses. Defaults to
    /// "Running MacRats <version>". Matches D-Rats's customizable
    /// ping reply text.
    public var pingReplyText: String = "Running MacRats"

    /// Confirm before quitting. Matches D-Rats's `confirm_exit` pref.
    public var confirmExit: Bool = true

    // MARK: - Radio panel (v1.0)

    /// Current radio connection kind. Selecting `.tcpRatflector` is
    /// v1.1; v1.0 ships with .disconnected / .serial / .tcpLoopback.
    public var connectionKind: ConnectionKind = .disconnected

    /// Serial device path for `.serial` connections
    /// (e.g. `/dev/cu.usbmodem2011201`).
    public var serialDevicePath: String = ""

    /// Serial baud rate. TH-D75 normal mode: 9600. Terminal mode: 38400.
    public var serialBaudRate: Int32 = 9600

    /// Host for `.tcpRatflector` / `.tcpLoopback` client mode. v1.1.
    public var tcpHost: String = ""

    /// Port for `.tcpRatflector` / `.tcpLoopback` client or server mode.
    public var tcpPort: UInt16 = 9000

    // MARK: - GPS panel (v1.0)

    /// Fixed latitude (decimal degrees). `nil` = GPS beacon disabled.
    public var fixedLatitude: Double?

    /// Fixed longitude (decimal degrees). `nil` = GPS beacon disabled.
    public var fixedLongitude: Double?

    /// Free-form GPS comment broadcast alongside position fixes.
    public var gpsComment: String = ""

    // MARK: - Appearance panel (v1.0)

    /// Regex pattern — lines matching this are highlighted as "notice".
    /// Typical value: user's own callsign, optionally `(?i)` for case
    /// insensitivity. Matches D-Rats's `notice_regex` pref.
    public var noticeRegex: String = ""

    /// Regex pattern — lines matching this are dimmed as "ignore".
    /// Typical value: `[QST] [CQCQCQ]` to de-emphasize beacons.
    public var ignoreRegex: String = ""

    // MARK: - Chat panel (v1.0)

    /// Show status-update lines (joins/parts) in the chat view.
    /// Matches D-Rats's "Show Status Updates In Chat" toggle.
    public var showStatusUpdatesInChat: Bool = true

    /// Local chat log file directory (inside the app support dir).
    /// Empty string = use the default `<appsupport>/logs/`.
    public var chatLogSubdirectory: String = ""

    // MARK: - Connection types

    public enum ConnectionKind: String, Codable, CaseIterable, Sendable {
        case disconnected     // no transport
        case serial           // /dev/cu.* serial device
        case tcpLoopback      // localhost TCP peer (testing)
        case tcpRatflector    // v1.1 — remote ratflector over TCP

        public var displayName: String {
            switch self {
            case .disconnected:   return "Disconnected"
            case .serial:         return "Serial / USB"
            case .tcpLoopback:    return "TCP (Local test)"
            case .tcpRatflector:  return "Ratflector (Internet)"
            }
        }
    }

    // MARK: - Init

    public init() {}

    // MARK: - Persistence

    /// Default on-disk location: `~/Library/Application Support/MacRats/settings.json`.
    public static func defaultStoreURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true)
        let dir = support.appendingPathComponent("MacRats", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("settings.json")
    }

    /// Load from disk. Returns defaults on any error (no file, corrupt
    /// JSON, schema mismatch) — we don't want a bad settings file to
    /// prevent the app from launching.
    public static func load(from url: URL? = nil) -> MacRatsSettings {
        let resolvedURL: URL
        if let url { resolvedURL = url }
        else if let defaultURL = try? defaultStoreURL() { resolvedURL = defaultURL }
        else { return MacRatsSettings() }

        guard let data = try? Data(contentsOf: resolvedURL) else {
            return MacRatsSettings()
        }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(MacRatsSettings.self, from: data) {
            return decoded
        }
        return MacRatsSettings()
    }

    /// Save to disk.
    public func save(to url: URL? = nil) throws {
        let resolvedURL: URL
        if let url { resolvedURL = url }
        else { resolvedURL = try Self.defaultStoreURL() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: resolvedURL, options: .atomic)
    }

    // MARK: - Validation

    /// Returns nil if the settings are valid, else a human-readable reason
    /// why they can't be used to start a connection. The UI uses this to
    /// enable/disable the Connect button.
    public func connectionValidationError() -> String? {
        if callsign.isEmpty {
            return "Callsign is required."
        }
        switch connectionKind {
        case .disconnected:
            return "No connection type selected."
        case .serial:
            if serialDevicePath.isEmpty {
                return "Select a serial device."
            }
            if serialBaudRate <= 0 {
                return "Baud rate must be positive."
            }
        case .tcpLoopback, .tcpRatflector:
            if tcpPort == 0 {
                return "TCP port must be set."
            }
            if connectionKind == .tcpRatflector && tcpHost.isEmpty {
                return "Ratflector host is required."
            }
        }
        return nil
    }
}
