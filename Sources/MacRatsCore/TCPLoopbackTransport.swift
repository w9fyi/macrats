import Foundation
import Network

/// A `RadioTransport` backed by a TCP socket.
///
/// Two modes:
///
/// - **Server**: bind a `NWListener` on a port, accept the first incoming
///   connection. Used by the "test peer" side when two MacRats instances
///   on the same Mac are talking to each other.
///
/// - **Client**: connect a `NWConnection` to a host:port. Used by the active
///   side, or for connecting to a remote D-Rats instance over Tailscale, etc.
///
/// This transport is **not** for talking to a real radio over IP. It exists
/// purely for:
/// 1. Unit and integration tests of the protocol/session layers without
///    needing the TH-D75 plugged in.
/// 2. Local two-process MacRats-to-MacRats testing during development.
/// 3. Future "remote MacRats over Tailscale" use cases where one Mac runs the
///    USB-serial transport and exposes it over TCP for another Mac to attach.
public final class TCPLoopbackTransport: RadioTransport, @unchecked Sendable {

    // MARK: - Configuration

    public enum Mode: Sendable {
        case server(port: UInt16)
        case client(host: String, port: UInt16)
    }

    public let mode: Mode
    public let displayName: String

    private let queue = DispatchQueue(label: "MacRatsCore.TCPLoopbackTransport")
    private let stateLock = NSLock()

    private var _status: TransportStatus = .disconnected
    public var status: TransportStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return _status
    }

    private weak var delegate: RadioTransportDelegate?

    // Networking handles
    private var listener: NWListener?
    private var connection: NWConnection?

    // MARK: - Init

    public init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .server(let port):
            self.displayName = "TCP loopback server :\(port)"
        case .client(let host, let port):
            self.displayName = "TCP loopback client \(host):\(port)"
        }
    }

    // MARK: - RadioTransport

    public func setDelegate(_ delegate: RadioTransportDelegate?) {
        stateLock.lock(); defer { stateLock.unlock() }
        self.delegate = delegate
    }

    public func connect() throws {
        setStatus(.connecting)
        switch mode {
        case .server(let port):
            try startListener(port: port)
        case .client(let host, let port):
            startClient(host: host, port: port)
        }
    }

    public func disconnect() {
        if let listener {
            listener.cancel()
            self.listener = nil
        }
        if let connection {
            connection.cancel()
            self.connection = nil
        }
        setStatus(.disconnected)
    }

    public func send(_ data: Data) throws {
        guard let connection else {
            throw TransportError.notConnected
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.notifyError(error)
            }
        })
    }

    // MARK: - Server

    private func startListener(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Listener is up but no peer yet — leave status at .connecting.
                break
            case .failed(let error):
                self.notifyError(error)
                self.setStatus(.failed("listener failed: \(error.localizedDescription)"))
            case .cancelled:
                self.setStatus(.disconnected)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] newConnection in
            guard let self else { return }
            // Accept first connection only — close listener so a second client
            // doesn't pile up.
            self.listener?.cancel()
            self.listener = nil
            self.attach(connection: newConnection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    // MARK: - Client

    private func startClient(host: String, port: UInt16) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        attach(connection: connection)
    }

    // MARK: - Connection plumbing

    private func attach(connection newConnection: NWConnection) {
        self.connection = newConnection
        newConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.setStatus(.connected)
                self.startReceiveLoop(on: newConnection)
            case .failed(let error):
                self.notifyError(error)
                self.setStatus(.failed("connection failed: \(error.localizedDescription)"))
            case .cancelled:
                self.setStatus(.disconnected)
            case .waiting(let error):
                self.notifyError(error)
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func startReceiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
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
            // Tail-recurse via dispatch — keeps us off the call stack.
            self.queue.async {
                self.startReceiveLoop(on: connection)
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
}

// MARK: - Errors

public enum TransportError: Error, LocalizedError {
    case notConnected
    case alreadyConnected
    case descriptive(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Transport is not connected"
        case .alreadyConnected:
            return "Transport is already connected"
        case .descriptive(let message):
            return message
        }
    }
}
