import Foundation
import Testing
@testable import MacRatsCore

/// Tests for `RatflectorHandshake` — the text-based authentication
/// exchange that D-Rats ratflectors perform before accepting DDT2
/// traffic. All tests drive the handshake synchronously with
/// scripted read/write closures; no real networking involved.
struct RatflectorHandshakeTests {

    // MARK: - Line parser

    @Test("parseResponseLine extracts code and message from a normal line")
    func parseNormalLine() throws {
        let (code, msg) = try RatflectorHandshake.parseResponseLine("100 Authentication not required")
        #expect(code == 100)
        #expect(msg == "Authentication not required")
    }

    @Test("parseResponseLine tolerates trailing \\r")
    func parseTrailingCarriageReturn() throws {
        let (code, msg) = try RatflectorHandshake.parseResponseLine("200 Welcome\r")
        #expect(code == 200)
        #expect(msg == "Welcome")
    }

    @Test("parseResponseLine tolerates extra whitespace")
    func parseExtraWhitespace() throws {
        let (code, msg) = try RatflectorHandshake.parseResponseLine("   102    Password needed  ")
        #expect(code == 102)
        #expect(msg == "Password needed")
    }

    @Test("parseResponseLine throws on empty line")
    func parseEmpty() {
        #expect(throws: RatflectorHandshakeError.self) {
            _ = try RatflectorHandshake.parseResponseLine("")
        }
    }

    @Test("parseResponseLine throws on line that doesn't start with digits")
    func parseNoDigits() {
        #expect(throws: RatflectorHandshakeError.self) {
            _ = try RatflectorHandshake.parseResponseLine("HELLO server")
        }
    }

    // MARK: - Scripted handshake driver

    /// A mutable script the test can drive forward. `read()` returns
    /// the next queued line; `write()` records everything the
    /// handshake tried to send.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [Result<String, Error>] = []
        private(set) var writes: [Data] = []

        func enqueue(line: String) {
            lock.lock(); defer { lock.unlock() }
            queued.append(.success(line))
        }

        func enqueue(error: Error) {
            lock.lock(); defer { lock.unlock() }
            queued.append(.failure(error))
        }

        func read() throws -> String {
            lock.lock(); defer { lock.unlock() }
            precondition(!queued.isEmpty, "script ran out of queued lines — handshake read too much")
            let next = queued.removeFirst()
            switch next {
            case .success(let line): return line
            case .failure(let err):  throw err
            }
        }

        func write(_ data: Data) throws {
            lock.lock(); defer { lock.unlock() }
            writes.append(data)
        }

        var writesAsStrings: [String] {
            writes.map { String(decoding: $0, as: UTF8.self) }
        }
    }

    // MARK: - Handshake tests

    @Test("Server sends code 100 — authenticate successfully without credentials")
    func code100NoAuth() throws {
        let script = Script()
        script.enqueue(line: "100 Authentication not required")

        let result = try RatflectorHandshake.performHandshake(
            callsign: nil,
            password: nil,
            read: { try script.read() },
            write: { try script.write($0) }
        )

        if case .authenticated(let line) = result {
            #expect(line.contains("100"))
        } else {
            Issue.record("expected .authenticated, got \(result)")
        }
        // No writes should have happened — we're anonymous.
        #expect(script.writes.isEmpty)
    }

    @Test("Server sends code 101 then 200 — USER accepted, no password needed")
    func code101Then200() throws {
        let script = Script()
        script.enqueue(line: "101 Authorization required")
        script.enqueue(line: "200 User accepted")

        let result = try RatflectorHandshake.performHandshake(
            callsign: "AI5OS",
            password: nil,
            read: { try script.read() },
            write: { try script.write($0) }
        )

        if case .authenticated = result {
            // ok
        } else {
            Issue.record("expected .authenticated, got \(result)")
        }
        #expect(script.writesAsStrings == ["USER AI5OS\r\n"])
    }

    @Test("Server sends 101 → 102 → 200 — password flow completes")
    func code101Then102Then200() throws {
        let script = Script()
        script.enqueue(line: "101 Authorization required")
        script.enqueue(line: "102 Password required")
        script.enqueue(line: "200 Welcome")

        let result = try RatflectorHandshake.performHandshake(
            callsign: "AI5OS",
            password: "hunter2",
            read: { try script.read() },
            write: { try script.write($0) }
        )

        if case .authenticated = result {
            // ok
        } else {
            Issue.record("expected .authenticated, got \(result)")
        }
        #expect(script.writesAsStrings == [
            "USER AI5OS\r\n",
            "PASS hunter2\r\n"
        ])
    }

    @Test("Server sends 101 without a callsign available — throws")
    func code101MissingCallsign() {
        let script = Script()
        script.enqueue(line: "101 Authorization required")

        #expect(throws: RatflectorHandshakeError.self) {
            _ = try RatflectorHandshake.performHandshake(
                callsign: nil,
                password: nil,
                read: { try script.read() },
                write: { try script.write($0) }
            )
        }
    }

    @Test("Server wants a password but none is configured — throws")
    func code102MissingPassword() {
        let script = Script()
        script.enqueue(line: "101 Authorization required")
        script.enqueue(line: "102 Password required")

        #expect(throws: RatflectorHandshakeError.self) {
            _ = try RatflectorHandshake.performHandshake(
                callsign: "AI5OS",
                password: nil,
                read: { try script.read() },
                write: { try script.write($0) }
            )
        }
    }

    @Test("Server rejects password with 500 — throws authenticationFailed")
    func code101ThenPasswordRejected() throws {
        let script = Script()
        script.enqueue(line: "101 Authorization required")
        script.enqueue(line: "102 Password required")
        script.enqueue(line: "500 Not authorized")

        do {
            _ = try RatflectorHandshake.performHandshake(
                callsign: "AI5OS",
                password: "wrong",
                read: { try script.read() },
                write: { try script.write($0) }
            )
            Issue.record("expected authenticationFailed to throw")
        } catch RatflectorHandshakeError.authenticationFailed(let code, _) {
            #expect(code == 500)
        }
    }

    @Test("Server rejects user with 500 — throws")
    func code101UserRejected() throws {
        let script = Script()
        script.enqueue(line: "101 Authorization required")
        script.enqueue(line: "500 User unknown")

        do {
            _ = try RatflectorHandshake.performHandshake(
                callsign: "NOBODY",
                password: "anything",
                read: { try script.read() },
                write: { try script.write($0) }
            )
            Issue.record("expected authenticationFailed to throw")
        } catch RatflectorHandshakeError.authenticationFailed(let code, _) {
            #expect(code == 500)
        }
    }

    @Test("First read times out — falls through to old-school ratflector")
    func oldSchoolOnTimeout() throws {
        let script = Script()
        script.enqueue(error: RatflectorHandshakeError.timeout)

        let result = try RatflectorHandshake.performHandshake(
            callsign: "AI5OS",
            password: nil,
            read: { try script.read() },
            write: { try script.write($0) }
        )

        #expect(result == .oldSchool)
        #expect(script.writes.isEmpty)
    }

    @Test("First read returns EOF — falls through to old-school ratflector")
    func oldSchoolOnEOF() throws {
        let script = Script()
        script.enqueue(error: RatflectorHandshakeError.eof)

        let result = try RatflectorHandshake.performHandshake(
            callsign: "AI5OS",
            password: nil,
            read: { try script.read() },
            write: { try script.write($0) }
        )

        #expect(result == .oldSchool)
    }

    @Test("Server sends an unknown response code — throws unexpectedResponseCode")
    func unknownCode() throws {
        let script = Script()
        script.enqueue(line: "999 What is this")

        do {
            _ = try RatflectorHandshake.performHandshake(
                callsign: "AI5OS",
                password: nil,
                read: { try script.read() },
                write: { try script.write($0) }
            )
            Issue.record("expected throw")
        } catch RatflectorHandshakeError.unexpectedResponseCode(let code, _) {
            #expect(code == 999)
        }
    }

    // MARK: - Real captured banner

    @Test("Real captured ratflector banner decodes to code 100")
    func realCapturedBanner() throws {
        // This is the exact bytes returned by sewx.ratflector.com,
        // sttammany.ratflector.com, pldares.ratflector.com,
        // gaares.ratflector.com, and gwinnettares.ratflector.com in
        // session 9 (2026-04-07). All five active public ratflectors
        // return this identical banner.
        let bytes: [UInt8] = [
            0x31, 0x30, 0x30, 0x20, // "100 "
            0x41, 0x75, 0x74, 0x68, 0x65, 0x6e, 0x74, 0x69, 0x63, 0x61, 0x74, 0x69, 0x6f, 0x6e, // "Authentication"
            0x20, 0x6e, 0x6f, 0x74, 0x20, 0x72, 0x65, 0x71, 0x75, 0x69, 0x72, 0x65, 0x64, // " not required"
            0x0d, 0x0a // \r\n
        ]
        let line = String(decoding: bytes.dropLast(2), as: UTF8.self) // strip \r\n
        let (code, msg) = try RatflectorHandshake.parseResponseLine(line)
        #expect(code == 100)
        #expect(msg == "Authentication not required")
    }
}
