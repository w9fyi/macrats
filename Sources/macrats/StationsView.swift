import SwiftUI
import MacRatsCore

/// Sidebar list of heard stations. Mirrors D-Rats's `ui/main_stations.py`
/// — callsign, last heard timestamp, last status + message. Accessibility
/// labels are the single most important thing about this view:
/// VoiceOver users must be able to understand the full state of each
/// station from a single focus-and-read.
struct StationsView: View {
    @EnvironmentObject private var store: MacRatsStore

    /// Bound from `MainView` so the toolbar's "Ping Selected" action
    /// knows which station the user has focused.
    @Binding var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                if store.heardStations.isEmpty {
                    Text("No stations heard yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No stations have been heard yet. Connect to hear stations on the air.")
                } else {
                    ForEach(store.heardStations) { station in
                        StationRow(station: station)
                            .tag(station.id)
                            .accessibilityLabel(Self.accessibilityLabel(for: station))
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Text("\(store.heardStations.count) station\(store.heardStations.count == 1 ? "" : "s") heard")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(store.heardStations.count) station\(store.heardStations.count == 1 ? "" : "s") currently heard")
        }
        .navigationTitle("Stations")
    }

    /// Build a VoiceOver label that reads the full station context in
    /// one sentence — so a screen reader user knows everything about a
    /// station by landing on its row.
    static func accessibilityLabel(for station: HeardStation) -> String {
        let timeAgo = Self.relativeTime(since: station.lastHeard)
        var parts = ["\(station.callsign), last heard \(timeAgo)"]
        if station.lastStatus != .unknown {
            parts.append("status \(station.lastStatus.description)")
        }
        if !station.lastStatusMessage.isEmpty {
            parts.append(station.lastStatusMessage)
        }
        if station.messageCount > 0 {
            parts.append("\(station.messageCount) message\(station.messageCount == 1 ? "" : "s")")
        }
        if let lat = station.lastLatitude, let lon = station.lastLongitude {
            let latStr = String(format: "%.4f", lat)
            let lonStr = String(format: "%.4f", lon)
            parts.append("position \(latStr), \(lonStr)")
            if !station.lastGPSComment.isEmpty {
                parts.append(station.lastGPSComment)
            }
        }
        return parts.joined(separator: ", ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relativeTime(since date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

/// A single row in the stations list. Designed for quick visual scanning
/// AND clear VoiceOver output — the accessibility label on this view's
/// parent in StationsView overrides the default concatenation.
struct StationRow: View {
    let station: HeardStation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(station.callsign)
                    .font(.system(.body, design: .monospaced).bold())
                Spacer()
                Text(StationsView.relativeTime(since: station.lastHeard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if station.lastStatus != .unknown || !station.lastStatusMessage.isEmpty {
                HStack(spacing: 4) {
                    if station.lastStatus != .unknown {
                        Text(station.lastStatus.description)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(statusColor.opacity(0.25))
                            .foregroundStyle(statusColor)
                            .clipShape(Capsule())
                    }
                    if !station.lastStatusMessage.isEmpty {
                        Text(station.lastStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if let lat = station.lastLatitude, let lon = station.lastLongitude {
                let latStr = String(format: "%.4f", lat)
                let lonStr = String(format: "%.4f", lon)
                Text("\(latStr), \(lonStr)\(station.lastGPSComment.isEmpty ? "" : " — \(station.lastGPSComment)")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch station.lastStatus {
        case .online:      return .green
        case .unattended:  return .orange
        case .offline:     return .red
        case .unknown:     return .gray
        }
    }
}
