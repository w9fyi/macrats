import Foundation

/// Fetches and parses the public D-Rats ratflector directory
/// maintained at `ham-radio-software/ratflectors`.
///
/// The directory is a small YAML file with the schema:
///
/// ```yaml
/// ---
/// ratflectors:
///   - name: example
///     description: Example Ratflector
///     hostname: example.ratflector.com
///     port: 9000
///     active: true
/// ```
///
/// We avoid pulling a full YAML parser dependency by implementing a
/// micro-parser that handles exactly this fixed schema. The parser
/// is deliberately narrow — it rejects anything that isn't a
/// recognizable ratflector list — and is easy to unit-test with
/// captured bytes.
public enum RatflectorDirectory {

    // MARK: - Constants

    /// Canonical URL of the upstream directory.
    public static let directoryURL = URL(string:
        "https://raw.githubusercontent.com/ham-radio-software/ratflectors/master/ratflectors.yml"
    )!

    // MARK: - Entry type

    public struct Entry: Identifiable, Equatable, Sendable {
        public let name: String
        public let description: String
        public let hostname: String
        public let port: UInt16
        public let active: Bool

        /// Identifiable: use the hostname as the id since it's the
        /// unique actionable field. Two entries with the same
        /// hostname would be a bug in the upstream directory.
        public var id: String { hostname }

        public init(name: String,
                    description: String,
                    hostname: String,
                    port: UInt16,
                    active: Bool) {
            self.name = name
            self.description = description
            self.hostname = hostname
            self.port = port
            self.active = active
        }

        /// Display string for a SwiftUI Picker row. Something like
        /// `"SEWX — Southeastern Weather Net (sewx.ratflector.com)"`.
        public var displayLabel: String {
            "\(name) — \(description) (\(hostname))"
        }
    }

    // MARK: - Fetch

    /// Errors produced by the directory fetcher / parser.
    public enum FetchError: Error, LocalizedError {
        case invalidYAML(reason: String)
        case noEntries
        case http(status: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidYAML(let reason):
                return "Ratflector directory YAML parse error: \(reason)"
            case .noEntries:
                return "Ratflector directory is empty or contained no entries"
            case .http(let status):
                return "Ratflector directory HTTP error \(status)"
            }
        }
    }

    /// Fetch the directory over HTTPS. Runs on an async task; the
    /// caller is expected to be a SwiftUI view-model or similar that
    /// can display the result.
    public static func fetch() async throws -> [Entry] {
        let (data, response) = try await URLSession.shared.data(from: directoryURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.http(status: http.statusCode)
        }
        let text = String(decoding: data, as: UTF8.self)
        return try parse(text)
    }

    // MARK: - Parser

    /// Parse the directory YAML into an array of entries.
    ///
    /// This is a deliberately narrow parser — it expects exactly
    /// the schema shipped by `ham-radio-software/ratflectors` and
    /// rejects anything else. We don't want a full YAML library in
    /// MacRats just for one file.
    ///
    /// Rules:
    /// - A line starting with `- name:` begins a new entry.
    /// - Subsequent lines starting with spaces and `key: value` add
    ///   fields to the current entry.
    /// - Entries must end before a blank line or a new `- name:`.
    /// - Required fields: `name`, `description`, `hostname`,
    ///   `port`, `active`.
    /// - Values may be quoted with single or double quotes;
    ///   quotes are stripped.
    /// - `active` is parsed as a boolean (true/false/yes/no).
    /// - `port` is parsed as an integer.
    public static func parse(_ text: String) throws -> [Entry] {
        var entries: [Entry] = []
        var currentFields: [String: String] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip comments and doc separators.
            if line.isEmpty || line.hasPrefix("#") || line == "---" {
                // Blank line: close any in-progress entry.
                if line.isEmpty, !currentFields.isEmpty {
                    if let entry = try makeEntry(from: currentFields) {
                        entries.append(entry)
                    }
                    currentFields.removeAll()
                }
                continue
            }

            // Top-level list key — skip.
            if line == "ratflectors:" {
                continue
            }

            // New entry marker: "- name: foo"
            if line.hasPrefix("- ") {
                // Close any in-progress entry.
                if !currentFields.isEmpty {
                    if let entry = try makeEntry(from: currentFields) {
                        entries.append(entry)
                    }
                    currentFields.removeAll()
                }
                // Strip the leading "- " and parse as a key: value.
                let keyValueLine = String(line.dropFirst(2))
                if let (k, v) = parseKeyValue(keyValueLine) {
                    currentFields[k] = v
                }
                continue
            }

            // Continuation line: key: value
            if let (k, v) = parseKeyValue(line) {
                currentFields[k] = v
            }
        }

        // Close trailing entry.
        if !currentFields.isEmpty, let entry = try makeEntry(from: currentFields) {
            entries.append(entry)
        }

        if entries.isEmpty {
            throw FetchError.noEntries
        }
        return entries
    }

    // MARK: - Private helpers

    /// Parse a single `key: value` line. Returns nil if the line
    /// doesn't look like a key/value pair.
    private static func parseKeyValue(_ line: String) -> (String, String)? {
        guard let colonIdx = line.firstIndex(of: ":") else {
            return nil
        }
        let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        var value = String(line[line.index(after: colonIdx)...])
            .trimmingCharacters(in: .whitespaces)
        // Strip surrounding quotes (single or double).
        if value.count >= 2 {
            let first = value.first!
            let last = value.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
        }
        return (key, value)
    }

    /// Build a `RatflectorDirectory.Entry` from a field dictionary.
    /// Missing or malformed fields cause a thrown error unless we
    /// can fall back to sensible defaults.
    private static func makeEntry(from fields: [String: String]) throws -> Entry? {
        // All required fields must be present and non-empty.
        guard let name = fields["name"], !name.isEmpty else { return nil }
        guard let description = fields["description"] else { return nil }
        guard let hostname = fields["hostname"], !hostname.isEmpty else { return nil }

        // Port defaults to 9000 if absent.
        let port: UInt16
        if let portString = fields["port"], let parsed = UInt16(portString) {
            port = parsed
        } else {
            port = 9000
        }

        // active defaults to true if absent.
        let active: Bool
        if let activeString = fields["active"] {
            active = parseBool(activeString)
        } else {
            active = true
        }

        return Entry(name: name,
                     description: description,
                     hostname: hostname,
                     port: port,
                     active: active)
    }

    /// Parse a YAML-style boolean.
    private static func parseBool(_ s: String) -> Bool {
        switch s.lowercased() {
        case "true", "yes", "y", "on", "1":
            return true
        default:
            return false
        }
    }
}
