import Foundation
import MacRatsCore

/// macrats-chat — interactive chat CLI for MacRats.
///
/// Spawns a `SessionManager` bound to either a TCP loopback peer (for
/// two-instance testing without a radio) or a real serial device, then
/// presents a line-oriented REPL that:
///
///   - Prints every incoming chat message, ping, and status update
///   - Lets you send chat messages with `<dest> <message>` or just
///     `<message>` for CQCQCQ broadcast
///   - Supports commands: `/ping <callsign>`, `/status <online|unattended|offline> <message>`,
///     `/quit`
///
/// This is the v0.1 "everything but the SwiftUI" MacRats — it exercises
/// the full protocol + session stack from the command line, which is
/// useful for:
///
/// - Integration testing with another MacRats process on localhost
/// - Connecting to a real D-Rats ratflector over TCP (v1.1 feature)
/// - Sanity-checking behavior against a live radio once Terminal Mode
///   is enabled on the TH-D75
///
/// Usage:
///
///   macrats-chat --callsign AI5OS --server 9999
///       Listen for an incoming connection on TCP port 9999.
///
///   macrats-chat --callsign W9FYI --client 127.0.0.1 9999
///       Connect to a peer on TCP port 9999.
///
///   macrats-chat --callsign AI5OS --serial /dev/cu.usbmodem2011201 --baud 9600
///       Talk to a serial device (TH-D75 in normal or terminal mode,
///       or an external TNC).

@main
struct ChatCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            exit(2)
        }

        var callsign: String = ""
        var mode: Mode?
        var baud: Int32 = 9600

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--callsign":
                i += 1
                if i < args.count { callsign = args[i] }
            case "--server":
                i += 1
                if i < args.count, let port = UInt16(args[i]) {
                    mode = .server(port: port)
                }
            case "--client":
                i += 1
                if i + 1 < args.count, let port = UInt16(args[i + 1]) {
                    mode = .client(host: args[i], port: port)
                    i += 1
                }
            case "--serial":
                i += 1
                if i < args.count {
                    mode = .serial(path: args[i])
                }
            case "--ratflector":
                i += 1
                if i < args.count {
                    // Accept either "host:port" or just "host" (default port 9000).
                    let spec = args[i]
                    if let colonIdx = spec.firstIndex(of: ":"),
                       let port = UInt16(spec[spec.index(after: colonIdx)...]) {
                        mode = .ratflector(host: String(spec[..<colonIdx]), port: port)
                    } else {
                        mode = .ratflector(host: spec, port: 9000)
                    }
                }
            case "--baud":
                i += 1
                if i < args.count, let b = Int32(args[i]) { baud = b }
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                print("Unknown arg: \(args[i])")
                printUsage()
                exit(2)
            }
            i += 1
        }

        guard !callsign.isEmpty else {
            print("ERROR: --callsign is required")
            exit(2)
        }
        guard let mode else {
            print("ERROR: must specify --server, --client, --serial, or --ratflector")
            exit(2)
        }

        print("=== MacRats chat — \(callsign) ===")
        print("Transport: \(mode.description)")
        print("Type a message to broadcast to CQCQCQ.")
        print("Prefix with '<DEST> ' to send to a specific station.")
        print("Commands: /ping <call>, /status <online|unattended|offline> <msg>, /quit")
        print("")

        // Build the transport
        let transport: RadioTransport
        switch mode {
        case .server(let port):
            transport = TCPLoopbackTransport(mode: .server(port: port))
        case .client(let host, let port):
            transport = TCPLoopbackTransport(mode: .client(host: host, port: port))
        case .serial(let path):
            transport = USBSerialTransport(devicePath: path, baudRate: baud)
        case .ratflector(let host, let port):
            transport = RatflectorTransport(
                host: host,
                port: port,
                callsign: callsign,
                password: nil,
                handshakeTimeoutSeconds: 5
            )
        }

        let manager = SessionManager(callsign: callsign, transport: transport)
        manager.logHandler = { msg in
            print("[log] \(msg)")
        }

        let chat = ChatSession(pingReplyText: "Running MacRats \(callsign)")
        let delegate = ChatPrinter()
        chat.delegate = delegate
        manager.add(chat, id: 1)

        do {
            try manager.connect()
        } catch {
            print("Connect failed: \(error.localizedDescription)")
            exit(1)
        }

        // Wait briefly for the transport to come up.
        try? await Task.sleep(nanoseconds: 250_000_000)

        // REPL
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed == "/quit" {
                break
            }
            if trimmed.hasPrefix("/ping ") {
                let target = trimmed.dropFirst("/ping ".count).trimmingCharacters(in: .whitespaces)
                do {
                    try chat.pingStation(target)
                    print("  ... pinged \(target)")
                } catch {
                    print("  !! ping failed: \(error.localizedDescription)")
                }
                continue
            }
            if trimmed.hasPrefix("/status ") {
                let rest = trimmed.dropFirst("/status ".count)
                let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count >= 1 else {
                    print("  !! usage: /status <online|unattended|offline> [message]")
                    continue
                }
                let status: StationStatus
                switch parts[0].lowercased() {
                case "online":     status = .online
                case "unattended": status = .unattended
                case "offline":    status = .offline
                default:
                    print("  !! unknown status '\(parts[0])' — use online/unattended/offline")
                    continue
                }
                let message = parts.count > 1 ? String(parts[1]) : ""
                chat.currentStatus = status
                chat.currentStatusMessage = message
                do {
                    try chat.advertise(status: status, message: message)
                    print("  ... broadcast status \(status.description) '\(message)'")
                } catch {
                    print("  !! status failed: \(error.localizedDescription)")
                }
                continue
            }

            // Plain message. Parse `<DEST> <rest>` if the first token is all
            // uppercase A-Z0-9 3-8 chars (callsign-shaped); otherwise the
            // whole line is the message and destination is CQCQCQ.
            let tokens = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if tokens.count == 2, looksLikeCallsign(String(tokens[0])) {
                let dest = String(tokens[0]).uppercased()
                let body = String(tokens[1])
                do {
                    try chat.sendMessage(body, to: dest)
                    print("  ... sent to \(dest)")
                } catch {
                    print("  !! send failed: \(error.localizedDescription)")
                }
            } else {
                do {
                    try chat.sendMessage(trimmed)
                    print("  ... sent CQCQCQ")
                } catch {
                    print("  !! send failed: \(error.localizedDescription)")
                }
            }
        }

        print("--- shutting down ---")
        manager.disconnect()
    }

    static func printUsage() {
        print("""
Usage:
  macrats-chat --callsign <CALL> --server <PORT>
  macrats-chat --callsign <CALL> --client <HOST> <PORT>
  macrats-chat --callsign <CALL> --serial <DEVICE> [--baud <RATE>]
  macrats-chat --callsign <CALL> --ratflector <HOST[:PORT]>

Examples:
  macrats-chat --callsign AI5OS --server 9999
  macrats-chat --callsign W9FYI --client 127.0.0.1 9999
  macrats-chat --callsign AI5OS --serial /dev/cu.usbmodem2011201 --baud 9600
  macrats-chat --callsign AI5OS --ratflector sewx.ratflector.com
  macrats-chat --callsign AI5OS --ratflector sewx.ratflector.com:9000
""")
    }

    static func looksLikeCallsign(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 8 else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/")
        let upper = s.uppercased()
        return upper.unicodeScalars.allSatisfy { allowed.contains(Character($0)) }
    }
}

