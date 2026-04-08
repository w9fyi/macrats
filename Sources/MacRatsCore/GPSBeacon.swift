import Foundation

/// Minimal GPS beacon encoder and decoder for D-Rats APRS-style position
/// reports. Ported from `d_rats/gps.py` in upstream ham-radio-software/D-Rats
/// (the `GPSPosition.to_aprs` method + `gpsa_checksum` + `deg2nmea`
/// helpers).
///
/// ## What this is
///
/// D-Rats stations can broadcast their location by sending a specially
/// formatted chat message through the normal `T_DEF` chat frame type.
/// The receiver tells the difference between a chat message and a
/// position report by looking for the literal string `$$CRC` at the
/// start of the payload — if it's there, the message is an
/// APRS-compliant position report ("GPS-A" in upstream's terminology);
/// otherwise it's ordinary text.
///
/// A position report looks like this on the wire (line breaks shown
/// for readability, actual message is a single CR-terminated string):
///
/// ```text
/// $$CRC<hex>,<callsign>>APRATS,DSTAR*:/<HHMMSS>h<lat><N|S><symTable><lon><E|W><symbol>[<dir/spd>][/A=altitude]<comment>\r
/// ```
///
/// - `$$CRC<hex>` — `gpsa_checksum` of everything after the comma, 4 hex digits.
/// - `<callsign>` — the sender's call. Spaces are replaced with `-`.
/// - `>APRATS,DSTAR*` — fixed AX.25-style path (D-Rats is the destination).
/// - `:/HHMMSSh` — APRS time-of-day prefix, UTC, `h` = HMS.
/// - `<lat>` — 7 characters in `DDMM.MM` format (two-digit degrees, two-digit
///   minutes, a period, two more minute digits).
/// - `<N|S>` — hemisphere.
/// - `<symTable>` — APRS symbol table (`/` = primary, `\` = alternate).
/// - `<lon>` — 8 characters in `DDDMM.MM` format (three-digit degrees).
/// - `<E|W>` — hemisphere.
/// - `<symbol>` — APRS symbol character. Upstream default is the car `>`.
/// - `<dir/spd>` — optional 7-character `DDD/SSS` direction and speed.
/// - `/A=altitude` — optional 9-character altitude in feet.
/// - `<comment>` — optional free-form text, clipped to fit inside a ~43-byte
///   total station payload.
///
/// `GPSBeacon` implements the fixed-position subset: no speed, no
/// direction, no altitude. That's enough for a static MacRats station
/// ("this is my QTH") but not enough to be a mobile tracker — mobile
/// tracking belongs to a future Core Location integration.
///
/// ## Limits of this port
///
/// - **Encode only the most common fields.** Upstream supports NMEA
///   `$GPGGA` / `$GPRMC` sentences as well as DPRS-coded comments, and
///   will happily generate either. MacRats emits `$$CRC` APRS form
///   exclusively because that's the format used by all modern D-Rats
///   stations and it's the one that survives serialization through
///   the DDT2 layer cleanly.
/// - **Decode the `$$CRC` form only.** NMEA decoding is deferred. A
///   frame that starts with `$GPGGA` or `$GPRMC` is currently treated
///   as chat text (which is harmless — it just shows up as a weird
///   message in the chat log).
/// - **Checksum is verified on receive.** If it fails, the beacon is
///   rejected and the frame is passed through as plain chat. This
///   matches the upstream fallback behavior.
public enum GPSBeacon {

    /// A decoded position report. Enough information to show "station X
    /// is at lat/lon with comment Y" in the heard-stations panel.
    public struct Fix: Equatable, Sendable {
        public let station: String
        public let latitude: Double     // Decimal degrees, negative for S
        public let longitude: Double    // Decimal degrees, negative for W
        public let comment: String

        public init(station: String, latitude: Double, longitude: Double, comment: String) {
            self.station = station
            self.latitude = latitude
            self.longitude = longitude
            self.comment = comment
        }
    }

    // MARK: - Encode

