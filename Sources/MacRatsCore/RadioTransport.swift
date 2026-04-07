import Foundation

/// Connection status of a `RadioTransport`.
public enum TransportStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// Abstraction over the byte pipe to a D-STAR radio.
///
/// `RadioTransport` is intentionally bidirectional, byte-oriented, and totally
/// agnostic to the protocol layers above it. The DDT2 framer/deframer is the
/// only thing that needs to know about `[SOB]` / `[EOB]` envelopes; everything
/// below this protocol just shovels bytes.
///
/// Conformances:
/// - `TCPLoopbackTransport` — for testing without a radio (or for talking to
///   another MacRats instance on the same Mac).
/// - `USBSerialTransport` — for the TH-D75 and other USB-CDC radios. Added in
///   a follow-up commit; the protocol shape is here from day one so the rest
///   of the code can be written against it.
/// - Future: `BluetoothSPPTransport` for v1.1, `KISSTNCTransport` if we ever
///   want to talk to a separate hardware TNC.
///
/// Implementations are expected to be safe to use from any actor or thread.
/// Conformances should serialize their own internal state. Callers receive
/// status changes and inbound bytes via the `delegate` callback set on the
/// transport — the protocol intentionally does not use `AsyncStream` here
/// because the SwiftUI app layer wants synchronous status updates and we want
/// transports to be usable from XCTest as well as from the running app.
public protocol RadioTransport: AnyObject, Sendable {

    /// Human-readable name for logging and the UI ("USB serial: cu.usbmodem14201",
    /// "TCP loopback: 127.0.0.1:9876", etc.).
    var displayName: String { get }

    /// Current connection status. Implementations must update this atomically.
    var status: TransportStatus { get }

    /// Open the underlying connection. Returns immediately; status updates and
    /// inbound bytes arrive via the delegate.
    func connect() throws

    /// Close the underlying connection. Idempotent.
    func disconnect()

    /// Send raw bytes (already DDT2-framed and SOB/EOB-wrapped). Returns the
    /// number of bytes the transport accepted; partial sends are an error in
    /// the transport, not the caller's problem.
    func send(_ data: Data) throws

    /// Set the delegate that receives inbound bytes and status changes.
    /// Calling this with `nil` detaches the delegate.
    func setDelegate(_ delegate: RadioTransportDelegate?)
}

/// Delegate callbacks from a `RadioTransport`. All methods may be called from
/// arbitrary threads — implementations must hop to the main actor themselves
/// if they need to update SwiftUI state.
public protocol RadioTransportDelegate: AnyObject, Sendable {
    func transport(_ transport: RadioTransport, didReceive data: Data)
    func transport(_ transport: RadioTransport, didChangeStatus status: TransportStatus)
    func transport(_ transport: RadioTransport, didEncounterError error: Error)
}

// MARK: - Frame splitter

/// Stateful splitter that turns a stream of arbitrary inbound bytes into a
/// sequence of complete SOB/EOB frames. The radio link does not preserve
/// frame boundaries — bytes can arrive in any chunking — so we buffer until
/// we see a complete `[SOB]...[EOB]` and then emit it.
///
/// This is the bridge between `RadioTransport` (raw bytes) and
/// `DDT2EncodedFrame.unpack(_:)` (complete envelope).
public final class DDT2FrameSplitter: @unchecked Sendable {

    private var buffer = Data()
    private let lock = NSLock()

    /// Maximum buffer size before we drop and resync. Protects against a
    /// malformed transmitter sending an unbounded stream with no envelope.
    public let maxBufferSize: Int

    public init(maxBufferSize: Int = 1024 * 1024) {
        self.maxBufferSize = maxBufferSize
    }

    /// Feed inbound bytes to the splitter. Returns any complete frames that
    /// became available as a result of this feed. Does NOT call into the DDT2
    /// unpacker — that's the caller's job.
    public func feed(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)

        if buffer.count > maxBufferSize {
            // Drop the oldest half — keeps us alive on hostile inputs without
            // throwing away frames currently in flight.
            buffer.removeSubrange(0..<(buffer.count / 2))
        }

        var frames: [Data] = []
        while let frame = extractOne() {
            frames.append(frame)
        }
        return frames
    }

    /// Reset the buffer (e.g. after a reconnect).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }

    private func extractOne() -> Data? {
        guard let sob = buffer.range(of: DDT2Frame.envelopeStart) else {
            // No SOB at all — anything before would never become a frame, so
            // drop everything except the last 4 bytes (might be the start of
            // an SOB about to arrive).
            if buffer.count > 4 {
                buffer.removeSubrange(0..<(buffer.count - 4))
            }
            return nil
        }
        // Drop anything before the SOB — it's noise.
        if sob.lowerBound > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<sob.lowerBound)
        }
        // Re-locate SOB now that we've shifted (it's at offset 0).
        // Look for an EOB after the SOB.
        let searchStart = buffer.index(buffer.startIndex, offsetBy: DDT2Frame.envelopeStart.count)
        guard searchStart <= buffer.endIndex,
              let eob = buffer.range(of: DDT2Frame.envelopeEnd,
                                     options: [],
                                     in: searchStart..<buffer.endIndex)
        else {
            // SOB present but no EOB yet — wait for more bytes.
            return nil
        }

        let frameEnd = eob.upperBound
        let frame = buffer.subdata(in: buffer.startIndex..<frameEnd)
        buffer.removeSubrange(buffer.startIndex..<frameEnd)
        return frame
    }
}
