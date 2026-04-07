import Foundation

/// Stateful parser that accumulates inbound serial bytes from the MMDVM modem
/// (TH-D75 in terminal mode) and emits complete parsed frames.
///
/// Handles partial frames split across serial reads: bytes from the dispatch
/// source are buffered until a complete `[0xE0][length][command][payload...]`
/// frame is available, then the frame is removed from the buffer and emitted.
/// Multiple frames in a single `feed()` call are all extracted.
///
/// Junk bytes before a `0xE0` marker are discarded silently — this makes the
/// parser robust against modem preamble, line noise, and mid-session resyncs.
///
/// Ported from the sibling `th-programmer` project's
/// `Sources/TH-Programmer/MMDVM/MMDVMParser.swift`.
public final class MMDVMParser: @unchecked Sendable {

    // MARK: - Output

    /// A single parsed MMDVM frame.
    public enum ParsedFrame: Equatable, Sendable {

        /// D-STAR header frame (41-byte payload: 3 flags + 4×8 callsigns +
        /// 4 suffix + 2 CRC).
        case dstarHeader(Data)

        /// D-STAR voice frame (12-byte payload: 9 AMBE + 3 slow data).
        ///
        /// For MacRats: extract `payload[9..<12]` to get the 3 slow-data
        /// bytes carrying DDT2 stream data, then feed them into
        /// `DDT2FrameSplitter` to reassemble complete `[SOB]...[EOB]`
        /// envelopes.
        case dstarVoice(Data)

        /// D-STAR frame-lost indicator.
        case dstarLost

        /// D-STAR end-of-transmission marker.
        case dstarEOT

        /// Firmware version response (ASCII string stripped of control bytes).
        case version(String)

        /// Modem status response (raw payload).
        case status(Data)

        /// Positive acknowledgement for the last command.
        case ack

        /// Negative acknowledgement with the reason byte from the payload.
        case nak(UInt8)

        /// Unknown command — carries the raw command byte and payload for
        /// diagnostic logging.
        case unknown(UInt8, Data)
    }

    // MARK: - State

    private var buffer = Data()
    private let lock = NSLock()

    /// Maximum buffer size before we drop and resync. Protects against a
    /// misbehaving modem sending an unbounded stream with no marker.
    public let maxBufferSize: Int

    public init(maxBufferSize: Int = 1024 * 1024) {
        self.maxBufferSize = maxBufferSize
    }

    // MARK: - Public API

    /// Feed inbound serial bytes to the parser. Returns zero or more complete
    /// parsed frames that became available as a result of this call.
    public func feed(_ data: Data) -> [ParsedFrame] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)

        if buffer.count > maxBufferSize {
            // Drop the oldest half — keeps us alive on hostile inputs
            // without throwing away any frame currently in flight.
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + buffer.count / 2))
        }

        var results: [ParsedFrame] = []
        while buffer.count >= MMDVMProtocol.minFrameSize {
            // Find the 0xE0 marker.
            guard let markerIndex = buffer.firstIndex(of: MMDVMProtocol.frameMarker) else {
                // No marker at all — entire buffer is noise.
                buffer.removeAll(keepingCapacity: true)
                break
            }

            // Discard any bytes before the marker.
            if markerIndex > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<markerIndex)
            }

            guard buffer.count >= MMDVMProtocol.minFrameSize else { break }

            let length = Int(buffer[buffer.startIndex + 1])

            // Sanity check: length must be at least 3.
            guard length >= MMDVMProtocol.minFrameSize else {
                // Invalid length — discard this marker and look for the next.
                buffer.removeFirst(1)
                continue
            }

            // Wait for the full frame to arrive.
            guard buffer.count >= length else { break }

            let frameData = Data(buffer.prefix(length))
            buffer.removeFirst(length)

            let command = frameData[frameData.startIndex + 2]
            let payload = frameData.count > 3 ? Data(frameData[(frameData.startIndex + 3)...]) : Data()
            results.append(classify(command: command, payload: payload))
        }

        return results
    }

    /// Reset the parser state, discarding any buffered data.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Helpers for DDT2 integration

    /// Convenience: extract the 3 slow-data bytes from a `.dstarVoice` payload.
    /// Returns an empty Data if the payload is malformed.
    public static func slowData(from dstarVoicePayload: Data) -> Data {
        guard dstarVoicePayload.count >= 12 else { return Data() }
        let start = dstarVoicePayload.startIndex + 9
        let end = dstarVoicePayload.startIndex + 12
        return Data(dstarVoicePayload[start..<end])
    }

    // MARK: - Classification

    private func classify(command: UInt8, payload: Data) -> ParsedFrame {
        switch command {
        case MMDVMProtocol.dstarHeader:
            return .dstarHeader(payload)

        case MMDVMProtocol.dstarData:
            return .dstarVoice(payload)

        case MMDVMProtocol.dstarLost:
            return .dstarLost

        case MMDVMProtocol.dstarEOT:
            return .dstarEOT

        case MMDVMProtocol.getVersion:
            // Version response: payload is firmware version string.
            let versionString: String
            if payload.isEmpty {
                versionString = "unknown"
            } else {
                versionString = String(data: payload, encoding: .ascii)?
                    .trimmingCharacters(in: .controlCharacters) ?? "unknown"
            }
            return .version(versionString)

        case MMDVMProtocol.getStatus:
            return .status(payload)

        case MMDVMProtocol.ack:
            return .ack

        case MMDVMProtocol.nak:
            let reason = payload.first ?? 0x00
            return .nak(reason)

        default:
            return .unknown(command, payload)
        }
    }
}
