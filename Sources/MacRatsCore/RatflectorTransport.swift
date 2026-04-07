import Foundation
import Network

/// A `RadioTransport` that connects to a D-Rats ratflector over TCP.
///
/// After the TCP connection reaches `.ready`, the transport runs the
/// text-based handshake in `RatflectorHandshake.performHandshake()`
/// and only then starts the regular receive loop that delivers raw
/// bytes to `SessionManager.ingestBytes(_:)`.
///
/// This is deliberately a separate class from `TCPLoopbackTransport`.
/// The loopback transport is the dumb byte-pipe used for two-MacRats
/// integration tests; the ratflector transport carries the handshake
/// state machine and a callsign/password. Keeping them separate means
/// the loopback tests stay simple and fast, and the ratflector
/// handshake logic lives in one well-tested place.
///
/// Wire protocol is plaintext TCP — no TLS, no encryption. This
/// matches upstream D-Rats exactly. The "security" model for
/// ratflectors is "it's a public chat server on the internet, don't
/// say anything on it you wouldn't say on the air."
public final class RatflectorTransport: RadioTransport, @unchecked Sendable {

    // MARK: - Configuration

    public let host: String
    public let port: UInt16
    public let callsign: String?
    public let password: String?
    public let displayName: String

    // MARK: - State

    private let queue = DispatchQueue(label: "MacRatsCore.RatflectorTransport")
    private let stateLock = NSLock()

