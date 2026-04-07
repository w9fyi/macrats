import Foundation

/// `SessionManager` is the glue between the application-level session
/// layer (`ChatSession`, future `FileSession`, etc.) and the byte-pipe
/// transport layer (`USBSerialTransport`, `TCPLoopbackTransport`).
///
/// Responsibilities:
///
/// 1. Own a `RadioTransport` instance and keep it connected.
/// 2. Run inbound bytes through a `DDT2FrameSplitter` to reassemble
///    SOB/EOB envelopes, decode them into `DDT2Frame` values, and
///    dispatch each one to the matching `Session` by session id.
/// 3. Accept outbound `DDT2Frame` values from sessions via
///    `outgoing(_:frame:)`, encode them through `DDT2EncodedFrame.pack()`,
///    and hand the resulting bytes to the transport.
/// 4. Maintain the list of registered sessions (indexed by session id).
///
/// Mirrors a subset of `d_rats.sessionmgr.SessionManager` from upstream.
/// The parts we don't need yet:
///
/// - Session open/close handshake for stateful sessions (stateful file
///   transfer is v1.1).
/// - The station list (heard-stations cache) — that's a MacRats app-level
///   concern and lives outside the core.
/// - The "keep alive" ping every N seconds — will be added when we have
///   a UI to toggle it.
///
/// `SessionManager` is an `NSLock`-protected class, not an actor, because
/// it needs to be callable from the transport's dispatch queue (which
/// isn't an actor context) AND from the SwiftUI main actor without a
/// hop-and-wait every time a session wants to write.
public final class SessionManager: @unchecked Sendable {

    // MARK: - Configuration

    /// This station's callsign. Stamped into every outbound frame as the
    /// source station. Used to decide whether inbound frames are addressed
    /// to us.
    public let callsign: String

    /// The byte-pipe transport this manager owns.
    public let transport: RadioTransport

    // MARK: - Internal state

    private let lock = NSLock()
    private var sessionsById: [UInt8: Session] = [:]
    private let splitter = DDT2FrameSplitter()
    private let scheduleQueue = DispatchQueue(label: "MacRatsCore.SessionManager.schedule")

    /// Optional callback the transport delegate hops through.
    private var transportDelegateShim: ManagerTransportShim?

    /// Optional log callback — used by sessions to surface diagnostic
    /// messages back to the app without pulling in a full logger
    /// dependency. MacRats's app layer will typically plug a real logger
    /// in here.
    public var logHandler: (@Sendable (String) -> Void)?

    /// Optional callback invoked for every inbound DDT2 frame *before*
    /// it's routed to a session. Useful for:
    /// - building a "heard stations" list from frame.sStation
    /// - raw traffic monitoring in the UI
    /// - dropping frames for stations on an ignore list
    public var onInboundFrame: (@Sendable (DDT2Frame) -> Void)?

    /// Optional callback invoked when an inbound frame's session id does
    /// not match any registered session. The app may want to log or
    /// display unknown-session traffic so the user can tell that
    /// *something* is out there.
    public var onUnroutedFrame: (@Sendable (DDT2Frame) -> Void)?

    // MARK: - Init

    public init(callsign: String, transport: RadioTransport) {
        self.callsign = callsign
        self.transport = transport
        let shim = ManagerTransportShim(owner: self)
        self.transportDelegateShim = shim
        transport.setDelegate(shim)
    }

    // MARK: - Session registry

    /// Register a session. Assigns the session's id if not already set.
    /// The manager holds a strong reference to the session; the session
    /// holds a weak reference back via its `manager` property.
    public func add(_ session: Session, id: UInt8? = nil) {
        lock.lock()
        defer { lock.unlock() }

        if let explicit = id {
            session.id = explicit
        } else if session.id == 0 {
            // Assign the next unused id, starting at 1 (id 0 is reserved
            // for the control session in upstream D-Rats).
            var next: UInt8 = 1
            while sessionsById[next] != nil {
                if next == 255 {
                    preconditionFailure("SessionManager: session ids exhausted")
                }
                next += 1
            }
            session.id = next
        }
        sessionsById[session.id] = session
        session.manager = self
        session.state = .open
    }

