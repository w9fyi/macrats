import Foundation

/// Implements the D-Rats ratflector authentication handshake.
///
/// A ratflector is a TCP server (usually on port 9000) that relays
/// D-Rats chat/file/presence traffic between clients over the
/// internet. Before the connection becomes a plain DDT2 byte pipe,
/// the client and server exchange a tiny text-based handshake:
///
/// ```
/// Server → Client:  "100 Authentication not required\r\n"
///                   (or "101 Authorization required\r\n")
///
/// If 100:  handshake done, start DDT2
///
/// If 101:  Client → Server:  "USER <callsign>\r\n"
///          Server → Client:  "200 ...\r\n"  or  "102 ...\r\n"
///
///          If 200:  handshake done, start DDT2
///          If 102:  Client → Server:  "PASS <password>\r\n"
///                   Server → Client:  "200 ...\r\n"  (or error)
/// ```
///
/// The handshake is text, one line at a time, `\r\n` or `\n`
/// terminated. Each line starts with a three-digit numeric response
/// code. Known codes (from `d-rats_repeater.py` lines 270-330):
///
/// - `100` Authentication not required (proceed straight to DDT2)
/// - `101` Authorization required (client must send USER/PASS)
/// - `102` Username accepted, waiting for password
/// - `200` Authorized / authentication successful
/// - `201` Protocol violation
/// - `500` Not authorized
/// - `501` Invalid syntax
///
/// **Old-school ratflectors** (pre-handshake versions) accept the
/// TCP connection but never send a banner at all. If the first read
/// returns EOF or times out, MacRats assumes it's talking to one of
/// these and proceeds directly to DDT2 without a handshake. This
/// matches D-Rats's upstream behavior in `d_rats/comm.py` line 1079:
/// *"Assuming an old-school ratflector for now"*.
///
/// This type is stateless and testable without any real networking.
/// `performHandshake(read:write:)` takes closures for byte I/O so
/// tests can inject a scripted server reply.
public enum RatflectorHandshake {

    // MARK: - Public API

    /// Perform the handshake. The caller supplies a `read` closure
    /// that returns one line of text (without the trailing newline)
    /// or throws on timeout/EOF, and a `write` closure that accepts
    /// bytes to send.
    ///
    /// - Parameters:
    ///   - callsign: the client's callsign. Only sent if the server
    ///     asks for authentication (code `101`). May be `nil` for
    ///     servers that don't require auth.
    ///   - password: optional password, only sent if the server
    ///     responds `102` after the USER line.
    ///   - read: closure that reads one line from the socket,
    ///     with the server-side `\r\n` already stripped. Must throw
    ///     `RatflectorHandshakeError.timeout` on read timeout,
    ///     `RatflectorHandshakeError.eof` when the server closes
    ///     the connection, and may throw any other error for socket
    ///     failures.
    ///   - write: closure that writes raw bytes. Called once or
    ///     twice during auth.
    /// - Returns: a `Result` describing how the handshake completed.
    ///   Note that "old-school" is a successful completion — the
    ///   caller should proceed directly to DDT2.
    /// - Throws: `RatflectorHandshakeError` on any explicit failure.
    public static func performHandshake(
        callsign: String?,
        password: String?,
        read: () throws -> String,
        write: (Data) throws -> Void
    ) throws -> Result {
        // Step 1 — read the server's initial banner line.
        let initialLine: String
        do {
            initialLine = try read()
        } catch RatflectorHandshakeError.timeout, RatflectorHandshakeError.eof {
            // Old-school ratflector: accepted the connection but
            // doesn't speak the handshake. Proceed directly to DDT2.
            return .oldSchool
        }

        let (code, _) = try parseResponseLine(initialLine)

        switch code {
        case 100:
            // No authentication required — done.
            return .authenticated(initialLine)

        case 101:
            // Auth required. Send USER line.
            guard let callsign, !callsign.isEmpty else {
                throw RatflectorHandshakeError.authRequiredButCallsignMissing
            }
            try write(Data("USER \(callsign)\r\n".utf8))

            // Read the response to USER.
            let userResponse = try read()
            let (userCode, _) = try parseResponseLine(userResponse)
            switch userCode {
            case 200:
                // Authenticated with no password — done.
                return .authenticated(userResponse)
            case 102:
                // Waiting for password. Send PASS line.
                guard let password, !password.isEmpty else {
                    throw RatflectorHandshakeError.passwordRequired
                }
                try write(Data("PASS \(password)\r\n".utf8))
                let passResponse = try read()
                let (passCode, passText) = try parseResponseLine(passResponse)
                if passCode == 200 {
                    return .authenticated(passResponse)
                }
                throw RatflectorHandshakeError.authenticationFailed(
                    code: passCode, message: passText
                )
            case 500:
                throw RatflectorHandshakeError.authenticationFailed(
                    code: userCode,
                    message: "User rejected"
                )
            default:
                throw RatflectorHandshakeError.unexpectedResponseCode(userCode, userResponse)
            }

        default:
            throw RatflectorHandshakeError.unexpectedResponseCode(code, initialLine)
        }
    }

