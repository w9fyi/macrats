import Foundation

/// D-Rats session types. Matches the `T_*` constants from
/// `d_rats/sessions/base.py` exactly — these values are on the wire and
/// must not drift from upstream.
public enum SessionType: UInt8, Sendable {
    case stateless = 0
    case general   = 1
    case unused2   = 2  // legacy — old non-pipelined file transfer
    case unused3   = 3  // legacy — old non-pipelined form transfer
    case socket    = 4
    case fileXfer  = 5
    case formXfer  = 6
    case rpc       = 7
}

/// D-Rats session lifecycle state. Matches `ST_*` from `base.py`.
public enum SessionState: Sendable, Equatable {
    case closed        // ST_CLSD
    case opening       // ST_CLSW (close-wait — originally meant "waiting for open ack")
    case open          // ST_OPEN
    case syncing       // ST_SYNC
}

/// Station online/unattended/offline status broadcast in chat T_STATUS frames.
/// Matches the `STATUS_*` constants in `d_rats/station_status.py`.
public enum StationStatus: Int, Sendable {
    case unknown    = 0
    case online     = 1
    case unattended = 2
    case offline    = 9

    public static let min = 0
    public static let max = 9

    public var description: String {
        switch self {
        case .unknown:    return "Unknown"
        case .online:     return "Online"
        case .unattended: return "Unattended"
        case .offline:    return "Offline"
        }
    }
}

/// Errors specific to session processing.
public enum SessionError: Error, LocalizedError {
    case sessionClosed
    case invalidStatus(Int)
    case notAttachedToManager

    public var errorDescription: String? {
        switch self {
        case .sessionClosed:
            return "Session is closed"
        case .invalidStatus(let n):
            return "Station status value \(n) is out of range (\(StationStatus.min)..\(StationStatus.max))"
        case .notAttachedToManager:
            return "Session is not attached to a session manager"
        }
    }
}

/// A `Session` is one application-level conversation riding on top of the
/// DDT2 framing layer. Each outbound frame from the session carries the
/// session's numeric `id` in the DDT2 `session` field, and inbound frames
/// are dispatched back to the right session by `SessionManager` based on
/// that same field.
///
/// This protocol matches the shape of `d_rats.sessions.base.Session` from
/// upstream D-Rats, simplified for Swift:
/// - No explicit state machine for stateless sessions (chat is stateless).
/// - Inbound delivery is an async callback on `handler`, not a polled
///   blocking queue, because SwiftUI and dispatch sources want push, not
///   pull.
/// - `write()` builds a `DDT2Frame` and hands it to the session manager's
///   `outgoing(_:frame:)` method, which then framed + transported it.
///
/// Concrete conformances: `StatelessSession` (base), `ChatSession`
/// (everything MacRats v1.0 needs). Stateful file transfer is a v1.1 task.
public protocol Session: AnyObject, Sendable {

    /// Human-readable session name for logging.
    var name: String { get }

    /// Wire-level session type. Drives the DDT2 frame `type` field semantics.
    var type: SessionType { get }

    /// Numeric session id (0..255). Assigned by the SessionManager when the
    /// session is registered.
    var id: UInt8 { get set }

    /// Whether the session's frames should be zlib-compressed. Chat sessions
    /// set this to false because chat messages are usually tiny and
    /// compression overhead exceeds savings.
    var compress: Bool { get }

    /// Callback invoked on inbound `DDT2Frame` delivery. Set by the session
    /// when it registers with the manager. The manager calls this from its
    /// own queue — implementations must be thread-safe.
    var handler: ((DDT2Frame) -> Void)? { get set }

    /// Back-pointer to the owning session manager. Set by
    /// `SessionManager.add(_:)` at registration time.
    var manager: SessionManager? { get set }

    /// Current lifecycle state. Stateless sessions stay `.open` forever
    /// after registration; stateful sessions transition through opening,
    /// syncing, etc.
    var state: SessionState { get set }

    /// Number of bytes sent, received, and retried on this session.
    /// Mirrors the `stats` dict on upstream `base.Session`.
    var stats: SessionStats { get set }
}

/// Per-session cumulative statistics.
public struct SessionStats: Sendable, Equatable {
    public var sentBytes: Int = 0
    public var receivedBytes: Int = 0
    public var sentWireBytes: Int = 0
    public var receivedWireBytes: Int = 0
    public var retries: Int = 0
}