    /// Unregister a session by id.
    public func remove(_ session: Session) {
        lock.lock()
        defer { lock.unlock() }
        sessionsById.removeValue(forKey: session.id)
        session.state = .closed
        session.manager = nil
    }

    /// Look up a session by id. Primarily for tests.
    public func session(id: UInt8) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return sessionsById[id]
    }

    // MARK: - Outgoing path (sessions → transport)

    /// Called by a `Session` when it has a frame ready to send. The
    /// manager encodes the frame through `DDT2EncodedFrame.pack()` and
    /// writes the result to the transport.
    public func outgoing(_ session: Session, frame: DDT2Frame) throws {
        var finalFrame = frame
        finalFrame.session = session.id  // force the session id onto every frame

        let encoded = DDT2EncodedFrame.pack(finalFrame)

        // Update stats under the lock.
        lock.lock()
        session.stats.sentBytes += finalFrame.data.count
        session.stats.sentWireBytes += encoded.count
        lock.unlock()

        try transport.send(encoded)
    }

    // MARK: - Incoming path (transport → sessions)

    /// Feed raw inbound bytes. The transport delegate calls this
    /// automatically via the shim. Exposed publicly for tests that want
    /// to inject frames without wiring up a full transport.
    public func ingestBytes(_ data: Data) {
        let frames = splitter.feed(data)
        for wireFrame in frames {
            do {
                let decoded = try DDT2EncodedFrame.unpack(wireFrame)
                routeIncoming(decoded, wireSize: wireFrame.count)
            } catch {
                log("inbound decode failed: \(error.localizedDescription)")
            }
        }
    }

    private func routeIncoming(_ frame: DDT2Frame, wireSize: Int) {
        // Hook for the app layer — heard-stations list, traffic monitor,
        // etc. Runs before the per-session dispatch so the app sees
        // everything, even frames that don't route to a registered
        // session.
        onInboundFrame?(frame)

        lock.lock()
        let session = sessionsById[frame.session]
        lock.unlock()

        guard let session else {
            onUnroutedFrame?(frame)
            log("unrouted frame: session=\(frame.session) from=\(frame.sStation) to=\(frame.dStation) bytes=\(frame.data.count)")
            return
        }

        // Update receive stats under the lock, then deliver the frame.
        lock.lock()
        session.stats.receivedWireBytes += wireSize
        lock.unlock()

        if let stateless = session as? StatelessSession {
            stateless.deliver(frame)
        } else {
            session.handler?(frame)
        }
    }

    // MARK: - Delayed execution (for ping-reply random delays)

    /// Run a closure after `delay` seconds on a private queue. Used by
    /// ChatSession to implement the random-delay broadcast-ping replies
    /// without blocking the transport read queue.
    public func scheduleAfter(_ delay: TimeInterval, _ block: @escaping @Sendable () -> Void) {
        if delay <= 0 {
            scheduleQueue.async(execute: block)
        } else {
            scheduleQueue.asyncAfter(deadline: .now() + delay, execute: block)
        }
    }

    // MARK: - Logging

    public func log(_ message: String) {
        logHandler?(message)
    }

    // MARK: - Transport lifecycle passthroughs

    public func connect() throws {
        try transport.connect()
    }

    public func disconnect() {
        transport.disconnect()
    }
}

// MARK: - Transport delegate shim

/// The `RadioTransportDelegate` is retained by the transport via a weak
/// reference, which means the `SessionManager` itself can't be the
/// delegate (it would be released before the transport calls back). We
/// use a small shim that keeps the manager alive for as long as the
/// transport holds onto this shim as its delegate.
private final class ManagerTransportShim: RadioTransportDelegate, @unchecked Sendable {
    // Strong reference — the manager owns this shim, and the shim owns
    // the manager. Retain cycle is broken when the manager is released
    // (the shim goes with it).
    weak var owner: SessionManager?

    init(owner: SessionManager) {
        self.owner = owner
    }

    func transport(_ transport: RadioTransport, didReceive data: Data) {
        owner?.ingestBytes(data)
    }

    func transport(_ transport: RadioTransport, didChangeStatus status: TransportStatus) {
        owner?.log("transport status: \(status)")
    }

    func transport(_ transport: RadioTransport, didEncounterError error: Error) {
        owner?.log("transport error: \(error.localizedDescription)")
    }
}
