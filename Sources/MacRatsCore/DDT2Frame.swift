import Foundation
import Compression

/// A DDT2 frame — the unit of data carried by D-Rats over the radio link.
///
/// Faithful Swift port of `DDT2Frame` and `DDT2EncodedFrame` from
/// `d_rats/ddt2.py` in the upstream D-Rats Python codebase. Wire format:
///
/// ```
///  offset  size  field
///  ------  ----  -----
///       0     1  magic        (0xDD = compressed payload, 0x22 = raw)
///       1     2  seq          (big-endian uint16)
///       3     1  session
///       4     1  type
///       5     2  checksum     (big-endian uint16, computed with this field zeroed)
///       7     2  length       (big-endian uint16, payload length only)
///       9     8  s_station    (right-padded with 0x7E '~' if shorter)
///      17     8  d_station    (right-padded with 0x7E '~')
///      25   ...  payload      (zlib-compressed if magic == 0xDD, else raw)
/// ```
///
/// Header total: 25 bytes. The checksum is computed over the entire 25-byte
/// header (with the checksum field set to 0) followed by the payload bytes.
///
/// `DDT2EncodedFrame` wraps the entire packed frame in `[SOB]...[EOB]` after
/// yEncoding, which is what actually goes over the air.
public struct DDT2Frame: Equatable, Sendable {

    // MARK: - Fields

    public var seq: UInt16 = 0
    public var session: UInt8 = 0
    public var type: UInt8 = 0
    public var sStation: String = ""
    public var dStation: String = ""
    public var data: Data = Data()
    public var compress: Bool = true

    // MARK: - Constants

    /// Total fixed-header length in bytes.
    public static let headerLength = 25

    /// Magic byte indicating a zlib-compressed payload.
    public static let magicCompressed: UInt8 = 0xDD

    /// Magic byte indicating a raw (uncompressed) payload.
    public static let magicUncompressed: UInt8 = 0x22

    /// The padding byte used to right-pad station callsigns to 8 bytes.
    public static let stationPad: UInt8 = 0x7E // '~'

    /// SOB envelope marker for `DDT2EncodedFrame`.
    public static let envelopeStart = Data([0x5B, 0x53, 0x4F, 0x42, 0x5D]) // "[SOB]"

    /// EOB envelope marker for `DDT2EncodedFrame`.
    public static let envelopeEnd = Data([0x5B, 0x45, 0x4F, 0x42, 0x5D]) // "[EOB]"

    // MARK: - Init

    public init() {}

    public init(seq: UInt16,
                session: UInt8,
                type: UInt8,
                sStation: String,
                dStation: String,
                data: Data,
                compress: Bool = true) {
        self.seq = seq
        self.session = session
        self.type = type
        self.sStation = sStation
        self.dStation = dStation
        self.data = data
        self.compress = compress
    }

    // MARK: - Errors

    public enum FrameError: Error, LocalizedError {
        case tooShort(Int)
        case unknownMagic(UInt8)
        case checksumMismatch(expected: UInt16, computed: UInt16)
        case decompressionFailed
        case missingEnvelope

        public var errorDescription: String? {
            switch self {
            case .tooShort(let n):
                return "Frame too short: \(n) bytes (need at least \(DDT2Frame.headerLength))"
            case .unknownMagic(let m):
                return String(format: "Unknown DDT2 magic byte 0x%02X", m)
            case .checksumMismatch(let exp, let got):
                return String(format: "DDT2 checksum mismatch: expected 0x%04X, computed 0x%04X", exp, got)
            case .decompressionFailed:
                return "DDT2 zlib decompression failed"
            case .missingEnvelope:
                return "DDT2 encoded frame is missing [SOB]/[EOB] envelope"
            }
        }
    }

    // MARK: - Pack

    /// Serialize this frame to its raw on-link byte form (no [SOB]/[EOB] envelope,
    /// no yEncoding). Use `DDT2EncodedFrame.pack(_:)` for the over-the-air form.
    public func pack() -> Data {
        // 1. Prepare payload (compressed or raw) and the magic byte.
        let payload: Data
        let magic: UInt8
        if compress {
            payload = Self.zlibCompress(data)
            magic = Self.magicCompressed
        } else {
            payload = data
            // Faithful to upstream: when compression is off, the magic byte is
            // the bitwise complement of 0xDD, masked to 8 bits — 0x22.
            magic = (~Self.magicCompressed) & 0xFF
        }

        let length = UInt16(payload.count)
        let sBytes = Self.padStation(sStation)
        let dBytes = Self.padStation(dStation)

        // 2. Build the header with checksum=0, then compute the real checksum
        //    over (header || payload), then rebuild the header with the real
        //    checksum. This matches the upstream Python exactly.
        let zeroHeader = Self.makeHeader(magic: magic,
                                         seq: seq,
                                         session: session,
                                         type: type,
                                         checksum: 0,
                                         length: length,
                                         sStation: sBytes,
                                         dStation: dBytes)

        let checksum = DRatsCRC.calcChecksum(zeroHeader + payload)

        let header = Self.makeHeader(magic: magic,
                                     seq: seq,
                                     session: session,
                                     type: type,
                                     checksum: checksum,
                                     length: length,
                                     sStation: sBytes,
                                     dStation: dBytes)

        return header + payload
    }