    private var _status: TransportStatus = .disconnected
    public var status: TransportStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return _status
    }

    private weak var delegate: RadioTransportDelegate?
    private var connection: NWConnection?

    // Buffer used during the handshake phase. Once the handshake
    // finishes, this is drained and never touched again — from that
    // point on bytes flow directly to the delegate.
    private var handshakeBuffer = Data()
    private var handshakeDone = false

    /// Optional override of the handshake read timeout. Defaults to
    /// 5 seconds. 30 seconds is upstream D-Rats's value, but 5
    /// seconds is plenty for a server that's going to respond
    /// immediately and keeps the "old-school ratflector" fallback
    /// from being annoying.
    public let handshakeTimeoutSeconds: TimeInterval

    // MARK: - Init

    public init(host: String,
                port: UInt16 = 9000,
                callsign: String? = nil,
                password: String? = nil,
                handshakeTimeoutSeconds: TimeInterval = 5) {
        self.host = host
        self.port = port
        self.callsign = callsign
        self.password = password
        self.handshakeTimeoutSeconds = handshakeTimeoutSeconds
        self.displayName = "Ratflector \(host):\(port)"
    }

    // MARK: - RadioTransport

    public func setDelegate(_ delegate: RadioTransportDelegate?) {
        stateLock.lock(); defer { stateLock.unlock() }
        self.delegate = delegate
    }

    public func connect() throws {
        setStatus(.connecting)

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            setStatus(.failed("Invalid port \(port)"))
            throw TransportError.descriptive("Invalid ratflector port \(port)")
        }

        let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.beginHandshake(on: conn)
            case .failed(let err):
                self.notifyError(err)
                self.setStatus(.failed("connection failed: \(err.localizedDescription)"))
            case .waiting(let err):
                self.notifyError(err)
            case .cancelled:
                self.setStatus(.disconnected)
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    public func disconnect() {
        if let conn = connection {
            connection = nil
            conn.cancel()
        }
        setStatus(.disconnected)
    }

    public func send(_ data: Data) throws {
        guard let conn = connection else {
            throw TransportError.notConnected
        }
        // Once the handshake completes, writes are unrestricted. If
        // a write happens before the handshake completes (which
        // shouldn't happen because the status isn't .connected yet),
        // we still pass it through to NWConnection so it queues
        // normally behind the TCP buffer.
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.notifyError(error)
            }
        })
    }

    // MARK: - Handshake

    /// The handshake is a short sequence of line-based reads and
    /// writes. We reuse `NWConnection.receive` to pull bytes into
    /// `handshakeBuffer`, scan for a line terminator, and feed each
    /// complete line to `RatflectorHandshake.performHandshake()` by
    /// driving it synchronously through a DispatchSemaphore.
    ///
    /// This is the only place in MacRats where we block a dispatch
    /// queue — everywhere else we're fully non-blocking. The block
    /// is bounded by `handshakeTimeoutSeconds` (default 5s) so a
    /// misbehaving server can't lock us up.
    private func beginHandshake(on conn: NWConnection) {
        // Kick off the first inbound receive to fill the handshake
        // buffer. We keep recursively receiving into the buffer
        // until the handshake completes or times out.
        receiveHandshakeBytes(on: conn)

        // The handshake itself runs on a background thread because
        // it needs to block waiting for line reads that are driven
        // by the async NWConnection receive callbacks. When it
        // finishes, we either flip status to .connected and begin
        // the real receive loop, or mark the transport as failed.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let result: Result<RatflectorHandshake.Result, Error>
            do {
                let handshakeResult = try RatflectorHandshake.performHandshake(
                    callsign: self.callsign,
                    password: self.password,
                    read: { try self.readHandshakeLine() },
                    write: { data in
                        try self.writeHandshakeBytes(data, on: conn)
                    }
                )
                result = .success(handshakeResult)
            } catch {
                result = .failure(error)
            }

            switch result {
            case .success(let kind):
                self.log("ratflector handshake: \(kind)")
                self.stateLock.lock()
                self.handshakeDone = true
                let leftover = self.handshakeBuffer
                self.handshakeBuffer = Data()
                self.stateLock.unlock()

                // If the handshake reads happened to pull in extra
                // bytes beyond the final handshake line (e.g. a
                // server that sent the banner and a DDT2 frame in
                // the same TCP segment), deliver those to the
                // delegate immediately so the splitter can process
                // them.
                self.setStatus(.connected)
                if !leftover.isEmpty {
                    self.notifyReceive(leftover)
                }
                self.startReceiveLoop(on: conn)

            case .failure(let error):
                self.notifyError(error)
                self.setStatus(.failed(error.localizedDescription))
                self.disconnect()
            }
        }
    }

    /// Post a fresh `receive` call on the NWConnection that appends
    /// inbound bytes to `handshakeBuffer`. Called recursively until
    /// the handshake finishes or the connection dies. The blocking
    /// `readHandshakeLine()` reads from the buffer as it fills.
    private func receiveHandshakeBytes(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1,
                     maximumLength: 8 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.notifyError(error)
                return
            }
            if let data, !data.isEmpty {
                self.stateLock.lock()
                if !self.handshakeDone {
                    self.handshakeBuffer.append(data)
                } else {
                    // Handshake already finished (race) — deliver
                    // directly.
                    self.stateLock.unlock()
                    self.notifyReceive(data)
                    return
                }
                self.stateLock.unlock()
            }
            if isComplete {
                return
            }
            self.stateLock.lock()
            let stillHandshaking = !self.handshakeDone
            self.stateLock.unlock()
            if stillHandshaking {
                self.receiveHandshakeBytes(on: conn)
            }
        }
    }

    /// Block until one complete `\r\n` or `\n` terminated line is
    /// available in `handshakeBuffer`, then return it (with the
    /// terminator stripped). Throws `.timeout` if no complete line
    /// appears within `handshakeTimeoutSeconds`, `.eof` if the
    /// connection closes during the wait.
    ///
    /// Implemented via polling with a short sleep — simpler than
    /// a DispatchSemaphore dance, and the handshake is a tiny
    /// one-shot operation so the few extra ms per poll don't matter.
    private func readHandshakeLine() throws -> String {
        let deadline = Date().addingTimeInterval(handshakeTimeoutSeconds)
        while Date() < deadline {
            stateLock.lock()
            // Look for a newline in the current buffer.
            if let newlineIdx = handshakeBuffer.firstIndex(of: 0x0A) { // '\n'
                let lineBytes = handshakeBuffer[..<newlineIdx]
                // Strip the line (and the \n) from the buffer.
                handshakeBuffer.removeSubrange(handshakeBuffer.startIndex...newlineIdx)
                stateLock.unlock()
                // Trim trailing \r if present.
                var bytes = Array(lineBytes)
                if bytes.last == 0x0D {
                    bytes.removeLast()
                }
                return String(decoding: bytes, as: UTF8.self)
            }
            stateLock.unlock()
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Deadline expired — caller decides whether this is timeout
        // or EOF. If the buffer is empty, we treat it as EOF;
        // otherwise as timeout.
        stateLock.lock()
        let bufferEmpty = handshakeBuffer.isEmpty
        stateLock.unlock()
        throw bufferEmpty
            ? RatflectorHandshakeError.eof
            : RatflectorHandshakeError.timeout
    }

    /// Write raw bytes during the handshake. Unlike the normal
    /// `send(_:)` path this one is synchronous so the handshake
    /// state machine can wait on completions. We use a semaphore
    /// to block until the NWConnection acknowledges the write.
    private func writeHandshakeBytes(_ data: Data, on conn: NWConnection) throws {
        let sem = DispatchSemaphore(value: 0)
        var sendError: Error?
        conn.send(content: data, completion: .contentProcessed { err in
            sendError = err
            sem.signal()
        })
        _ = sem.wait(timeout: .now() + handshakeTimeoutSeconds)
        if let sendError {
            throw sendError
        }
    }

    // MARK: - Main receive loop (post-handshake)

    private func startReceiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1,
                     maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.notifyReceive(data)
            }
            if let error {
                self.notifyError(error)
                return
            }
            if isComplete {
                self.disconnect()
                return
            }
            self.queue.async {
                self.startReceiveLoop(on: conn)
            }
        }
    }

    // MARK: - Status / delegate plumbing

    private func setStatus(_ newStatus: TransportStatus) {
        let delegate: RadioTransportDelegate?
        stateLock.lock()
        if _status == newStatus {
            stateLock.unlock()
            return
        }
        _status = newStatus
        delegate = self.delegate
        stateLock.unlock()
        delegate?.transport(self, didChangeStatus: newStatus)
    }

    private func notifyReceive(_ data: Data) {
        let delegate: RadioTransportDelegate?
        stateLock.lock()
        delegate = self.delegate
        stateLock.unlock()
        delegate?.transport(self, didReceive: data)
    }

    private func notifyError(_ error: Error) {
        let delegate: RadioTransportDelegate?
        stateLock.lock()
        delegate = self.delegate
        stateLock.unlock()
        delegate?.transport(self, didEncounterError: error)
    }

    private func log(_ message: String) {
        // Ratflector transport doesn't have its own log handler —
        // fold diagnostic messages into the delegate error channel
        // under the assumption the app layer mirrors them somewhere
        // useful (status bar, wire log, etc.).
        //
        // No-op for now; reserved for a future dedicated log sink.
        _ = message
    }
}
