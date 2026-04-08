import SwiftUI
import MacRatsCore

/// The main chat conversation view. Shows the running chat log, an
/// input field with destination selector, and a live announcement of
/// notice-matched messages via VoiceOver.
///
/// Accessibility-first details:
///
/// - Every chat row has an explicit `accessibilityLabel` containing
///   the full semantics: timestamp, from, to, kind, text. VoiceOver
///   users hear one complete sentence per focused row, not a loose
///   concatenation.
/// - The input field autofocuses on view appear and is always
///   keyboard-reachable.
/// - Notice-regex matches fire a post-notification via
///   `NSAccessibility.post(element:notification:)` so VoiceOver
///   announces the message without requiring focus to land on it.
/// - The "Show status updates" setting is honored: when off, `.status`
///   messages are hidden from the view.
struct ChatView: View {
    @EnvironmentObject private var store: MacRatsStore

    /// Optional station that's currently selected in the sidebar. When
    /// set, the input defaults to sending direct messages to this
    /// callsign rather than broadcasting CQCQCQ.
    var pingTarget: String?

    @State private var draft: String = ""
    @State private var destination: String = "CQCQCQ"
    @State private var lastAnnouncedMessageID: UUID?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            chatScrollView
            Divider()
            composer
        }
        .navigationTitle("Chat")
        .onChange(of: pingTarget) { _, newTarget in
            destination = newTarget ?? "CQCQCQ"
        }
        .onChange(of: store.chatMessages) { _, newMessages in
            announceNoticeIfNeeded(messages: newMessages)
        }
        .onAppear {
            inputFocused = true
        }
    }

    // MARK: - Chat scroll view

    @ViewBuilder
    private var chatScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleMessages) { message in
                        ChatRow(message: message,
                                noticeRegex: store.settings.noticeRegex,
                                ignoreRegex: store.settings.ignoreRegex,
                                myCallsign: store.settings.callsign)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: store.chatMessages.last?.id) { _, newLastID in
                if let newLastID {
                    withAnimation {
                        proxy.scrollTo(newLastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var visibleMessages: [ChatMessage] {
        if store.settings.showStatusUpdatesInChat {
            return store.chatMessages
        }
        return store.chatMessages.filter { !$0.isStatusUpdate }
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Destination", text: $destination)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
                .accessibilityLabel("Destination callsign, defaults to CQCQCQ for broadcast")
                .autocorrectionDisabled()

            TextField("Type a message and press Return", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Chat message")
                .accessibilityHint("Type your message. Press Return to send.")
                .focused($inputFocused)
                .onSubmit(send)

            Button("Send") {
                send()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(store.connectionStatus != .connected
                      || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send message to \(destination.isEmpty ? "CQCQCQ" : destination)")
        }
        .padding(10)
    }

    // MARK: - Send action

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dest = destination.trimmingCharacters(in: .whitespaces).isEmpty
            ? "CQCQCQ"
            : destination.uppercased()
        store.sendChatMessage(trimmed, to: dest)
        draft = ""
        inputFocused = true
    }

    // MARK: - Notice announcements

    /// Check whether a newly-arrived message matches the user's notice
    /// regex. If so, fire a VoiceOver announcement so the user hears
    /// the message without needing focus to land on the row.
    private func announceNoticeIfNeeded(messages: [ChatMessage]) {
        guard let latest = messages.last else { return }
        if latest.id == lastAnnouncedMessageID { return }
        lastAnnouncedMessageID = latest.id
        guard !latest.outgoing else { return }

        let noticePattern = store.settings.noticeRegex
        guard !noticePattern.isEmpty else { return }
        guard latest.matches(regex: noticePattern) else { return }

        let announcement = "\(latest.sStation) mentioned you: \(latest.text)"
        AccessibilityAnnouncer.announce(announcement)
    }
}

/// Single chat row. Timestamp + sender + arrow + text. The whole row
/// is exposed to VoiceOver as one combined label — users should hear
/// the full context with a single focus event.
struct ChatRow: View {
    let message: ChatMessage
    let noticeRegex: String
    let ignoreRegex: String
    let myCallsign: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timestamp)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                header
                if !bodyText.isEmpty {
                    Text(bodyText)
                        .font(.system(.body, design: .default))
                        .foregroundStyle(isIgnored ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(isNotice ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var timestamp: String {
        Self.timeFormatter.string(from: message.timestamp)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 4) {
            Text(prefix)
                .font(.caption.bold())
                .foregroundStyle(headerColor)
        }
    }

    private var prefix: String {
        switch message.kind {
        case .message:
            if message.outgoing {
                return "You → \(message.dStation)"
            } else {
                return "\(message.sStation) → \(message.dStation)"
            }
        case .pingRequest:
            return message.outgoing
                ? "Ping → \(message.dStation)"
                : "Ping from \(message.sStation)"
        case .pingResponse:
            return "Ping reply from \(message.sStation)"
        case .status(let s):
            return "\(message.sStation) status: \(s.description)"
        case .systemEvent:
            return "MacRats"
        case .gpsFix(let lat, let lon):
            let latStr = String(format: "%.4f", lat)
            let lonStr = String(format: "%.4f", lon)
            let who = message.outgoing ? "Your position" : "\(message.sStation) position"
            return "\(who) \(latStr), \(lonStr)"
        }
    }

    private var bodyText: String {
        switch message.kind {
        case .pingRequest:
            return ""
        default:
            return message.text
        }
    }

    private var headerColor: Color {
        switch message.kind {
        case .message:     return .primary
        case .pingRequest: return .orange
        case .pingResponse: return .blue
        case .status:      return .purple
        case .systemEvent: return .secondary
        case .gpsFix:      return .green
        }
    }

    // MARK: - Filter state

    private var isNotice: Bool {
        guard !noticeRegex.isEmpty else { return false }
        return message.matches(regex: noticeRegex)
    }

    private var isIgnored: Bool {
        guard !ignoreRegex.isEmpty else { return false }
        return message.matches(regex: ignoreRegex)
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        let timeString = Self.accessibilityTimeFormatter.string(from: message.timestamp)
        var parts: [String] = [timeString]
        switch message.kind {
        case .message:
            if message.outgoing {
                parts.append("You sent to \(message.dStation): \(message.text)")
            } else {
                parts.append("\(message.sStation) to \(message.dStation): \(message.text)")
            }
        case .pingRequest:
            if message.outgoing {
                parts.append("You pinged \(message.dStation)")
            } else {
                parts.append("Ping request from \(message.sStation) to \(message.dStation)")
            }
        case .pingResponse(let replyText):
            parts.append("Ping reply from \(message.sStation): \(replyText)")
        case .status(let status):
            parts.append("\(message.sStation) is now \(status.description)")
            if !message.text.isEmpty {
                parts.append("Message: \(message.text)")
            }
        case .systemEvent:
            parts.append("MacRats: \(message.text)")
        case .gpsFix(let lat, let lon):
            let latStr = String(format: "%.4f", lat)
            let lonStr = String(format: "%.4f", lon)
            if message.outgoing {
                parts.append("You broadcast your position: \(latStr), \(lonStr)")
            } else {
                parts.append("\(message.sStation) position fix: \(latStr), \(lonStr)")
            }
            if !message.text.isEmpty && message.text != "Position fix" {
                parts.append("Comment: \(message.text)")
            }
        }
        if isNotice {
            parts.append("(mentions you)")
        }
        return parts.joined(separator: ", ")
    }

    private static let accessibilityTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()
}