    // MARK: - Unpack

    /// Parse a raw DDT2 frame (no envelope, no yEncoding) into a `DDT2Frame`.
    public static func unpack(_ data: Data) throws -> DDT2Frame {
        guard data.count >= headerLength else {
            throw FrameError.tooShort(data.count)
        }

        let bytes = [UInt8](data)

        let magic = bytes[0]
        let compress: Bool
        switch magic {
        case magicCompressed:
            compress = true
        case magicUncompressed:
            compress = false
        default:
            throw FrameError.unknownMagic(magic)
        }

        let seq = (UInt16(bytes[1]) << 8) | UInt16(bytes[2])
        let session = bytes[3]
        let type = bytes[4]
        let checksum = (UInt16(bytes[5]) << 8) | UInt16(bytes[6])
        let length = (UInt16(bytes[7]) << 8) | UInt16(bytes[8])
        let sStationBytes = Array(bytes[9..<17])
        let dStationBytes = Array(bytes[17..<25])
        let payload = Data(bytes[headerLength...])

        // Recompute the checksum over the header with checksum=0 plus the payload.
        let sBytesData = Data(sStationBytes)
        let dBytesData = Data(dStationBytes)
        let zeroHeader = makeHeader(magic: magic,
                                    seq: seq,
                                    session: session,
                                    type: type,
                                    checksum: 0,
                                    length: length,
                                    sStation: sBytesData,
                                    dStation: dBytesData)
        let computed = DRatsCRC.calcChecksum(zeroHeader + payload)
        guard computed == checksum else {
            throw FrameError.checksumMismatch(expected: checksum, computed: computed)
        }

        // Length field is informational — payload bounds come from the buffer.
        // Upstream does not enforce it strictly either, but we capture it for
        // diagnostics if needed in the future.
        _ = length

        // Decode payload.
        let resolvedData: Data
        if compress {
            guard let decoded = Self.zlibDecompress(payload) else {
                throw FrameError.decompressionFailed
            }
            resolvedData = decoded
        } else {
            resolvedData = payload
        }

        // Strip station padding (right-trim '~').
        let sStation = stripStationPadding(sStationBytes)
        let dStation = stripStationPadding(dStationBytes)

        return DDT2Frame(seq: seq,
                         session: session,
                         type: type,
                         sStation: sStation,
                         dStation: dStation,
                         data: resolvedData,
                         compress: compress)
    }

    // MARK: - Helpers

