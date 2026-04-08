import Foundation

/// A single station we've heard on the air (or over the ratflector).
/// Accumulates in `HeardStationTracker` and drives the StationsView in
/// the MacRats UI.
public struct HeardStation: Identifiable, Equatable, Sendable {

    public let callsign: String
    public var lastHeard: Date
    public var lastStatus: StationStatus
    public var lastStatusMessage: String
    public var messageCount: Int
    public var pingCount: Int

    /// Last known latitude in decimal degrees, from a `$$CRC` GPS beacon.
    /// Nil until the station sends a position fix.
    public var lastLatitude: Double?
    /// Last known longitude in decimal degrees.
    public var lastLongitude: Double?
    /// Last comment broadcast alongside a GPS fix.
    public var lastGPSComment: String

    public var id: String { callsign }

    public init(callsign: String,
                lastHeard: Date = Date(),
                lastStatus: StationStatus = .unknown,
                lastStatusMessage: String = "",
                messageCount: Int = 0,
                pingCount: Int = 0,
                lastLatitude: Double? = nil,
                lastLongitude: Double? = nil,
                lastGPSComment: String = "") {
        self.callsign = callsign
        self.lastHeard = lastHeard
        self.lastStatus = lastStatus
        self.lastStatusMessage = lastStatusMessage
        self.messageCount = messageCount
        self.pingCount = pingCount
        self.lastLatitude = lastLatitude
        self.lastLongitude = lastLongitude
        self.lastGPSComment = lastGPSComment
    }
}

/// Thread-safe tracker of heard stations. `MacRatsAppModel` feeds every
/// inbound frame into this tracker via `note(from:)` and related methods.
/// SwiftUI views read the sorted snapshot via `sortedSnapshot()`.
public final class HeardStationTracker: @unchecked Sendable {

    private let lock = NSLock()
    private var stations: [String: HeardStation] = [:]

    /// Optional minimum age — stations older than this are filtered out
    /// of the snapshot. Nil = no filtering. Matches D-Rats's "Station
    /// TTL" concept.
    public var maxAge: TimeInterval?

    public init(maxAge: TimeInterval? = nil) {
        self.maxAge = maxAge
    }

    // MARK: - Mutation

    /// Note that we heard `callsign` at the current time. Called for
    /// every inbound frame regardless of type.
    public func note(from callsign: String) {
        guard !callsign.isEmpty, callsign != "CQCQCQ" else { return }
        lock.lock()
        defer { lock.unlock() }
        if var existing = stations[callsign] {
            existing.lastHeard = Date()
            stations[callsign] = existing
        } else {
            stations[callsign] = HeardStation(callsign: callsign)
        }
    }

    /// Note a chat message from `callsign`. Increments messageCount.
    public func noteMessage(from callsign: String) {
        guard !callsign.isEmpty, callsign != "CQCQCQ" else { return }
        lock.lock()
        defer { lock.unlock() }
        var station = stations[callsign] ?? HeardStation(callsign: callsign)
        station.lastHeard = Date()
        station.messageCount += 1
        stations[callsign] = station
    }

    /// Note a ping request/response from `callsign`. Increments pingCount.
    public func notePing(from callsign: String) {
        guard !callsign.isEmpty, callsign != "CQCQCQ" else { return }
        lock.lock()
        defer { lock.unlock() }
        var station = stations[callsign] ?? HeardStation(callsign: callsign)
        station.lastHeard = Date()
        station.pingCount += 1
        stations[callsign] = station
    }

    /// Note a status update from `callsign`.
    public func noteStatus(from callsign: String, status: StationStatus, message: String) {
        guard !callsign.isEmpty, callsign != "CQCQCQ" else { return }
        lock.lock()
        defer { lock.unlock() }
        var station = stations[callsign] ?? HeardStation(callsign: callsign)
        station.lastHeard = Date()
        station.lastStatus = status
        station.lastStatusMessage = message
        stations[callsign] = station
    }

    /// Note a GPS position fix from `callsign`. Updates the cached
    /// latitude / longitude / comment and bumps lastHeard.
    public func noteGPSFix(from callsign: String,
                           latitude: Double,
                           longitude: Double,
                           comment: String) {
        guard !callsign.isEmpty, callsign != "CQCQCQ" else { return }
        lock.lock()
        defer { lock.unlock() }
        var station = stations[callsign] ?? HeardStation(callsign: callsign)
        station.lastHeard = Date()
        station.lastLatitude = latitude
        station.lastLongitude = longitude
        station.lastGPSComment = comment
        stations[callsign] = station
    }

    /// Drop a station from the list manually.
    public func forget(_ callsign: String) {
        lock.lock()
        defer { lock.unlock() }
        stations.removeValue(forKey: callsign)
    }

    /// Drop all stations.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        stations.removeAll()
    }

    // MARK: - Snapshots

    /// Return a snapshot sorted by most recently heard first. Stations
    /// older than `maxAge` (if set) are filtered out.
    public func sortedSnapshot() -> [HeardStation] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        var values = Array(stations.values)
        if let maxAge {
            values = values.filter { now.timeIntervalSince($0.lastHeard) <= maxAge }
        }
        values.sort { $0.lastHeard > $1.lastHeard }
        return values
    }

    /// Count of currently-tracked stations.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stations.count
    }
}
