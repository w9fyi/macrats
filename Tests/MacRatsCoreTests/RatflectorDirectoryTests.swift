import Foundation
import Testing
@testable import MacRatsCore

/// Tests for `RatflectorDirectory` — the YAML parser for the public
/// ratflector list maintained at `ham-radio-software/ratflectors`.
///
/// All tests parse fixed strings that match the real
/// `ratflectors.yml` format exactly. No network I/O here — the
/// `fetch()` path is integration-test territory.
struct RatflectorDirectoryTests {

    // MARK: - Real-file fixture

    /// Captured verbatim from
    /// `https://raw.githubusercontent.com/ham-radio-software/ratflectors/master/ratflectors.yml`
    /// on 2026-04-07. If the upstream file drifts, update this
    /// fixture and add a regression note.
    static let realFixture = """
    ---
    ratflectors:
      - name: ae5he
        description: 'El Paso, Texas'
        hostname: ae5he.ham-radio-op.net
        port: 9000
        active: true
      - name: k3pdr
        description: Philadelphia Digital Radio Association
        hostname: k3pdr.dstargateway.org
        port: 9000
        active: true
      - name: sewx
        description: Southeastern Weather Net
        hostname: sewx.ratflector.com
        port: 9000
        active: true
      - name: StTammany
        description: St Tammany Louisiana
        hostname: sttammany.ratflector.com
        port: 9000
        active: true
      - name: pldares
        description: Paulding County ARES West Metro Atlanta
        hostname: pldares.ratflector.com
        port: 9000
        active: true
      - name: gaares
        description: Georgia ARES
        hostname: gaares.ratflector.com
        port: 9000
        active: true
      - name: gwinnettares
        description: Gwinnett County ARES NE Metro Atlanta
        hostname: gwinnettares.ratflector.com
        port: 9000
        active: true
    """

    @Test("Real upstream ratflectors.yml parses to 7 entries")
    func realFixtureParsesToSevenEntries() throws {
        let entries = try RatflectorDirectory.parse(Self.realFixture)
        #expect(entries.count == 7)
    }

    @Test("Real fixture entries have the expected names in order")
    func realFixtureNames() throws {
        let entries = try RatflectorDirectory.parse(Self.realFixture)
        #expect(entries.map { $0.name } == [
            "ae5he", "k3pdr", "sewx", "StTammany",
            "pldares", "gaares", "gwinnettares"
        ])
    }

    @Test("Quoted description is unquoted in the parsed entry")
    func quotedDescription() throws {
        let entries = try RatflectorDirectory.parse(Self.realFixture)
        guard let ae5he = entries.first(where: { $0.name == "ae5he" }) else {
            Issue.record("no ae5he entry")
            return
        }
        #expect(ae5he.description == "El Paso, Texas")
    }

    @Test("All real entries are active and on port 9000")
    func allRealEntriesActiveOn9000() throws {
        let entries = try RatflectorDirectory.parse(Self.realFixture)
        #expect(entries.allSatisfy { $0.active })
        #expect(entries.allSatisfy { $0.port == 9000 })
    }

    @Test("Entry.displayLabel combines name, description, and hostname")
    func displayLabelFormat() throws {
        let entries = try RatflectorDirectory.parse(Self.realFixture)
        guard let sewx = entries.first(where: { $0.name == "sewx" }) else {
            Issue.record("no sewx entry")
            return
        }
        #expect(sewx.displayLabel == "sewx — Southeastern Weather Net (sewx.ratflector.com)")
    }

    // MARK: - Edge cases

    @Test("Empty input throws noEntries")
    func emptyInputThrows() {
        #expect(throws: RatflectorDirectory.FetchError.self) {
            _ = try RatflectorDirectory.parse("")
        }
    }

    @Test("YAML with only the header throws noEntries")
    func headerOnlyThrows() {
        let text = """
        ---
        ratflectors:
        """
        #expect(throws: RatflectorDirectory.FetchError.self) {
            _ = try RatflectorDirectory.parse(text)
        }
    }

    @Test("Single-entry minimal input parses")
    func singleEntry() throws {
        let text = """
        ---
        ratflectors:
          - name: test
            description: Test
            hostname: test.example.com
            port: 9000
            active: true
        """
        let entries = try RatflectorDirectory.parse(text)
        #expect(entries.count == 1)
        #expect(entries[0].hostname == "test.example.com")
    }

    @Test("Missing port defaults to 9000")
    func portDefaults() throws {
        let text = """
        ---
        ratflectors:
          - name: noport
            description: No Port
            hostname: noport.example.com
            active: true
        """
        let entries = try RatflectorDirectory.parse(text)
        #expect(entries.count == 1)
        #expect(entries[0].port == 9000)
    }

    @Test("Missing active defaults to true")
    func activeDefaults() throws {
        let text = """
        ---
        ratflectors:
          - name: noactive
            description: No Active
            hostname: noactive.example.com
            port: 9000
        """
        let entries = try RatflectorDirectory.parse(text)
        #expect(entries.count == 1)
        #expect(entries[0].active == true)
    }

    @Test("'active: false' is parsed as false")
    func inactiveEntry() throws {
        let text = """
        ---
        ratflectors:
          - name: dead
            description: Dead Ratflector
            hostname: dead.example.com
            port: 9000
            active: false
        """
        let entries = try RatflectorDirectory.parse(text)
        #expect(entries.count == 1)
        #expect(entries[0].active == false)
    }

    @Test("Double-quoted strings are unquoted")
    func doubleQuotedStrings() throws {
        let text = """
        ---
        ratflectors:
          - name: "quoted"
            description: "Quoted Description"
            hostname: "quoted.example.com"
            port: 9000
            active: true
        """
        let entries = try RatflectorDirectory.parse(text)
        #expect(entries.count == 1)
        #expect(entries[0].name == "quoted")
        #expect(entries[0].description == "Quoted Description")
    }

    @Test("Entry missing required name is dropped")
    func missingNameDropped() throws {
        let text = """
        ---
        ratflectors:
          - description: No Name
            hostname: nameless.example.com
            port: 9000
            active: true
          - name: valid
            description: Valid
            hostname: valid.example.com
            port: 9000
            active: true
        """
        let entries = try RatflectorDirectory.parse(text)
        #expect(entries.count == 1)
        #expect(entries[0].name == "valid")
    }

    @Test("Comments are ignored")
    func commentsIgnored() throws {
        let text = """
        ---
        # This is a comment
        ratflectors:
          # Another comment
          - name: commented
            description: Comments work
            hostname: commented.example.com
            port: 9000
            active: true
        """
        let entries = try RatflectorDirectory.parse(text)
        #expect(entries.count == 1)
    }
}