    private static func makeHeader(magic: UInt8,
                                   seq: UInt16,
                                   session: UInt8,
                                   type: UInt8,
                                   checksum: UInt16,
                                   length: UInt16,
                                   sStation: Data,
                                   dStation: Data) -> Data {
        var out = Data()
        out.reserveCapacity(headerLength)
        out.append(magic)
        out.append(UInt8((seq >> 8) & 0xFF))
        out.append(UInt8(seq & 0xFF))
        out.append(session)
        out.append(type)
        out.append(UInt8((checksum >> 8) & 0xFF))
        out.append(UInt8(checksum & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(sStation)
        out.append(dStation)
        return out
    }

    /// Right-pad a callsign to 8 bytes with '~' (0x7E). UTF-8 encoded; if the
    /// callsign is longer than 8 bytes it is truncated, matching upstream's
    /// `ljust(8, "~")` behavior on already-long strings.
    private static func padStation(_ s: String) -> Data {
        var bytes = Data(s.utf8)
        if bytes.count >= 8 {
            return bytes.prefix(8)
        }
        bytes.append(contentsOf: Array(repeating: stationPad, count: 8 - bytes.count))
        return bytes
    }

    private static func stripStationPadding(_ bytes: [UInt8]) -> String {
        // Upstream does .replace(b"~", b"") which removes ALL '~' bytes, not
        // just trailing ones. We mirror that exactly even though it means a
        // legitimate '~' anywhere in the callsign would be lost — D-STAR
        // callsigns never contain '~'.
        let stripped = bytes.filter { $0 != stationPad }
        return String(decoding: stripped, as: UTF8.self)
    }

    // MARK: - zlib

    /// zlib-compress data using the system Compression framework with the
    /// `.zlib` algorithm. Output includes the standard zlib header (0x78 0xDA
    /// for level 9), matching Python's `zlib.compress(data, 9)`.
    static func zlibCompress(_ input: Data) -> Data {
        // Apple's `Compression` framework `.zlib` algorithm produces RAW deflate
        // (no zlib header), not full zlib. We need full zlib output to match the
        // Python reference, so we wrap raw deflate in the zlib header/trailer
        // ourselves.
        //
        // zlib stream = 2-byte header + raw deflate + 4-byte Adler-32 trailer.
        let rawDeflate = rawDeflateCompress(input)

        // zlib header: CMF=0x78 (deflate, 32K window), FLG chosen so the header
        // as a 16-bit big-endian word is divisible by 31. 0x78DA = level 9.
        let header = Data([0x78, 0xDA])

        // Adler-32 over the *uncompressed* input, big-endian.
        let adler = adler32(input)
        let trailer = Data([
            UInt8((adler >> 24) & 0xFF),
            UInt8((adler >> 16) & 0xFF),
            UInt8((adler >> 8) & 0xFF),
            UInt8(adler & 0xFF)
        ])

        return header + rawDeflate + trailer
    }

    /// Decompress a zlib stream. Strips the 2-byte header and 4-byte Adler-32
    /// trailer, then runs raw deflate decompression on the middle.
    static func zlibDecompress(_ input: Data) -> Data? {
        guard input.count >= 6 else { return nil }
        let raw = input.subdata(in: 2..<(input.count - 4))
        return rawDeflateDecompress(raw)
    }

    private static func rawDeflateCompress(_ input: Data) -> Data {
        let bufferSize = max(input.count * 2, 64)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }

        let written = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dst, bufferSize, base, input.count, nil, COMPRESSION_ZLIB)
        }

        return Data(bytes: dst, count: written)
    }

    private static func rawDeflateDecompress(_ input: Data) -> Data? {
        // We don't know the decompressed size in advance. Try a starting buffer
        // sized at 8x input, doubling on overflow up to a sane ceiling.
        var capacity = max(input.count * 8, 1024)
        let ceiling = 16 * 1024 * 1024
        while capacity <= ceiling {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }

            let written = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, capacity, base, input.count, nil, COMPRESSION_ZLIB)
            }
            // compression_decode_buffer returns 0 on error OR when the output
            // exactly fills `capacity` and we can't tell if more was needed.
            // If we got back exactly `capacity` bytes, retry with more.
            if written == 0 {
                return nil
            }
            if written == capacity {
                capacity *= 2
                continue
            }
            return Data(bytes: dst, count: written)
        }
        return nil
    }

    /// Adler-32 checksum used in the zlib trailer.
    private static func adler32(_ input: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let modulus: UInt32 = 65521
        for byte in input {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }
        return (b << 16) | a
    }
}

// MARK: - DDT2EncodedFrame

/// Wraps `DDT2Frame.pack()` output with yEncoding and the `[SOB]/[EOB]` envelope
/// that actually traverses the radio link.
public enum DDT2EncodedFrame {

    /// Pack a frame for over-the-air transmission.
    public static func pack(_ frame: DDT2Frame) -> Data {
        let raw = frame.pack()
        let encoded = YEncode.encode(raw)
        return DDT2Frame.envelopeStart + encoded + DDT2Frame.envelopeEnd
    }

    /// Parse an over-the-air encoded frame back into a `DDT2Frame`.
    ///
    /// Locates the first `[SOB]` and the last `[EOB]` (matching the Python
    /// `index` / `rindex` semantics), yDecodes the payload between them, and
    /// then runs `DDT2Frame.unpack` on the result.
    public static func unpack(_ data: Data) throws -> DDT2Frame {
        guard let sobRange = data.range(of: DDT2Frame.envelopeStart),
              let eobRange = data.range(of: DDT2Frame.envelopeEnd, options: .backwards),
              sobRange.upperBound <= eobRange.lowerBound
        else {
            throw DDT2Frame.FrameError.missingEnvelope
        }

        let payload = data.subdata(in: sobRange.upperBound..<eobRange.lowerBound)
        let decoded = try YEncode.decode(payload)
        return try DDT2Frame.unpack(decoded)
    }
}