    /// Build a D-Rats APRS-style fixed-position beacon payload.
    ///
    /// Returns the exact bytes to pass to `ChatSession.sendMessage(_:to:)`
    /// — the caller hands this to the chat layer unchanged, which in
    /// turn packages it into a `T_DEF` frame. A receiver sees a chat
    /// message whose text starts with `$$CRC`; upstream D-Rats and
    /// MacRats both route that to `decode(_:)` instead of rendering
    /// it as chat.
    ///
    /// - Parameters:
    ///   - station: Sender callsign. Up to 8 characters; spaces become `-`.
    ///   - latitude: Decimal degrees. Negative values are South.
    ///   - longitude: Decimal degrees. Negative values are West.
    ///   - comment: Free-form comment. Clipped to 43 characters.
    ///   - symbolTable: APRS symbol table, `/` or `\`. Default `/`.
    ///   - symbol: APRS symbol character. Default `>` (the car, matching
    ///     upstream's `APRS_CAR_CODE`).
    ///   - now: Timestamp for the report (UTC). Defaults to current time —
    ///     parameterized so tests can pin a fixed clock.
    /// - Returns: The full beacon payload including the leading `$$CRC`
    ///   marker and the trailing `\r`.
    public static func encode(station: String,
                              latitude: Double,
                              longitude: Double,
                              comment: String = "",
                              symbolTable: Character = "/",
                              symbol: Character = ">",
                              now: Date = Date()) -> String {
        let sta = station.replacingOccurrences(of: " ", with: "-")

        // APRS time: HHMMSS in UTC with a trailing "h" to flag
        // hours/minutes/seconds form (as opposed to "z" for day).
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "HHmmss"
        let stamp = df.string(from: now)

        // Convert lat/lon to NMEA DDMM.MM form, picking the hemisphere
        // letter from the sign. The upstream algorithm operates on
        // absolute values and then prefixes N/S / E/W.
        let latAbs = abs(latitude)
        let lonAbs = abs(longitude)
        let northSouth: Character = latitude >= 0 ? "N" : "S"
        let eastWest:   Character = longitude >= 0 ? "E" : "W"

        let latNmea = deg2nmea(latAbs)
        let lonNmea = deg2nmea(lonAbs)

        // Upstream uses `%07.2f` for latitude and `%08.2f` for longitude.
        // %07.2f = minimum width 7 including the decimal and two fraction
        // digits, zero-padded. Swift's String(format:) matches.
        let latStr = String(format: "%07.2f", latNmea)
        let lonStr = String(format: "%08.2f", lonNmea)

        // The body ("station string") starts with the AX.25 path and
        // the APRS time prefix, then the lat/table/lon/symbol.
        var body = "\(sta)>APRATS,DSTAR*:/\(stamp)h"
        body += "\(latStr)\(northSouth)\(symbolTable)\(lonStr)\(eastWest)\(symbol)"

        // Comment clip to 43 bytes (upstream leaves room for /A=xxxxxx
        // when altitude is present, which we never emit).
        let clipped = String(comment.prefix(43))
        body += clipped

        // APRS row terminates in a single CR.
        body += "\r"

        // GPSA checksum is computed over the body (everything after the
        // `$$CRC<hex>,` prefix, INCLUDING the trailing \r).
        let checksum = gpsaChecksum(body)
        let hex = String(format: "%04X", checksum)

        // Upstream appends a "\n" after the body — keep parity so any
        // receiver that splits on newlines still sees the full payload.
        return "$$CRC\(hex),\(body)\n"
    }

    /// Convenience — build a beacon for a station that will transmit at
    /// the caller's current time using reasonable defaults.
    public static func encode(station: String,
                              latitude: Double,
                              longitude: Double,
                              comment: String) -> String {
        encode(station: station,
               latitude: latitude,
               longitude: longitude,
               comment: comment,
               symbolTable: "/",
               symbol: ">",
               now: Date())
    }

    // MARK: - Decode

