import Foundation

/// yEncode encoder/decoder used by D-Rats DDT2 to escape bytes that would
/// otherwise interfere with the radio link layer (XON/XOFF, KISS frame markers,
/// nulls, ICOM mode bytes, packet-loss notification bytes, etc.).
///
/// This is a faithful port of `d_rats/yencode.py` in the upstream D-Rats Python
/// codebase. The wire format is:
///
///   - For any byte in the banned set, emit `=` followed by `(byte + 64) mod 256`.
///   - For all other bytes, emit them unchanged.
///
/// `=` itself is always banned so the escape sequence is unambiguous.
public enum YEncode {

    /// Default banned bytes — bytes that must be escaped on radio links.
    /// From `d_rats/yencode.py` `DEFAULT_BANNED`.
    public static let defaultBanned: Set<UInt8> = [
        0x11, // XON
        0x13, // XOFF
        0x1A, // EOF
        0x00, // NULL
        0x84, // packet loss notification
        0xE7, // packet loss notification
        0xFD, // ICOM mode switch
        0xFE, // unknown
        0xFF, // unknown
        0xC0, // KISS FEND
        0xDB, // KISS FESC
        0x3D, // '=' — always escaped (yEncode escape character)
    ]

    private static let offset: UInt8 = 64
    private static let escapeByte: UInt8 = 0x3D // '='

    /// Encode a buffer with the default banned set.
    public static func encode(_ data: Data) -> Data {
        encode(data, banned: defaultBanned)
    }

    /// Encode a buffer with a custom banned set. `=` (0x3D) is always banned and
    /// will be added to `banned` if not already present.
    public static func encode(_ data: Data, banned: Set<UInt8>) -> Data {
        var bannedSet = banned
        bannedSet.insert(escapeByte)

        var out = Data()
        out.reserveCapacity(data.count)

        for byte in data {
            if bannedSet.contains(byte) {
                out.append(escapeByte)
                // (byte + 64) mod 256 — Swift's overflow operator gives us
                // exactly this without explicit masking.
                out.append(byte &+ offset)
            } else {
                out.append(byte)
            }
        }

        return out
    }

    /// Decoding errors.
    public enum DecodeError: Error, LocalizedError {
        case truncatedEscape

        public var errorDescription: String? {
            switch self {
            case .truncatedEscape:
                return "yEncode buffer ended in mid-escape sequence"
            }
        }
    }

    /// Decode a buffer.
    ///
    /// Mirrors `ydecode_buffer` from upstream. The Python implementation does
    /// not raise on a trailing dangling `=` — it would index past the end. We
    /// raise `DecodeError.truncatedEscape` instead, which is what we want for
    /// safety in a Swift port.
    public static func decode(_ data: Data) throws -> Data {
        var out = Data()
        out.reserveCapacity(data.count)

        var i = data.startIndex
        let end = data.endIndex
        while i < end {
            let byte = data[i]
            if byte == escapeByte {
                i = data.index(after: i)
                guard i < end else {
                    throw DecodeError.truncatedEscape
                }
                // The Python reference does:
                //     val = buf[i] - OFFSET
                //     if val < 0: val += 256
                // which is identical to subtracting 64 in modular UInt8
                // arithmetic — Swift's `&-` does exactly that.
                out.append(data[i] &- offset)
            } else {
                out.append(byte)
            }
            i = data.index(after: i)
        }

        return out
    }
}
