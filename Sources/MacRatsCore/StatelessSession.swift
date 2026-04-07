import Foundation

/// A stateless session — fires off a single DDT2 frame per outbound
/// message with no acknowledgement, sequencing, or retry. Mirrors
/// `d_rats.sessions.stateless.StatelessSession` in upstream.
///
/// This is the base class for `ChatSession`. The "stateless" naming is
/// from upstream and refers to the D-Rats session layer, not to the
/// transport below — the DDT2 frames themselves still carry a source and
/// destination callsign and a CRC, they just aren't paired into a
/// request/response dance by this layer.
open class StatelessSession: Session, @unchecked Sendable {

    // MARK: - Session conformance

    public var name: String
    public var type: SessionType = .stateless
    public var id: UInt8 = 0
    public var compress: Bool = true
    public var handler: ((DDT2Frame) -> Void)?
    public weak var manager: SessionManager?
    public var state: SessionState = .closed
    public var stats = SessionStats()

    // MARK: - Protocol-level config

    /// Default wire sub-type used by `write(_:dest:)`. Matches `T_DEF = 0`
    /// in upstream stateless.py. Subclasses (e.g. ChatSession) may use
    /// multiple sub-types (`T_PNG_REQ`, `T_STATUS`, etc.) via
    /// `send(frameType:data:dest:)`.
    public var defaultFrameType: UInt8 = 0

    public init(name: String) {
        self.name = name
    }

    // MARK: - Outbound

    /// Write one message. Builds a DDT2 frame and hands it to the session
    /// manager's `outgoing(_:frame:)` for framing and transport.
    open func write(_ data: Data, dest: String = "CQCQCQ") throws {
        guard let manager else { throw SessionError.notAttachedToManager }

        var frame = DDT2Frame()
        frame.seq = 0
        frame.session = id
        frame.type = defaultFrameType
        frame.sStation = manager.callsign
        frame.dStation = dest
        frame.data = data
        frame.compress = compress

        try manager.outgoing(self, frame: frame)
    }

    /// Convenience for sending a UTF-8 string.
    open func write(_ text: String, dest: String = "CQCQCQ") throws {
        try write(Data(text.utf8), dest: dest)
    }

    /// Send with an explicit frame sub-type. Used by subclasses that have
    /// more than one frame type (chat has 6: default, ping req/rsp, echo
    /// req/rsp, status).
    open func send(frameType: UInt8, data: Data, dest: String) throws {
        guard let manager else { throw SessionError.notAttachedToManager }

        var frame = DDT2Frame()
        frame.seq = 0
        frame.session = id
        frame.type = frameType
        frame.sStation = manager.callsign
        frame.dStation = dest
        frame.data = data
        frame.compress = compress

        try manager.outgoing(self, frame: frame)
    }

    // MARK: - Inbound

    /// Default inbound handling — just forwards to `handler`. Subclasses
    /// override `incomingData(_:)` to interpret the frame type.
    public func deliver(_ frame: DDT2Frame) {
        stats.receivedBytes += frame.data.count
        incomingData(frame)
    }

    /// Override point for subclasses. The default implementation forwards
    /// the frame to the external `handler` callback. ChatSession overrides
    /// this to interpret T_PNG_REQ/T_STATUS/etc.
    open func incomingData(_ frame: DDT2Frame) {
        handler?(frame)
    }
}
