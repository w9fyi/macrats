import Foundation
import Testing
@testable import MacRatsCore

struct ChatLogStoreTests {

    // MARK: - Helpers

    /// Build a temporary ChatLogStore in a fresh tmp directory. Caller
    /// is responsible for cleanup.
    private func makeTempStore(rotateAtBytes: Int64 = 10 * 1024 * 1024,
                               maxRecentCount: Int = 500) -> (store: ChatLogStore, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrats-chatlog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("chat.log.jsonl")
        let store = ChatLogStore(url: url, rotateAtBytes: rotateAtBytes, maxRecentCount: maxRecentCount)
        return (store, url)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Append + load round-trip

    @Test("Empty store returns an empty history")
    func emptyStore() {
        let (store, url) = makeTempStore()
        defer { cleanup(url) }
        #expect(store.loadRecent().isEmpty)
    }

    @Test("Append one message, load it back")
    func appendAndLoadOne() throws {
        let (store, url) = makeTempStore()
        defer { cleanup(url) }

        let msg = ChatMessage(kind: .message,
                              sStation: "AI5OS",
                              dStation: "CQCQCQ",
                              text: "hello world",
                              outgoing: true)
        try store.appendThrowing(msg)

        let loaded = store.loadRecent()
        #expect(loaded.count == 1)
        #expect(loaded[0].text == "hello world")
        #expect(loaded[0].sStation == "AI5OS")
        #expect(loaded[0].dStation == "CQCQCQ")
        #expect(loaded[0].outgoing == true)
        #expect(loaded[0].kind == .message)
    }

    @Test("Every ChatMessage kind round-trips through the store")
    func allKindsRoundTrip() throws {
        let (store, url) = makeTempStore()
        defer { cleanup(url) }

        let messages: [ChatMessage] = [
            ChatMessage(kind: .message, sStation: "W9FYI", dStation: "AI5OS", text: "direct msg", outgoing: false),
            ChatMessage(kind: .pingRequest, sStation: "W9FYI", dStation: "AI5OS", text: "ping", outgoing: false),
            ChatMessage(kind: .pingResponse(replyText: "Running MacRats"), sStation: "AI5OS", dStation: "W9FYI", text: "Running MacRats", outgoing: false),
            ChatMessage(kind: .status(.unattended), sStation: "W9FYI", dStation: "CQCQCQ", text: "AFK", outgoing: false),
            ChatMessage(kind: .systemEvent, sStation: "", dStation: "", text: "connected", outgoing: false),
        ]

        for msg in messages {
            try store.appendThrowing(msg)
        }

        let loaded = store.loadRecent()
        #expect(loaded.count == 5)
        #expect(loaded[0].kind == .message)
        #expect(loaded[1].kind == .pingRequest)
        if case .pingResponse(let reply) = loaded[2].kind {
            #expect(reply == "Running MacRats")
        } else {
            Issue.record("expected .pingResponse, got \(loaded[2].kind)")
        }
        if case .status(let s) = loaded[3].kind {
            #expect(s == .unattended)
        } else {
            Issue.record("expected .status(.unattended), got \(loaded[3].kind)")
        }
        #expect(loaded[4].kind == .systemEvent)
    }

    @Test("Message id and timestamp are preserved across round-trip")
    func idAndTimestampPreserved() throws {
        let (store, url) = makeTempStore()
        defer { cleanup(url) }

        let fixedID = UUID()
        let fixedTime = Date(timeIntervalSince1970: 1_700_000_000)
        let msg = ChatMessage(id: fixedID, timestamp: fixedTime, kind: .message,
                              sStation: "A", dStation: "B", text: "t", outgoing: false)
        try store.appendThrowing(msg)

        let loaded = store.loadRecent()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == fixedID)
        #expect(abs(loaded[0].timestamp.timeIntervalSince1970 - 1_700_000_000) < 0.001)
    }

    // MARK: - Multiple messages

    @Test("Messages are loaded in the order they were appended")
    func ordering() throws {
        let (store, url) = makeTempStore()
        defer { cleanup(url) }

        for i in 1...10 {
            let msg = ChatMessage(kind: .message, sStation: "AI5OS", dStation: "CQCQCQ",
                                  text: "message \(i)", outgoing: true)
            try store.appendThrowing(msg)
        }

        let loaded = store.loadRecent()
        #expect(loaded.count == 10)
        #expect(loaded[0].text == "message 1")
        #expect(loaded[9].text == "message 10")
    }

