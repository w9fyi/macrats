import Foundation

/// CRC-16 used by D-Rats DDT2 frames.
///
/// Bitwise CRC-16 with polynomial 0x1021, initial value 0, no XOR-out, augmented
/// with two trailing zero bytes (the "augment" pattern from the original Dan Smith
/// implementation in `d_rats/crc_checksum.py`). Result is masked to 16 bits.
///
/// This is intentionally a faithful direct port — the goal is byte-for-byte
/// compatibility with the upstream Python reference, not algorithmic elegance.
public enum DRatsCRC {

    /// Update one byte into a running CRC.
    @inline(__always)
    static func updateCRC(_ inputByte: UInt8, _ inCRC: UInt32) -> UInt32 {
        // The Python reference shifts the input byte left bit by bit and feeds
        // the bit that falls out of position 0o400 (octal 0400 = 0x100) into the
        // CRC. We mirror that exactly.
        var byte = UInt32(inputByte)
        var crc = inCRC
        for _ in 0..<8 {
            byte <<= 1
            let value: UInt32 = (byte & 0x100) != 0 ? 1 : 0
            if (crc & 0x8000) != 0 {
                crc = ((crc << 1) &+ value) ^ 0x1021
            } else {
                crc = (crc << 1) &+ value
            }
        }
        return crc & 0xFFFF
    }

    /// Calculate the DDT2 CRC over a byte sequence.
    public static func calcChecksum(_ data: Data) -> UInt16 {
        var crc: UInt32 = 0
        for byte in data {
            crc = updateCRC(byte, crc)
        }
        // Augment with two zero bytes — matches the Python reference exactly.
        crc = updateCRC(0, crc)
        crc = updateCRC(0, crc)
        return UInt16(crc & 0xFFFF)
    }

    /// Convenience for byte arrays.
    public static func calcChecksum(_ bytes: [UInt8]) -> UInt16 {
        calcChecksum(Data(bytes))
    }
}
