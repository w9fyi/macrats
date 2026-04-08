import Foundation

/// One entry in the MacRats chat log — either an incoming or outgoing
/// chat message, a ping event, or a station status update.
///
/// These values are the SwiftUI-facing record type; the underlying DDT2
/// frames have been normalized into a display-friendly form by
/// `MacRatsAppModel`.
public struct ChatMessage: Identifiable, Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        /// A plain chat message from one station to another (or CQCQCQ).
        case message

        /// A ping request observed on the wire.
        case pingRequest

        /// A ping reply from another station.
        case pingResponse(replyText: String)

        /// A station status update ("W9FYI: Online — K in Austin").
        case status(StationStatus)

        /// An internal event — connection state changes, errors, etc.
        /// Not a real on-air frame.
        case systemEvent

        /// A GPS position fix from a station's `$$CRC` beacon. The
        /// latitude and longitude are decimal degrees; the chat view
        /// renders this as a one-line "📍 W9FYI at 30.267,-97.743"
        /// entry rather than showing the raw APRS payload.
        case gpsFix(latitude: Double, longitude: Double)
    }

    public let id: UUID
    public let timestamp: Date
    public let kind: Kind

    /// Source callsign. Empty string for system events.
    public let sStation: String

    /// Destination callsign. "CQCQCQ" for broadcasts, empty for system events.
    public let dStation: String

    /// Message text. For ping responses, this is the free-form reply
    /// text; for status updates, it's the status message; for regular
    /// chat, it's the user's message.
    public let text: String

    /// Whether this message was transmitted BY us (vs received FROM
    /// another station). Used by the UI to right-align outgoing messages
    /// and dim incoming ones.
    public let outgoing: Bool

    public init(id: UUID = UUID(),
                timestamp: Date = Date(),
                kind: Kind,
                sStation: String,
                dStation: String,
                text: String,
                outgoing: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.sStation = sStation
        self.dStation = dStation
        self.text = text
        self.outgoing = outgoing
    }

    // MARK: - Classification helpers for filtering

    /// True if this message is a status-update line that the user may
    /// want to hide (joins/parts, online/offline announcements). The
    /// chat view consults this when the "Show Status Updates In Chat"
    /// setting is off.
    public var isStatusUpdate: Bool {
        switch kind {
        case .status:
            return true
        case .message, .pingRequest, .pingResponse, .systemEvent, .gpsFix:
            return false
        }
    }

    /// Check whether this message's text matches a regex pattern. Used
    /// for "notice" (highlight when your callsign is mentioned) and
    /// "ignore" (dim beacon lines) filtering.
    public func matches(regex pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        // Regex compilation failures are not fatal — an invalid regex
        // in the settings should not cause the chat view to crash.
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
