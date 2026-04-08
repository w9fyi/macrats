import Foundation

/// Application-level file transfer session. Sits on top of
/// `StatefulSession` (which provides reliable in-order byte delivery)
/// and implements the D-Rats file transfer wire protocol:
///
/// 1. **Sender writes an offer block**: `<4-byte little-endian size>
///    <UTF-8 filename>`. Size is the length of the compressed file
///    payload in bytes. Filename is the basename only (no directory
///    components), with non-UTF-8 bytes replaced.
/// 2. **Receiver parses the offer** and writes back either:
///    - `"OK"` — start at offset 0 (fresh transfer)
///    - `"RESUME:<offset>"` — the receiver has a partial file and
///      wants the sender to skip ahead (resume is not implemented in
///      MacRats v0.1 but we parse the message and fall back to full
///      transfer if the offset is non-zero).
/// 3. **Sender reads the response** and writes the compressed file
///    bytes as a single stream (StatefulSession chunks them
///    automatically into data blocks).
/// 4. **Receiver reads until the session closes** or a special "end"
///    marker arrives, decompresses with zlib, and writes the resulting
///    file to the download directory.
///
/// Ported from `d_rats/sessions/file.py` — upstream's
/// `FileTransferSession`. The wire format is preserved byte-for-byte
/// for interop with upstream D-Rats stations.
///
/// ## What's different from upstream
///
/// - **Event-driven instead of blocking.** Upstream's `send_file` and
///   `recv_file` are long-running calls that block the caller until
///   the transfer completes. MacRats is SwiftUI and SessionManager
///   callbacks run on the transport queue — we can't block. So this
///   class is a state machine driven by StatefulSession delegate
///   callbacks (`didReceive` advances the state), and progress is
///   reported via a delegate protocol.
///
/// - **Resume is not implemented.** Upstream supports resuming an
///   interrupted transfer via the `RESUME:<offset>` response from
///   the receiver. MacRats currently ignores partial files and
///   always does full transfers — resume can be added later if
///   someone needs it. A `RESUME:` response from a peer is parsed
///   and treated as `OK` (start at 0).
///
/// - **Compression is always zlib, always on.** Upstream has a flag.
///   MacRats file transfers always compress with zlib level 9 before
///   handing to the stateful layer, because file transfer is the one
///   place where the extra compression clearly pays back the CPU on
///   even the slowest link.
///
/// ## Lifecycle
///
/// A FileTransferSession is created fresh for each transfer. It
/// cannot be reused. Sending and receiving are separate code paths:
///
/// ```swift
/// // Sender side — upload a file to peer W9FYI
/// let session = FileTransferSession(remoteStation: "W9FYI", role: .sender)
/// session.delegate = ...
/// manager.add(session, id: 3)
/// try session.sendFile(url: fileURL)
///
/// // Receiver side — wait for incoming file from peer AI5OS
/// let session = FileTransferSession(remoteStation: "AI5OS", role: .receiver)
/// session.delegate = ...
/// manager.add(session, id: 3)
/// session.startReceiving(saveTo: downloadDir)
/// ```
///
/// Both peers must use the same session id — there is no dynamic
/// session negotiation yet (StatefulSession inherits that limitation).
/// The MacRats app picks a fixed id out of band.
public final class FileTransferSession: StatefulSession, StatefulSession.Delegate, @unchecked Sendable {

    // MARK: - Public types

    public enum Role: Sendable {
        case sender
        case receiver
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case awaitingOffer        // receiver: waiting for the sender's offer block
        case awaitingResponse     // sender: waiting for OK / RESUME from receiver
        case transferring         // bytes moving
        case complete(URL)        // transfer finished successfully, URL of written file (receiver) or nil (sender)
        case failed(String)