    /// Try to decode a payload as a GPS fix. Returns `nil` if the payload
    /// isn't a `$$CRC` beacon or the checksum fails.
    ///
    /// Pattern: `$$CRC<hex>,<body>` where `<body>` starts with the
    /// `<sender>>APRATS` AX.25 path and contains the lat/lon/symbol/comment.
    /// We don't need to understand the full APRS packet to pull out the
    /// fields we care about — station, lat, lon, and everything after
    /// the symbol as the comment.
    public static func decode(_ payload: String) -> Fix? {
        // Must start with "$$CRC"; lead characters up to the checksum
        // comma form the checksum. Anything that fails to match is not
        // a beacon — return nil and let the caller treat the payload
        // as chat text.
        guard payload.hasPrefix("$$CRC") else { return nil }
        let afterPrefix = payload.dropFirst(5) // drop "$$CRC"

        // Checksum is 4 hex digits followed by a comma.
        guard afterPrefix.count >= 5,
              let commaIdx = afterPrefix.firstIndex(of: ",") else { return nil }
        let hexField = String(afterPrefix[..<commaIdx])
        guard hexField.count == 4,
              let expectedChecksum = UInt16(hexField, radix: 16) else { return nil }

        // Body is everything after the comma. Strip a trailing \n and
        // ensure the body ends with \r, which is what the sender
        // computed its checksum over.
        //
        // **Swift grapheme gotcha:** `\r\n` is a single Character
        // (grapheme cluster) in Swift, so `body.hasSuffix("\n")` returns
        // false and `removeLast()` strips BOTH `\r` and `\n` at once.
        // Work on UTF-8 bytes directly to avoid the surprise.
        var bodyBytes = Array(afterPrefix[afterPrefix.index(after: commaIdx)...].utf8)
        if bodyBytes.last == 0x0A { bodyBytes.removeLast() }  // strip LF
        if bodyBytes.last != 0x0D { bodyBytes.append(0x0D) }  // ensure CR
        guard let body = String(bytes: bodyBytes, encoding: .utf8) else {
            return nil
        }

        let actualChecksum = gpsaChecksum(body)
        guard actualChecksum == expectedChecksum else { return nil }

        // Parse the body now that we trust it. The format is:
        //
        //   <sender>>APRATS,DSTAR*:/HHMMSSh<lat><N|S><symTable><lon><E|W><sym><comment>\r
        //
        // We don't need a full AX.25 decoder — grep for ">APRATS" as
        // the split between sender and path, then skip to the "/"
        // that marks the APRS time prefix and step through the fixed
        // offsets.
        guard let pathRange = body.range(of: ">APRATS") else { return nil }
        let station = String(body[..<pathRange.lowerBound])

        // Find the "/HHMMSSh" — that's the APRS time prefix and the
        // lat begins immediately after the "h".
        guard let afterColon = body.range(of: ":/", range: pathRange.upperBound..<body.endIndex) else {
            return nil
        }
        let afterTimePrefix = afterColon.upperBound
        // Time is 6 digits + 'h'. Move past them.
        guard body.distance(from: afterTimePrefix, to: body.endIndex) >= 7 else { return nil }
        let latStart = body.index(afterTimePrefix, offsetBy: 7)

        // Latitude: 7 characters (DDMM.MM), then N/S, then symbol
        // table, then longitude: 8 characters (DDDMM.MM), then E/W,
        // then symbol, then comment through the trailing \r.
        guard body.distance(from: latStart, to: body.endIndex) >= 7 + 1 + 1 + 8 + 1 + 1 + 1 else {
            return nil
        }
        let latEnd = body.index(latStart, offsetBy: 7)
        let latStr = String(body[latStart..<latEnd])

        let nsChar = body[latEnd]
        let symTableIdx = body.index(after: latEnd)
        let lonStart = body.index(after: symTableIdx)
        let lonEnd = body.index(lonStart, offsetBy: 8)
        let lonStr = String(body[lonStart..<lonEnd])
        let ewChar = body[lonEnd]
        let symbolIdx = body.index(after: lonEnd)
        let commentStart = body.index(after: symbolIdx)

        guard let latNmea = Double(latStr),
              let lonNmea = Double(lonStr) else { return nil }

        var latitude  = nmea2deg(latNmea)
        var longitude = nmea2deg(lonNmea)
        if nsChar == "S" { latitude  = -latitude  }
        if ewChar == "W" { longitude = -longitude }

        // Comment runs to the trailing "\r" (already guaranteed to be
        // present above). Strip it.
        var comment = String(body[commentStart...])
        if comment.hasSuffix("\r") { comment.removeLast() }

        return Fix(station: station,
                   latitude: latitude,
                   longitude: longitude,
                   comment: comment)
    }

    // MARK: - Math helpers (ported from d_rats/gps.py)

    /// Convert decimal degrees to the NMEA `DDMM.MM` form used inside
    /// APRS position reports. Operates on absolute values — the sign
    /// is encoded separately via N/S/E/W letters at the call site.
    ///
    /// Example: 30.2672 → 30 degrees, 16.032 minutes → 3016.032.
    public static func deg2nmea(_ deg: Double) -> Double {
        let degInt = Double(Int(deg))
        let minutes = (deg - degInt) * 60.0
        return degInt * 100 + minutes
    }

    /// Inverse of `deg2nmea`. `DDMM.MM` → decimal degrees.
    public static func nmea2deg(_ nmea: Double) -> Double {
        let deg = Double(Int(nmea / 100))
        let minutes = nmea - deg * 100
        return deg + minutes / 60.0
    }

    /// GPSA checksum: Icom's CRC variant used for APRS-over-D-STAR
    /// position reports. Ported byte-for-byte from `gpsa_checksum` in
    /// upstream `d_rats/gps.py`. Operates on the **UTF-8 / ASCII bytes**
    /// of the input string — not code points — so non-ASCII comments
    /// would be hashed byte-by-byte. MacRats should stick to ASCII in
    /// comments anyway because D-STAR slow-data is 7-bit clean at best.
    public static func gpsaChecksum(_ string: String) -> UInt16 {
        var icomcrc: UInt16 = 0xFFFF
        for byte in Array(string.utf8) {
            var char = UInt16(byte)
            for _ in 0..<8 {
                let xorflag = ((icomcrc ^ char) & 0x01) == 0x01
                icomcrc = (icomcrc >> 1) & 0x7FFF
                if xorflag {
                    icomcrc ^= 0x8408
                }
                char = (char >> 1) & 0x7F
            }
        }
        return (~icomcrc) & 0xFFFF
    }
}
