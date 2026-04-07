import Foundation
import Testing
@testable import MacRatsCore

struct MacRatsSettingsTests {

    @Test("Default settings have sensible defaults")
    func defaults() {
        let s = MacRatsSettings()
        #expect(s.callsign == "")
        #expect(s.connectionKind == .disconnected)
        #expect(s.serialBaudRate == 9600)
        #expect(s.confirmExit == true)
        #expect(s.pingReplyText == "Running MacRats")
        #expect(s.showStatusUpdatesInChat == true)
        #expect(s.fixedLatitude == nil)
        #expect(s.fixedLongitude == nil)
        // Warmup + wire-logging defaults (match D-Rats upstream + MacRats)
        #expect(s.warmupLength == 16)
        #expect(s.warmupTimeoutSeconds == 3.0)
        #expect(s.forceDelaySeconds == 0)
        #expect(s.wireLoggingEnabled == false)
    }

    @Test("Round-trip encode/decode preserves every field")
    func roundTrip() throws {
        var original = MacRatsSettings()
        original.callsign = "AI5OS"
        original.signOnMessage = "Testing sign-on"
        original.signOffMessage = "Testing sign-off"
        original.pingReplyText = "Custom ping reply"
        original.confirmExit = false
        original.connectionKind = .serial
        original.serialDevicePath = "/dev/cu.usbmodem2011201"
        original.serialBaudRate = 38400
        original.tcpHost = "ratflector.example.org"
        original.tcpPort = 9001
        original.fixedLatitude = 30.2672
        original.fixedLongitude = -97.7431
        original.gpsComment = "Austin, TX"
        original.noticeRegex = "AI5OS(?i)"
        original.ignoreRegex = "[QST]"
        original.showStatusUpdatesInChat = false
        original.chatLogSubdirectory = "my-logs"
        original.warmupLength = 32
        original.warmupTimeoutSeconds = 5
        original.forceDelaySeconds = -2  // random 0..2s
        original.wireLoggingEnabled = true
        original.ratflectorPassword = "s3cret"
        original.ratflectorLabel = "sewx — Southeastern Weather Net"

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(MacRatsSettings.self, from: data)

        #expect(decoded == original)
    }

    @Test("Load from nonexistent file returns defaults")
    func loadMissingFile() {
        let bogusURL = URL(fileURLWithPath: "/tmp/macrats-definitely-missing-file-\(UUID().uuidString).json")
        let loaded = MacRatsSettings.load(from: bogusURL)
        #expect(loaded == MacRatsSettings())
    }

    @Test("Load from corrupt file returns defaults")
    func loadCorruptFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrats-corrupt-\(UUID().uuidString).json")
        try "this is not json {{{".data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loaded = MacRatsSettings.load(from: tmp)
        #expect(loaded == MacRatsSettings())
    }

    @Test("Save and reload preserves settings atomically")
    func saveAndReload() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrats-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var original = MacRatsSettings()
        original.callsign = "W9FYI"
        original.connectionKind = .tcpLoopback
        original.tcpPort = 9876
        try original.save(to: tmp)

        let loaded = MacRatsSettings.load(from: tmp)
        #expect(loaded == original)
    }

    @Test("Connection validation rejects empty callsign")
    func validationEmptyCallsign() {
        var s = MacRatsSettings()
        s.callsign = ""
        s.connectionKind = .serial
        s.serialDevicePath = "/dev/cu.usbmodem2011201"
        #expect(s.connectionValidationError() == "Callsign is required.")
    }

    @Test("Connection validation rejects disconnected kind")
    func validationDisconnected() {
        var s = MacRatsSettings()
        s.callsign = "AI5OS"
        s.connectionKind = .disconnected
        #expect(s.connectionValidationError()?.contains("No connection") == true)
    }

    @Test("Connection validation rejects empty serial path")
    func validationEmptySerialPath() {
        var s = MacRatsSettings()
        s.callsign = "AI5OS"
        s.connectionKind = .serial
        s.serialDevicePath = ""
        #expect(s.connectionValidationError()?.contains("serial device") == true)
    }

    @Test("Connection validation passes for a valid serial config")
    func validationValidSerial() {
        var s = MacRatsSettings()
        s.callsign = "AI5OS"
        s.connectionKind = .serial
        s.serialDevicePath = "/dev/cu.usbmodem2011201"
        s.serialBaudRate = 9600
        #expect(s.connectionValidationError() == nil)
    }

    @Test("Connection validation rejects ratflector without host")
    func validationRatflectorMissingHost() {
        var s = MacRatsSettings()
        s.callsign = "AI5OS"
        s.connectionKind = .tcpRatflector
        s.tcpHost = ""
        s.tcpPort = 9000
        #expect(s.connectionValidationError()?.contains("host") == true)
    }

    @Test("ConnectionKind displayName covers every case")
    func connectionKindDisplayNames() {
        for kind in MacRatsSettings.ConnectionKind.allCases {
            #expect(!kind.displayName.isEmpty)
        }
    }
}