        public static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):                return true
            case (.awaitingOffer, .awaitingOffer): return true
            case (.awaitingResponse, .awaitingResponse): return true
            case (.transferring, .transferring): return true
            case (.complete(let a), .complete(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    // MARK: - Delegate

    /// App-layer delegate callbacks for progress and completion. All
    /// callbacks may run on the StatefulSession worker queue or the
    /// transport queue — conformers must hop to main if they touch UI.
    public protocol FileTransferDelegate: AnyObject, Sendable {
        /// Fired when the session enters `.transferring` — the offer
        /// has been negotiated and bytes are about to move.
        func fileTransferDidBegin(_ session: FileTransferSession,
                                   filename: String,
                                   totalBytes: Int)

        /// Fired as bytes accumulate. `bytesReceived` is the running
        /// count of raw (pre-decompression) bytes the receiver has
        /// ingested, or the running count of compressed bytes the
        /// sender has handed to the stateful layer. `totalBytes` is
        /// the size advertised in the offer block.
        func fileTransfer(_ session: FileTransferSession,
                           didProgressTo bytesReceived: Int,
                           of totalBytes: Int)

        /// Fired exactly once, when the transfer succeeds. On the
        /// receiver side `fileURL` is the path to the written file;
        /// on the sender side it's the same `URL` that was passed to
        /// `sendFile(url:)` for symmetry.
        func fileTransferDidComplete(_ session: FileTransferSession,
                                      fileURL: URL)

        /// Fired exactly once, when the transfer fails.
        func fileTransfer(_ session: FileTransferSession,
                           didFailWith reason: String)
    }

    public weak var fileDelegate: FileTransferDelegate?

    // MARK: - Configuration

    public let role: Role

    // MARK: - State (protected by `stateLock`)

    private let stateLock = NSLock()
    private var phase: Phase = .idle
    private var sourceURL: URL?
    private var destinationDirectory: URL?
    private var advertisedTotalSize: Int = 0
    private var advertisedFilename: String = ""
    private var bytesAccumulated: Int = 0
    /// Running buffer of bytes received from the stateful layer. For
    /// the receiver this is the compressed file payload; we decompress
    /// it all at once after the transfer completes. Upstream does the
    /// same — it doesn't support streaming decompression.
    private var receiveBuffer = Data()
    /// Set true once we've parsed the offer header out of
    /// `receiveBuffer`. Further inbound bytes are file payload.
    private var offerParsed: Bool = false

    // MARK: - Init

    /// Create a file transfer session for the given peer.
    ///
    /// The underlying StatefulSession is initialized with an
    /// appropriately-sized block size (512 bytes by default, tunable
    /// for slow links). Session type is `fileXfer` so upstream peers
    /// that care about type filtering see us correctly.
    public init(remoteStation: String,
                role: Role,
                blocksize: Int = 512,
                outLimit: Int = 8) {
        self.role = role
        super.init(name: "file-\(role == .sender ? "tx" : "rx")",
                   remoteStation: remoteStation,
                   sessionType: .fileXfer,
                   blocksize: blocksize,
                   outLimit: outLimit)

        // StatefulSession's init already sets `handler` to route
        // inbound frames to its own deliverIncoming(_:). We install
        // ourselves as the StatefulSession.Delegate so we see the
        // decoded byte stream (not raw frames).
        super.delegate = self
    }

    // MARK: - Sender API

    /// Begin sending a file to the remote peer.
    ///
    /// Builds the offer header (size + basename), compresses the file
    /// contents with zlib level 9, and immediately writes the offer
    /// to the stateful layer. The session transitions to
    /// `.awaitingResponse` and will begin transferring once the peer
    /// responds with `OK` (or a `RESUME:` that MacRats falls back to
    /// treat as full-start).
    ///
    /// - Throws: `FileTransferError.fileNotReadable` if the file
    ///   cannot be read; `FileTransferError.wrongRole` if this
    ///   session was constructed with `.receiver`.
    public func sendFile(url: URL) throws {
        guard role == .sender else {
            throw FileTransferError.wrongRole("sendFile requires role = .sender")
        }

        let rawData: Data
        do {
            rawData = try Data(contentsOf: url)
        } catch {
            throw FileTransferError.fileNotReadable(url.path, error.localizedDescription)
        }

        // Compress with zlib level 9. Matches upstream's
        // `zlib.compress(data, 9)` in `get_file_data`.
        let compressed = try Self.zlibCompress(rawData, level: 9)
        let basename = url.lastPathComponent
        let nameBytes = basename.data(using: .utf8) ?? Data()

        // Offer header: 4-byte little-endian size + filename.
        // The comment in upstream explains: "little endian to be
        // compatible with most existing d-rats deployment as that is
        // the native endian for x86."
        var offer = Data(count: 4)
        let size = UInt32(compressed.count)
        offer[0] = UInt8(size        & 0xFF)
        offer[1] = UInt8((size >> 8)  & 0xFF)
        offer[2] = UInt8((size >> 16) & 0xFF)
        offer[3] = UInt8((size >> 24) & 0xFF)
        offer.append(nameBytes)

        stateLock.lock()
        phase = .awaitingResponse
        sourceURL = url
        advertisedTotalSize = compressed.count
        advertisedFilename = basename
        // Stash the compressed payload on sourceURL by caching it in
        // the `pendingSendData` field so we can write it after we get
        // the OK. Avoid holding it twice.
        pendingSendData = compressed
        stateLock.unlock()

        // Send the offer. StatefulSession.send signals the worker
        // immediately; the bytes will actually hit the wire on the
        // worker's next iteration.
        send(offer)
    }

    /// Buffer of compressed file bytes that we'll write after the
    /// peer acknowledges the offer. Kept separate from receiveBuffer
    /// so the two roles don't accidentally share state.
    private var pendingSendData: Data = Data()

    // MARK: - Receiver API

    /// Begin waiting for an incoming file. The session transitions to
    /// `.awaitingOffer` and the worker idles until the peer's offer
    /// block arrives. `saveTo` must be a directory; the received
    /// file is written at `saveTo.appendingPathComponent(filename)`.
    ///
    /// - Throws: `FileTransferError.wrongRole` if this session was
    ///   constructed with `.sender`.
    public func startReceiving(saveTo directory: URL) throws {
        guard role == .receiver else {
            throw FileTransferError.wrongRole("startReceiving requires role = .receiver")
        }
        stateLock.lock()
        phase = .awaitingOffer
        destinationDirectory = directory
        stateLock.unlock()
    }

    // MARK: - Inbound byte delivery (from StatefulSession.Delegate)

    public func statefulSession(_ session: StatefulSession, didReceive data: Data) {
        stateLock.lock()
        receiveBuffer.append(data)
        let phaseNow = phase
        let roleNow = role
        stateLock.unlock()

        switch (roleNow, phaseNow) {
        case (.receiver, .awaitingOffer):
            tryParseOfferAndRespond()
        case (.receiver, .transferring):
            trackReceiverProgress()
        case (.sender, .awaitingResponse):
            tryParseSenderResponse()
        default:
            // Extra bytes after completion or in an unexpected phase
            // — log and ignore. A well-behaved peer should not send
            // anything at this point.
            manager?.log("FileTransferSession: unexpected inbound bytes in phase \(phaseNow)")
        }
    }

    public func statefulSessionDidClose(_ session: StatefulSession) {
        // Session closed normally. On the receiver side, a close with
        // a complete file still in the buffer is how upstream signals
        // "transfer done" — there's no explicit EOF marker.
        stateLock.lock()
        let roleNow = role
        let phaseNow = phase
        stateLock.unlock()

        switch (roleNow, phaseNow) {
        case (.receiver, .transferring):
            finishReceive()
        case (.sender, .transferring):
            finishSend()
        default:
            // Already completed or failed — nothing more to do.
            break
        }
    }

    public func statefulSession(_ session: StatefulSession, didFailWithReason reason: String) {
        transitionToFailed(reason)
    }

    // MARK: - Receiver state transitions

    /// Called while in `.awaitingOffer`. The receive buffer now holds
    /// at least some bytes. Parse the 4-byte LE size + filename, then
    /// respond with `OK` and transition to `.transferring`.
    private func tryParseOfferAndRespond() {
        stateLock.lock()

        // Need at least 4 bytes for the size field, plus one byte for
        // the filename. Wait if we don't have them yet.
        guard receiveBuffer.count >= 5 else {
            stateLock.unlock()
            return
        }

        let size = UInt32(receiveBuffer[0])
                 | (UInt32(receiveBuffer[1]) << 8)
                 | (UInt32(receiveBuffer[2]) << 16)
                 | (UInt32(receiveBuffer[3]) << 24)
        let nameBytes = receiveBuffer.subdata(in: 4..<receiveBuffer.count)
        let name = String(data: nameBytes, encoding: .utf8) ?? "unknown"

        // Consume the offer; anything past the header is unexpected
        // (the peer should wait for our OK before streaming data).
        // Upstream doesn't explicitly defend against this either.
        receiveBuffer = Data()
        offerParsed = true
        advertisedTotalSize = Int(size)
        advertisedFilename = name
        phase = .transferring
        stateLock.unlock()

        // Fire the "begin" delegate event before we answer the peer
        // so the UI can show progress immediately.
        fileDelegate?.fileTransferDidBegin(self,
                                            filename: name,
                                            totalBytes: Int(size))

        // Respond with "OK" to start the transfer.
        send(Data("OK".utf8))
    }

    private func trackReceiverProgress() {
        stateLock.lock()
        let progress = receiveBuffer.count
        let total = advertisedTotalSize
        let allArrived = (progress >= total)
        stateLock.unlock()
        fileDelegate?.fileTransfer(self, didProgressTo: progress, of: total)

        // We know the full size up front (from the offer), so the
        // receiver can finish as soon as the advertised byte count
        // has accumulated — no need to wait for the sender to
        // explicitly close the session. That removes a whole class
        // of "sender closed cleanly but our close event never fired
        // because the stateful layer was mid-retry" problems.
        if allArrived {
            finishReceive()
        }
    }

    /// Called when the session closes while we're in `.transferring`.
    /// Decompress the accumulated buffer and write the file to disk.
    private func finishReceive() {
        stateLock.lock()
        let compressed = receiveBuffer
        let name = advertisedFilename
        let dir = destinationDirectory
        stateLock.unlock()

        guard let dir else {
            transitionToFailed("no destination directory set")
            return
        }

        let decompressed: Data
        do {
            decompressed = try Self.zlibDecompress(compressed)
        } catch {
            transitionToFailed("decompression failed: \(error.localizedDescription)")
            return
        }

        let outURL = dir.appendingPathComponent(name)
        do {
            try decompressed.write(to: outURL)
        } catch {
            transitionToFailed("write failed: \(error.localizedDescription)")
            return
        }

        stateLock.lock()
        phase = .complete(outURL)
        stateLock.unlock()

        fileDelegate?.fileTransferDidComplete(self, fileURL: outURL)
    }

    // MARK: - Sender state transitions

    /// Called while in `.awaitingResponse`. The receive buffer now
    /// holds `OK` or `RESUME:<offset>`. Parse it and start streaming.
    private func tryParseSenderResponse() {
        stateLock.lock()
        let buf = receiveBuffer
        stateLock.unlock()

        // Minimum response is 2 bytes ("OK").
        guard buf.count >= 2 else { return }

        let text = String(data: buf, encoding: .utf8) ?? ""

        var startOffset = 0
        if text == "OK" {
            startOffset = 0
        } else if text.hasPrefix("RESUME:") {
            let offsetStr = text.dropFirst("RESUME:".count)
            startOffset = Int(offsetStr) ?? 0
            // v0.1 does not implement resume — fall back to full
            // transfer. Honoring RESUME would need us to seek into
            // pendingSendData, which is trivial, but also requires
            // the receiver to decompress a split stream, which
            // upstream's zlib layer can't do. Leave resume off until
            // we have a real need.
            startOffset = 0
        } else {
            // Unknown response — treat it as "not yet" and wait for
            // more bytes. If the peer sent garbage, the stateful
            // layer's retry budget will eventually close the session.
            manager?.log("FileTransferSession: unknown offer response: \(text)")
            return
        }

        // Consume the response and move to transferring.
        stateLock.lock()
        receiveBuffer = Data()
        phase = .transferring
        let compressed = pendingSendData
        let name = advertisedFilename
        let total = advertisedTotalSize
        stateLock.unlock()

        fileDelegate?.fileTransferDidBegin(self,
                                            filename: name,
                                            totalBytes: total)

        // Apply the start offset (currently always 0) and stream the
        // compressed payload through the stateful layer.
        let payload = compressed.dropFirst(startOffset)
        send(Data(payload))

        // We don't know for sure when the peer has consumed all
        // bytes. Upstream closes the session immediately after the
        // write and counts on the ACK/REQACK retry logic to drain
        // any in-flight blocks. We do the same — call close(), let
        // the worker drain outstanding, and fire
        // `fileTransferDidComplete` from `statefulSessionDidClose`.
        close()
    }

    private func finishSend() {
        stateLock.lock()
        let url = sourceURL
        stateLock.unlock()
        guard let url else { return }

        stateLock.lock()
        phase = .complete(url)
        stateLock.unlock()

        fileDelegate?.fileTransferDidComplete(self, fileURL: url)
    }

    // MARK: - Failure

    private func transitionToFailed(_ reason: String) {
        stateLock.lock()
        if case .failed = phase {
            stateLock.unlock()
            return
        }
        if case .complete = phase {
            stateLock.unlock()
            return
        }
        phase = .failed(reason)
        stateLock.unlock()
        fileDelegate?.fileTransfer(self, didFailWith: reason)
    }

    // MARK: - zlib helpers

    /// Wraps `zlib.compress(data, 9)` from Python. Uses Foundation's
    /// built-in `compressed(using: .zlib)` via the low-level `libz`
    /// API that ships with the SDK. The raw-zlib frame produced here
    /// matches exactly what Python's `zlib.compress` emits, so MacRats
    /// output decompresses cleanly inside upstream D-Rats.
    static func zlibCompress(_ data: Data, level: Int32 = 9) throws -> Data {
        var result = Data()
        var stream = z_stream_swift()
        // Initial buffer size: worst case plus zlib header overhead.
        let bound = data.count + (data.count >> 12) + (data.count >> 14) + (data.count >> 25) + 13

        let status = data.withUnsafeBytes { (inBuffer: UnsafeRawBufferPointer) -> Int32 in
            var out = [UInt8](repeating: 0, count: bound + 16)
            return out.withUnsafeMutableBufferPointer { outBufferPtr -> Int32 in
                guard let inBase = inBuffer.baseAddress,
                      let outBase = outBufferPtr.baseAddress else {
                    return -1
                }
                stream.next_in = UnsafeMutablePointer(mutating: inBase.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = UInt32(data.count)
                stream.next_out = outBase
                stream.avail_out = UInt32(outBufferPtr.count)

                var ret = deflateInit_swift(&stream, level)
                if ret != Z_OK_swift { return ret }
                ret = deflate_swift(&stream, Z_FINISH_swift)
                if ret != Z_STREAM_END_swift {
                    _ = deflateEnd_swift(&stream)
                    return ret
                }
                let produced = outBufferPtr.count - Int(stream.avail_out)
                result.append(outBase, count: produced)
                return deflateEnd_swift(&stream)
            }
        }
        guard status == Z_OK_swift else {
            throw FileTransferError.zlibFailed("compress returned \(status)")
        }
        return result
    }

    /// Decompress a zlib-wrapped blob, matching Python's `zlib.decompress`.
    static func zlibDecompress(_ data: Data) throws -> Data {
        var result = Data()
        var stream = z_stream_swift()

        let status = data.withUnsafeBytes { (inBuffer: UnsafeRawBufferPointer) -> Int32 in
            // Start with a 4x guess and grow if needed.
            var bufSize = Swift.max(data.count * 4, 1024)
            var out = [UInt8](repeating: 0, count: bufSize)
            guard let inBase = inBuffer.baseAddress else { return -1 }
            stream.next_in = UnsafeMutablePointer(mutating: inBase.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = UInt32(data.count)

            var ret = inflateInit_swift(&stream)
            if ret != Z_OK_swift { return ret }

            while true {
                let ok = out.withUnsafeMutableBufferPointer { outBufferPtr -> Int32 in
                    guard let outBase = outBufferPtr.baseAddress else { return -1 }
                    stream.next_out = outBase
                    stream.avail_out = UInt32(outBufferPtr.count)
                    let step = inflate_swift(&stream, Z_NO_FLUSH_swift)
                    let produced = outBufferPtr.count - Int(stream.avail_out)
                    result.append(outBase, count: produced)
                    return step
                }
                if ok == Z_STREAM_END_swift {
                    _ = inflateEnd_swift(&stream)
                    return Z_OK_swift
                }
                if ok != Z_OK_swift {
                    _ = inflateEnd_swift(&stream)
                    return ok
                }
                // Out of room — double the buffer and continue.
                bufSize *= 2
                out = [UInt8](repeating: 0, count: bufSize)
            }
        }
        guard status == Z_OK_swift else {
            throw FileTransferError.zlibFailed("decompress returned \(status)")
        }
        return result
    }

    // MARK: - Phase snapshot

    /// Thread-safe read of the current phase. Useful for tests and UI
    /// that want to poll.
    public var currentPhase: Phase {
        stateLock.lock(); defer { stateLock.unlock() }
        return phase
    }
}

// MARK: - Errors

public enum FileTransferError: Error, LocalizedError, Equatable {
    case wrongRole(String)
    case fileNotReadable(String, String)
    case zlibFailed(String)

    public var errorDescription: String? {
        switch self {
        case .wrongRole(let msg):
            return "File transfer: \(msg)"
        case .fileNotReadable(let path, let reason):
            return "Could not read file \(path): \(reason)"
        case .zlibFailed(let msg):
            return "Zlib operation failed: \(msg)"
        }
    }
}

// MARK: - Minimal zlib shim
//
// Swift has no first-class zlib API on macOS (there's Compression.framework
// but its raw-zlib wrapper produces a subtly different frame that upstream
// D-Rats's `zlib.decompress` rejects). We call libz directly instead.
//
// Dynamically linking libz avoids the need for a C shim target. The symbol
// names use `_swift` suffixes to avoid colliding with any other zlib
// bindings pulled in by dependencies.

@_silgen_name("deflateInit_") private func deflateInit_swift_raw(_ strm: OpaquePointer, _ level: Int32, _ version: UnsafePointer<Int8>, _ stream_size: Int32) -> Int32
@_silgen_name("deflate") private func deflate_swift_raw(_ strm: OpaquePointer, _ flush: Int32) -> Int32
@_silgen_name("deflateEnd") private func deflateEnd_swift_raw(_ strm: OpaquePointer) -> Int32
@_silgen_name("inflateInit_") private func inflateInit_swift_raw(_ strm: OpaquePointer, _ version: UnsafePointer<Int8>, _ stream_size: Int32) -> Int32
@_silgen_name("inflate") private func inflate_swift_raw(_ strm: OpaquePointer, _ flush: Int32) -> Int32
@_silgen_name("inflateEnd") private func inflateEnd_swift_raw(_ strm: OpaquePointer) -> Int32

// The z_stream struct layout. Matches libz's definition on macOS and
// Linux (both use 64-bit pointers and 32-bit ints/counts).
fileprivate struct z_stream_swift {
    var next_in: UnsafeMutablePointer<UInt8>? = nil
    var avail_in: UInt32 = 0
    var total_in: UInt = 0

    var next_out: UnsafeMutablePointer<UInt8>? = nil
    var avail_out: UInt32 = 0
    var total_out: UInt = 0

    var msg: UnsafePointer<Int8>? = nil
    var state: OpaquePointer? = nil

    var zalloc: OpaquePointer? = nil
    var zfree: OpaquePointer? = nil
    var opaque: OpaquePointer? = nil

    var data_type: Int32 = 0
    var adler: UInt = 0
    var reserved: UInt = 0
}

fileprivate let Z_OK_swift: Int32 = 0
fileprivate let Z_STREAM_END_swift: Int32 = 1
fileprivate let Z_NO_FLUSH_swift: Int32 = 0
fileprivate let Z_FINISH_swift: Int32 = 4
fileprivate let ZLIB_VERSION_swift = "1.2.11"

fileprivate func deflateInit_swift(_ strm: inout z_stream_swift, _ level: Int32) -> Int32 {
    return withUnsafeMutablePointer(to: &strm) { ptr in
        ZLIB_VERSION_swift.withCString { version in
            deflateInit_swift_raw(OpaquePointer(ptr), level, version,
                                    Int32(MemoryLayout<z_stream_swift>.size))
        }
    }
}

fileprivate func deflate_swift(_ strm: inout z_stream_swift, _ flush: Int32) -> Int32 {
    return withUnsafeMutablePointer(to: &strm) { ptr in
        deflate_swift_raw(OpaquePointer(ptr), flush)
    }
}

fileprivate func deflateEnd_swift(_ strm: inout z_stream_swift) -> Int32 {
    return withUnsafeMutablePointer(to: &strm) { ptr in
        deflateEnd_swift_raw(OpaquePointer(ptr))
    }
}

fileprivate func inflateInit_swift(_ strm: inout z_stream_swift) -> Int32 {
    return withUnsafeMutablePointer(to: &strm) { ptr in
        ZLIB_VERSION_swift.withCString { version in
            inflateInit_swift_raw(OpaquePointer(ptr), version,
                                    Int32(MemoryLayout<z_stream_swift>.size))
        }
    }
}

fileprivate func inflate_swift(_ strm: inout z_stream_swift, _ flush: Int32) -> Int32 {
    return withUnsafeMutablePointer(to: &strm) { ptr in
        inflate_swift_raw(OpaquePointer(ptr), flush)
    }
}

fileprivate func inflateEnd_swift(_ strm: inout z_stream_swift) -> Int32 {
    return withUnsafeMutablePointer(to: &strm) { ptr in
        inflateEnd_swift_raw(OpaquePointer(ptr))
    }
}
