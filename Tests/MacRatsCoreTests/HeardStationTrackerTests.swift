import Foundation
import Testing
@testable import MacRatsCore

struct HeardStationTrackerTests {

    @Test("Tracker starts empty")
    func emptyTracker() {
        let tracker = HeardStationTracker()
        #expect(tracker.count == 0)
        #expect(tracker.sortedSnapshot().isEmpty)
    }

    @Test("note(from:) creates a new station entry")
    func noteCreatesEntry() {
        let tracker = HeardStationTracker()
        tracker.note(from: "AI5OS")
        #expect(tracker.count == 1)
        let snapshot = tracker.sortedSnapshot()
        #expect(snapshot.first?.callsign == "AI5OS")
        #expect(snapshot.first?.messageCount == 0)
    }

    @Test("CQCQCQ is never tracked as a station")
    func cqcqcqIgnored() {
        let tracker = HeardStationTracker()
        tracker.note(from: "CQCQCQ")
        tracker.noteMessage(from: "CQCQCQ")
        tracker.notePing(from: "CQCQCQ")
        #expect(tracker.count == 0)
    }

    @Test("Empty callsign is never tracked")
    func emptyIgnored() {
        let tracker = HeardStationTracker()
        tracker.note(from: "")
        tracker.noteMessage(from: "")
        #expect(tracker.count == 0)
    }

    @Test("noteMessage increments messageCount")
    func messageCountIncrements() {
        let tracker = HeardStationTracker()
        tracker.noteMessage(from: "AI5OS")
        tracker.noteMessage(from: "AI5OS")
        tracker.noteMessage(from: "AI5OS")
        let snapshot = tracker.sortedSnapshot()
        #expect(snapshot.first?.messageCount == 3)
    }

    @Test("notePing increments pingCount")
    func pingCountIncrements() {
        let tracker = HeardStationTracker()
        tracker.notePing(from: "W9FYI")
        tracker.notePing(from: "W9FYI")
        let snapshot = tracker.sortedSnapshot()
        #expect(snapshot.first?.pingCount == 2)
    }

    @Test("noteStatus stores status and message")
    func statusCaptured() {
        let tracker = HeardStationTracker()
        tracker.noteStatus(from: "AI5OS", status: .unattended, message: "At work")
        let snapshot = tracker.sortedSnapshot()
        #expect(snapshot.first?.lastStatus == .unattended)
        #expect(snapshot.first?.lastStatusMessage == "At work")
    }

    @Test("Sorted snapshot puts most recently heard first")
    func sortedByRecency() {
        let tracker = HeardStationTracker()
        tracker.note(from: "OLD1")
        Thread.sleep(forTimeInterval: 0.02)
        tracker.note(from: "OLD2")
        Thread.sleep(forTimeInterval: 0.02)
        tracker.note(from: "NEW")
        let snapshot = tracker.sortedSnapshot()
        #expect(snapshot.count == 3)
        #expect(snapshot[0].callsign == "NEW")
        #expect(snapshot[2].callsign == "OLD1")
    }

    @Test("forget removes a station")
    func forget() {
        let tracker = HeardStationTracker()
        tracker.note(from: "AI5OS")
        tracker.note(from: "W9FYI")
        tracker.forget("AI5OS")
        #expect(tracker.count == 1)
        #expect(tracker.sortedSnapshot().first?.callsign == "W9FYI")
    }

    @Test("reset clears all stations")
    func reset() {
        let tracker = HeardStationTracker()
        tracker.note(from: "A")
        tracker.note(from: "B")
        tracker.note(from: "C")
        tracker.reset()
        #expect(tracker.count == 0)
    }

    @Test("maxAge filter drops stale stations from the snapshot")
    func maxAgeFilter() {
        let tracker = HeardStationTracker(maxAge: 0.05) // 50ms
        tracker.note(from: "OLDSTATION")
        Thread.sleep(forTimeInterval: 0.2) // well past maxAge
        tracker.note(from: "NEWSTATION")
        let snapshot = tracker.sortedSnapshot()
        // Stale station is filtered; fresh one is kept.
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.callsign == "NEWSTATION")
        // Underlying storage still has both — the filter only affects
        // the snapshot.
        #expect(tracker.count == 2)
    }
}