enum Mode: Sendable {
    case server(port: UInt16)
    case client(host: String, port: UInt16)
    case serial(path: String)
    case ratflector(host: String, port: UInt16)

    var description: String {
        switch self {
        case .server(let port):                return "TCP listen :\(port)"
        case .client(let host, let port):      return "TCP connect \(host):\(port)"
        case .serial(let path):                return "Serial \(path)"
        case .ratflector(let host, let port):  return "Ratflector \(host):\(port)"
        }
    }
}

/// Prints every ChatSession delegate callback to stdout with a short
/// timestamp, so two running instances of `macrats-chat` produce a
/// live transcript of traffic.
final class ChatPrinter: ChatSession.Delegate, @unchecked Sendable {
    private static let formatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    private func timestamp() -> String {
        Self.formatter.string(from: Date())
    }

    func chatSession(_ session: ChatSession, didReceiveMessage text: String, from sStation: String, to dStation: String) {
        print("\n[\(timestamp())] \(sStation) → \(dStation): \(text)")
    }

    func chatSession(_ session: ChatSession, didReceivePingRequest from: String, to dStation: String) {
        print("\n[\(timestamp())] PING request from \(from) → \(dStation)")
    }

    func chatSession(_ session: ChatSession, didReceivePingResponse from: String, to dStation: String, replyText: String) {
        print("\n[\(timestamp())] PING reply from \(from): \(replyText)")
    }

    func chatSession(_ session: ChatSession, didReceiveEchoRequest from: String, to dStation: String, payload: Data) {
        print("\n[\(timestamp())] ECHO request from \(from) (\(payload.count) bytes)")
    }

    func chatSession(_ session: ChatSession, didReceiveEchoResponse from: String, to dStation: String, payload: Data) {
        print("\n[\(timestamp())] ECHO reply from \(from) (\(payload.count) bytes)")
    }

    func chatSession(_ session: ChatSession, didReceiveStationStatus from: String, status: StationStatus, message: String) {
        print("\n[\(timestamp())] STATUS \(from): \(status.description) — \(message)")
    }
}
