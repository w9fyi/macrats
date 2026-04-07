import Foundation

/// MMDVM (Multi-Mode Digital Voice Modem) host ↔ modem serial protocol.
///
/// The Kenwood TH-D75 in **terminal mode** (Menu 650) stops acting as a
/// normal radio and instead speaks this protocol over its USB-CDC-ACM
/// interface. MacRats uses terminal mode to put DDT2 bytes into the 3-byte
/// slow-data field of each outbound D-STAR voice frame (using `silenceAMBE`
/// as the audio payload) and to read them back from inbound voice frames.
///
/// ## Wire format
///
/// ```
///   [0xE0] [length] [command] [...payload]
/// ```
///
/// - `0xE0` — frame-start marker.
/// - `length` — total frame length in bytes, **including** the marker, the
///   length byte, and the command byte. So for a 3-byte command-only frame
///   like `getStatus`, the length byte is `0x03`.
/// - `command` — one of the constants below.
/// - `payload` — variable-length per command.
///
/// ## Baud rate
///
/// **The TH-D75 uses 38400, not the standard MMDVM 115200.** Pass 38400
/// to `USBSerialTransport(baudRate:)` when connecting to the TH-D75 in
/// terminal mode.
///
/// ## References
///
/// - Ported from the sibling `th-programmer` project's
///   `Sources/TH-Programmer/MMDVM/MMDVMProtocol.swift`.
/// - Wire format based on MMDVMHost's `CModem::setConfig()` in upstream
///   MMDVMHost (see https://github.com/g4klx/MMDVMHost).
public enum MMDVMProtocol {

    // MARK: - Frame framing

    /// Frame start marker byte.
    public static let frameMarker: UInt8 = 0xE0

    /// Minimum on-wire frame size (marker + length + command).
    public static let minFrameSize: Int = 3

    // MARK: - Host → Modem commands

    /// Get firmware version.
    public static let getVersion: UInt8 = 0x00

    /// Get modem status.
    public static let getStatus: UInt8 = 0x01

    /// Set modem configuration.
    public static let setConfig: UInt8 = 0x02

    /// Set modem mode.
    public static let setMode: UInt8 = 0x03

    // MARK: - D-STAR frame commands

    /// D-STAR header frame (41-byte payload: 3 flags + 4×8 callsigns + 4 suffix + 2 CRC).
    public static let dstarHeader: UInt8 = 0x10

    /// D-STAR voice data frame (12-byte payload: 9 bytes AMBE + 3 bytes slow data).
    public static let dstarData: UInt8 = 0x11

    /// D-STAR frame-lost indicator.
    public static let dstarLost: UInt8 = 0x12

    /// D-STAR end-of-transmission marker.
    public static let dstarEOT: UInt8 = 0x13

    // MARK: - Modem → Host responses

    /// Positive acknowledgement.
    public static let ack: UInt8 = 0x70

    /// Negative acknowledgement (followed by a single reason byte in the payload).
    public static let nak: UInt8 = 0x7F

    // MARK: - Well-known D-STAR payload constants

    /// AMBE silence frame (9 bytes) — the standard D-STAR silent-voice codec
    /// output. For data-only transmissions, every voice frame uses this as
    /// the audio portion of its 12-byte payload. The air is literally
    /// silent on the other end, leaving the 3-byte slow-data field free to
    /// carry DDT2 bytes.
    public static let silenceAMBE = Data([0x9E, 0x8D, 0x32, 0x88, 0x26, 0x1A, 0x3F, 0x61, 0xE8])

    /// Slow-data filler (3 bytes) — sent in the slow-data field when there
    /// is nothing application-level to send. Used during idle moments
    /// within a transmission (e.g., TX keyup delay before the first DDT2
    /// byte is ready).
    public static let fillerSlowData = Data([0x16, 0x29, 0xF5])

    /// Number of voice frames per D-STAR superframe (0–20, wrapping).
    public static let framesPerSuperframe: UInt8 = 21

    // MARK: - Frame builders

    /// Build a complete MMDVM frame around an arbitrary command and payload.
    public static func buildFrame(command: UInt8, payload: Data = Data()) -> Data {
        let length = UInt8(minFrameSize + payload.count)
        var frame = Data(capacity: Int(length))
        frame.append(frameMarker)
        frame.append(length)
        frame.append(command)
        frame.append(payload)
        return frame
    }

    /// Build a Get Version probe: `[0xE0, 0x03, 0x00]`.
    public static func buildGetVersion() -> Data {
        buildFrame(command: getVersion)
    }

    /// Build a Get Status probe: `[0xE0, 0x03, 0x01]`.
    public static func buildGetStatus() -> Data {
        buildFrame(command: getStatus)
    }