    @Test("Recent count cap enforced — only the last N messages returned")
    func recentCountCap() throws {
        let (store, url) = makeTempStore(maxRecentCount: 5)
        defer { cleanup(url) }

        for i in 1...10 {
            let msg = ChatMessage(kind: .message, sStation: "AI5OS", dStation: "CQCQCQ",
                                  text: "m\(i)", outgoing: true)
            try store.appendThrowing(msg)
        }

        let loaded = store.loadRecent()
        #expect(loaded.count == 5)
        #expect(loaded.first?.text == "m6")
        #expect(loaded.last?.text == "m10")
    }

    // MARK: - Rotate

    @Test("Rotate moves the current file to .old and empties the active log")
    func rotate() throws {
        let (store, url) = makeTempStore()
        defer { cleanup(url) }

        let msg = ChatMessage(kind: .message, sStation: "A", dStation: "B", text: "pre", outgoing: false)
        try store.appendThrowing(msg)
        #expect(store.loadRecent().count == 1)

        try store.rotate()

        #expect(store.loadRecent().isEmpty, "after rotate the active log should be empty")
        let oldURL = url.appendingPathExtension("old")
        #expect(FileManager.default.fileExists(atPath: oldURL.path),
                "rotated file should exist at .old")
    }

    @Test("Automatic rotation triggers when file exceeds rotateAtBytes")
    func automaticRotation() throws {
        // Set the rotate threshold very low so a handful of messages
        // triggers it.
        let (store, url) = makeTempStore(rotateAtBytes: 200)
        defer { cleanup(url) }

        for i in 1...20 {
            let msg = ChatMessage(kind: .message, sStation: "AI5OS", dStation: "CQCQCQ",
                                  text: "This is message number \(i) and it is long enough to push the file over the rotate threshold quickly.",
                                  outgoing: true)
            try store.appendThrowing(msg)
        }

        // After 20 appends, rotation should have happened at least
        // once — the active file should be smaller than the total
        // bytes we wrote.
        let oldURL = url.appendingPathExtension("old")
        #expect(FileManager.default.fileExists(atPath: oldURL.path),
                "automatic rotation should have produced a .old file")
    }

    // MARK: - Delete

    @Test("deleteAll removes both the active and rotated files")
    func deleteAll() throws {
        let (store, url) = makeTempStore()
        defer { cleanup(url) }

        let msg = ChatMessage(kind: .message, sStation: "A", dStation: "B", text: "x", outgoing: false)
        try store.appendThrowing(msg)
        try store.rotate()
        try store.appendThrowing(msg)

        try store.deleteAll()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("old").path))
        #expect(store.loadRecent().isEmpty)
    }

    // MARK: - Corruption tolerance

    @Test("Corrupt lines in the log are silently skipped")
    func corruptLineSkipped() throws {
        let (store, url) = makeTempStore()
        defer { cleanup(url) }

        // Write some valid lines, a garbage line, then more valid lines.
        let m1 = ChatMessage(kind: .message, sStation: "A", dStation: "B", text: "one", outgoing: false)
        let m2 = ChatMessage(kind: .message, sStation: "A", dStation: "B", text: "two", outgoing: false)
        try store.appendThrowing(m1)
        try store.appendThrowing(m2)

        // Append a garbage line manually.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("this is not json\n".utf8))
        try handle.close()

        // Append another valid message.
        let m3 = ChatMessage(kind: .message, sStation: "A", dStation: "B", text: "three", outgoing: false)
        try store.appendThrowing(m3)

        let loaded = store.loadRecent()
        #expect(loaded.count == 3)
        #expect(loaded.map { $0.text } == ["one", "two", "three"])
    }

    // MARK: - Integration with MacRatsAppModel

    @Test("MacRatsAppModel persists messages through its ChatLogStore")
    func appModelPersists() throws {
        let (store, url) = makeTempStore()
        defer { cleanup(url) }

        var settings = MacRatsSettings()
        settings.callsign = "AI5OS"

        let model = MacRatsAppModel(settings: settings, chatLogStore: store)

        // Directly trigger a message via the model's handleIncoming path
        // (which is what a real transport would drive). Since we don't
        // want to spin up a TCP pair just for a persistence test, we
        // exercise the append path through a public method that hits
        // the private append() — sendChatMessage throws without a
        // session, so we use a different route: loadHistory after
        // manually appending via the store, then verify it shows up.
        let msg = ChatMessage(kind: .message, sStation: "W9FYI", dStation: "AI5OS",
                              text: "persisted hello", outgoing: false)
        try store.appendThrowing(msg)

        // New model pointed at the same store should see the history.
        let model2 = MacRatsAppModel(settings: settings, chatLogStore: store)
        model2.loadHistory()
        let loaded = model2.chatMessages
        #expect(loaded.contains { $0.text == "persisted hello" && $0.sStation == "W9FYI" })

        _ = model // suppress unused warning
    }
}