    // MARK: - Output

    /// Result of a successful handshake.
    public enum Result: Equatable, Sendable {
        /// Server spoke the modern handshake and authenticated us.
        /// The associated line is the final "200 …" (or "100 …")
        /// line for diagnostic display.
        case authenticated(String)

        /// Server is a pre-handshake ratflector that accepted the
        /// connection without a banner. The caller should proceed
        /// directly to DDT2 with no further negotiation.
        case oldSchool
    }

    // MARK: - Line parser

    /// Parse a single response line into its integer code and the
    /// trailing message text (e.g. `"100 Authentication not required"`
    /// → `(100, "Authentication not required")`).
    ///
    /// Accepts lines with or without a trailing `\r`. Tolerates any
    /// amount of whitespace between the code and the message.
    ///
    /// Throws `invalidResponseLine` if the line is empty or doesn't
    /// start with a three-digit number.
    public static func parseResponseLine(_ line: String) throws -> (code: Int, message: String) {
        // Strip any leading/trailing whitespace or stray \r.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RatflectorHandshakeError.invalidResponseLine(line)
        }

        // Extract the leading run of digits.
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, let code = Int(digits) else {
            throw RatflectorHandshakeError.invalidResponseLine(line)
        }

        // Anything after the digits (with leading whitespace stripped)
        // is the human-readable message.
        let remainder = trimmed.dropFirst(digits.count)
            .drop(while: { $0 == " " || $0 == "\t" })
        return (code, String(remainder))
    }
}

// MARK: - Errors

public enum RatflectorHandshakeError: Error, LocalizedError, Equatable {
    /// The read closure signaled a read timeout before any bytes
    /// arrived. The outer layer may treat this as "old-school
    /// ratflector" and proceed to DDT2.
    case timeout

    /// The server closed the socket before sending anything. Also
    /// treated as "old-school".
    case eof

    /// A response line couldn't be parsed (empty line, no leading
    /// digits, etc.).
    case invalidResponseLine(String)

    /// The server sent a response code we don't know how to handle
    /// at this point in the state machine.
    case unexpectedResponseCode(Int, String)

    /// The server required auth (`101`) but the caller didn't
    /// provide a callsign.
    case authRequiredButCallsignMissing

    /// The server asked for a password (`102`) but the caller
    /// didn't provide one.
    case passwordRequired

    /// The server rejected our credentials with a non-`200` response
    /// code at the final step.
    case authenticationFailed(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Ratflector did not send a handshake banner in time"
        case .eof:
            return "Ratflector closed the connection during handshake"
        case .invalidResponseLine(let line):
            return "Ratflector sent an unparseable response line: \(line)"
        case .unexpectedResponseCode(let code, let line):
            return "Ratflector returned unexpected response code \(code): \(line)"
        case .authRequiredButCallsignMissing:
            return "Ratflector requires authentication but no callsign is configured"
        case .passwordRequired:
            return "Ratflector requires a password but none is configured"
        case .authenticationFailed(let code, let message):
            return "Ratflector authentication failed (\(code)): \(message)"
        }
    }
}