    /// Build a `setConfig` frame that enables D-STAR mode.
    ///
    /// Uses the MMDVMHost protocol v1 config layout (23 payload bytes, 26
    /// on the wire). All values are lifted from the sibling `th-programmer`
    /// project's `buildSetConfig()` which has been verified working against
    /// a real TH-D75.
    public static func buildSetConfig() -> Data {
        var payload = Data(count: 23)
        payload[0]  = 0x00  // flags: simplex (bit 7 = 0), no inversions
        payload[1]  = 0x01  // modes: D-STAR enabled (bit 0)
        payload[2]  = 0x08  // TX delay: 8 × 10 ms = 80 ms preamble
        payload[3]  = 0x00  // mode state: MODE_IDLE
        payload[4]  = 0x32  // RX level: 50 %
        payload[5]  = 0x00  // CW ID TX level
        payload[6]  = 0x00  // DMR color code (unused)
        payload[7]  = 0x00  // DMR delay (unused)
        payload[8]  = 0x80  // oscillator offset: 128 = 0 offset
        payload[9]  = 0x32  // D-STAR TX level: 50 %
        payload[10] = 0x00  // DMR TX level (unused)
        payload[11] = 0x00  // YSF TX level (unused)
        payload[12] = 0x00  // P25 TX level (unused)
        payload[13] = 0x80  // TX DC offset: 128 = 0
        payload[14] = 0x80  // RX DC offset: 128 = 0
        payload[15] = 0x00  // NXDN TX level (unused)
        payload[16] = 0x00  // YSF TX hang (unused)
        payload[17] = 0x00  // POCSAG TX level (unused)
        payload[18] = 0x00  // FM TX level (unused)
        payload[19] = 0x00  // P25 TX hang (unused)
        payload[20] = 0x00  // NXDN TX hang (unused)
        payload[21] = 0x00  // M17 TX level (unused)
        payload[22] = 0x00  // M17 TX hang (unused)
        return buildFrame(command: setConfig, payload: payload)
    }

    /// Build a `setMode` frame.
    ///
    /// Mode byte: `0x00` = idle, `0x01` = D-STAR, `0x02` = DMR, etc.
    /// MacRats always wants `0x01` (D-STAR) in v1.0.
    public static func buildSetMode(mode: UInt8 = 0x01) -> Data {
        buildFrame(command: setMode, payload: Data([mode]))
    }

    // MARK: - D-STAR frame builders

    /// Build a D-STAR voice data frame for sending to the modem.
    ///
    /// Payload is exactly 12 bytes: 9 AMBE + 3 slow data.
    /// Short inputs are zero-padded; long inputs are truncated.
    ///
    /// For data-only D-STAR (the MacRats use case), pass
    /// `MMDVMProtocol.silenceAMBE` as `ambe` and up to 3 bytes of DDT2
    /// stream data as `slowData`. Use `MMDVMProtocol.fillerSlowData` when
    /// there is no DDT2 data ready but the transmission must continue.
    public static func buildDStarData(ambe: Data, slowData: Data) -> Data {
        var payload = Data(capacity: 12)
        payload.append(ambe.prefix(9))
        if ambe.count < 9 {
            payload.append(Data(count: 9 - ambe.count))
        }
        payload.append(slowData.prefix(3))
        if slowData.count < 3 {
            payload.append(Data(count: 3 - slowData.count))
        }
        return buildFrame(command: dstarData, payload: payload)
    }

    /// Build a D-STAR end-of-transmission frame.
    public static func buildDStarEOT() -> Data {
        buildFrame(command: dstarEOT)
    }

    /// Build a D-STAR header frame from the four callsign fields.
    ///
    /// The 41-byte payload layout is:
    ///
    /// | offset | size | field          |
    /// |--------|------|----------------|
    /// |    0   |   3  | flags          |
    /// |    3   |   8  | RPT2 callsign  |
    /// |   11   |   8  | RPT1 callsign  |
    /// |   19   |   8  | YOUR callsign  |
    /// |   27   |   8  | MY callsign    |
    /// |   35   |   4  | MY suffix      |
    /// |   39   |   2  | CRC-CCITT over bytes 0..38, little-endian |
    ///
    /// All callsign fields are space-padded to 8 bytes.
    public static func buildDStarHeader(
        myCallsign: String,
        yourCallsign: String = "CQCQCQ  ",
        rpt1Callsign: String = "        ",
        rpt2Callsign: String = "        "
    ) -> Data {
        var payload = Data(count: 41)

        // Bytes 0-2: flag bytes — zero for a normal voice+data transmission.
        payload[0] = 0x00
        payload[1] = 0x00
        payload[2] = 0x00

        // Bytes 3-10: RPT2 callsign
        writeCallsign(rpt2Callsign, to: &payload, offset: 3)
        // Bytes 11-18: RPT1 callsign
        writeCallsign(rpt1Callsign, to: &payload, offset: 11)
        // Bytes 19-26: YOUR callsign
        writeCallsign(yourCallsign, to: &payload, offset: 19)
        // Bytes 27-34: MY callsign
        writeCallsign(myCallsign, to: &payload, offset: 27)

        // Bytes 35-38: MY suffix (4 bytes, space-padded)
        payload[35] = 0x20
        payload[36] = 0x20
        payload[37] = 0x20
        payload[38] = 0x20

        // Bytes 39-40: CRC-CCITT over bytes 0..38, little-endian
        let crc = DSTARCRC.compute(payload, from: 0, count: 39)
        payload[39] = UInt8(crc & 0xFF)
        payload[40] = UInt8((crc >> 8) & 0xFF)

        return buildFrame(command: dstarHeader, payload: payload)
    }

    // MARK: - Private helpers

    /// Write an 8-byte space-padded callsign into `data` at `offset`.
    /// Truncates if longer than 8 bytes.
    private static func writeCallsign(_ call: String, to data: inout Data, offset: Int) {
        let padded = call.padding(toLength: 8, withPad: " ", startingAt: 0)
        for (i, byte) in padded.utf8.prefix(8).enumerated() {
            data[offset + i] = byte
        }
    }
}
