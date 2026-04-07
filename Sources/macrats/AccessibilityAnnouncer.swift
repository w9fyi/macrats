import AppKit

/// Thin wrapper around `NSAccessibility.post(element:notification:userInfo:)`
/// to fire a VoiceOver announcement without requiring focus to land on a
/// specific element. This is the macOS equivalent of an ARIA live
/// region — we use it to announce new notice-matched chat messages.
///
/// Keeping this in its own file means other views (debug log, ping
/// replies, connection state changes) can reuse the same pattern as
/// MacRats grows.
@MainActor
enum AccessibilityAnnouncer {
    /// Announce `message` to VoiceOver if it's running. Silent no-op
    /// when VoiceOver isn't enabled. Must be called from the main
    /// actor because it touches `NSApp`.
    static func announce(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ]
        // Post against the shared application element — VoiceOver
        // reads the announcement without moving focus.
        NSAccessibility.post(element: NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: userInfo)
    }
}
