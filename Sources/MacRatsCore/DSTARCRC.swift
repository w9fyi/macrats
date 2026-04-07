import Foundation

/// D-STAR CRC-CCITT used in D-STAR header checksums (and by extension in
/// every MMDVM `dstarHeader` frame MacRats sends or receives).
///
/// Polynomial: 0x8408 (reflected 0x1021), initial value 0xFFFF, final XOR
/// by inverting all bits. This is the standard CRC used by D-STAR headers
/// and the ICom DExtra / DCS reflector protocols.
///
/// Ported verbatim from the sibling `th-programmer` project's
/// `Reflector/DVFrame.swift` (function `dstarCRC(data:from:count:)` and
/// its lookup table generator).
///
/// Distinct from `DRatsCRC` — the two algorithms operate on totally
/// different parts of the stack:
///
/// - `DRatsCRC`  — DDT2 payload checksum (bitwise, augmented, polynomial
///                 0x1021 non-reflected). Used inside the DDT2 frame.
/// - `DSTARCRC`  — D-STAR header checksum (table-driven, reflected 0x8408,
///                 final XOR). Used at the bottom of a D-STAR header frame
///                 that carries DDT2 bytes in its slow-data channel.
public enum DSTARCRC {

    /// CRC-CCITT lookup table (polynomial 0x8408, reflected).
    /// Computed once at type-load time.
    private static let ccittTable: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt16(i)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0x8408
                } else {
                    crc >>= 1
                }
            }
            table[i] = crc
        }
        return table
    }()

    /// Compute the D-STAR CRC-CCITT over `count` bytes starting at `start`
    /// within `data`. The result is the post-inversion value that gets
    /// written into bytes 39–40 of a D-STAR header (little-endian).
    public static func compute(_ data: Data, from start: Int, count: Int) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for i in start..<(start + count) {
            let byte = data[data.startIndex + i]
            crc = (crc >> 8) ^ ccittTable[Int((crc & 0x00FF) ^ UInt16(byte))]
        }
        return ~crc
    }

    /// Convenience for arrays.
    public static func compute(_ bytes: [UInt8]) -> UInt16 {
        compute(Data(bytes), from: 0, count: bytes.count)
    }
}
