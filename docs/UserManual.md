# MacRats User Manual

**Version 0.1.0 (Alpha)**

MacRats is a native macOS client for the D-Rats messaging protocol. It speaks
the same on-air bytes as the upstream Python D-Rats application
([ham-radio-software/D-Rats](https://github.com/ham-radio-software/D-Rats)),
but with a SwiftUI interface that is fully accessible to VoiceOver users.

This manual covers installing and using MacRats. For build instructions and
the protocol/architecture deep-dive, see the project [README](../README.md).

---

## Table of contents

1. [What MacRats does](#what-macrats-does)
2. [System requirements](#system-requirements)
3. [Installing](#installing)
4. [First launch and Gatekeeper](#first-launch-and-gatekeeper)
5. [The setup wizard](#the-setup-wizard)
6. [The main window at a glance](#the-main-window-at-a-glance)
7. [Connecting to a ratflector (no radio needed)](#connecting-to-a-ratflector-no-radio-needed)
8. [Connecting to a Kenwood TH-D75 over USB](#connecting-to-a-kenwood-th-d75-over-usb)
9. [Sending and receiving chat messages](#sending-and-receiving-chat-messages)
10. [Pinging another station](#pinging-another-station)
11. [Setting your status](#setting-your-status)
12. [The stations sidebar](#the-stations-sidebar)
13. [Preferences reference](#preferences-reference)
14. [Keyboard shortcuts](#keyboard-shortcuts)
15. [VoiceOver tips](#voiceover-tips)
16. [Where MacRats stores its data](#where-macrats-stores-its-data)
17. [Troubleshooting](#troubleshooting)
18. [Known limitations in 0.1.0](#known-limitations-in-010)
19. [Getting help](#getting-help)

---

## What MacRats does

MacRats lets you send short text messages, ping requests, and station-status
announcements between licensed amateur radio stations. Messages can travel
over three different transports:

- **A radio**, currently the Kenwood TH-D75 D-STAR HT, using the radio's
  built-in TNC over USB. Other D-Rats stations on the same simplex frequency
  or D-STAR repeater can hear you.
- **A ratflector**, which is a public D-Rats server on the Internet. No radio
  required. The easiest way to try MacRats and to talk to other D-Rats users
  worldwide.
- **TCP loopback** for testing — two copies of MacRats on the same Mac can
  talk to each other for protocol testing without ever keying a transmitter.

MacRats v0.1.0 implements the chat tab features of D-Rats: text messages,
pings, and station status broadcasts. File transfer, structured forms, the
map view, and Winlink gatewaying are planned for later versions — see
[Known limitations in 0.1.0](#known-limitations-in-010) below.

---

## System requirements

- **macOS 14 (Sonoma) or newer**
- **Apple Silicon or Intel Mac** — MacRats 0.1.0 ships as a universal binary
  and runs natively on both architectures
- **A USB-A or USB-C port** if you plan to connect a TH-D75 directly
- **An amateur radio license** if you plan to actually transmit
- **A network connection** if you plan to use ratflectors

---

## Installing

1. Download `MacRats-v0.1.0.zip` from the
   [GitHub releases page](https://github.com/w9fyi/macrats/releases).
2. Double-click the zip in Finder. macOS will expand `MacRats.app` next to it.
3. Drag `MacRats.app` into your `/Applications` folder.

That's it. MacRats is a single self-contained `.app` bundle with no installer
and no helper processes.

---

## First launch and Gatekeeper

MacRats 0.1.0 is **ad-hoc signed but not notarized**. macOS Gatekeeper does
not recognize the signature, so the first time you double-click `MacRats.app`
you will see one of these messages:

> *"MacRats" cannot be opened because the developer cannot be verified.*

or

> *"MacRats" is damaged and can't be opened. You should move it to the Trash.*

This is expected. To get past it, **right-click (or Control-click)
`MacRats.app` in Finder and choose Open** from the context menu. macOS will
then show a dialog with an **Open** button — click it. After that, MacRats
will launch normally on every subsequent double-click.

If macOS still refuses to open the app, run this once in Terminal to clear
the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/MacRats.app
```

A signed and notarized build is on the roadmap and will eliminate this
friction in a future release.

---

## The setup wizard

The first time MacRats launches, it walks you through a one-page setup
wizard. The wizard collects three things:

1. **Your callsign** — required. Use your FCC (or national-equivalent)
   issued amateur radio callsign. MacRats stamps every outgoing frame with
   this callsign exactly the way upstream D-Rats does.
2. **A short sign-on message** — optional. If set, MacRats automatically
   broadcasts this once when you connect, so other stations on the channel
   know you've arrived. A typical message: `AI5OS QRV from Austin, TX`.
3. **A short sign-off message** — optional. If set, MacRats automatically
   broadcasts this just before you disconnect.

Click **Save and continue** to dismiss the wizard. You can change any of
these later in Preferences (`⌘,`).

If you cancel the wizard, MacRats will show it again on the next launch
until you either save settings or fill them in via Preferences.

---

## The main window at a glance

After setup, MacRats shows its main window:

- **Left sidebar — Stations.** A list of every station MacRats has heard
  recently. Each row shows the callsign and a "last heard" timestamp. The
  list is empty when you first connect.
- **Right pane — Chat.** A scrolling log of every chat message, ping, and
  status broadcast in this session. New messages append to the bottom and
  the view auto-scrolls to follow.
- **Bottom of the chat pane — Compose field.** A single-line text field
  where you type outgoing messages. Press Return to send.
- **Toolbar.** Three controls:
  - **Connect / Disconnect** button (`⌘K`)
  - **Connection status indicator** — red when disconnected, yellow during
    handshake, green when fully connected
  - **My Status** popover button — opens a small popover where you can
    broadcast your current status (online / unattended / offline + a free
    text message)

Every control in the window has an accessible label. VoiceOver users can
navigate the entire interface with Tab, Shift-Tab, and arrow keys without
ever touching the mouse.

---

## Connecting to a ratflector (no radio needed)

A **ratflector** is a public D-Rats server on the Internet that relays
messages between connected clients. This is the easiest way to try MacRats.

1. Open **Preferences** (`⌘,`) and switch to the **Radio** tab.
2. Set **Connection type** to **Ratflector (Internet)**.
3. The **Public ratflector** picker loads a directory of public ratflectors
   automatically the first time you switch to this mode. Click **Refresh**
   to re-fetch the list.
4. Pick a ratflector from the list — MacRats fills in the host and port
   for you. Recommended starting points: `sewx.ratflector.com`,
   `alabama.ratflector.com`.
5. Leave the **Password** field blank unless the operator of a specific
   ratflector has given you one. Most public ratflectors accept anonymous
   connections.
6. Close Preferences and press `⌘K` to connect.

The status indicator should turn green within a second or two. Any messages
you type in the compose field now go to every other user connected to the
same ratflector. Their messages will appear in your chat log and their
callsigns will populate your stations sidebar.

**Important**: ratflector traffic is plaintext TCP — there is no encryption.
Treat it like a public ham radio channel, because functionally it is one.

---

## Connecting to a Kenwood TH-D75 over USB

MacRats 0.1.0 supports the Kenwood TH-D75 D-STAR handheld over USB. Other
radios are not yet supported.

### One-time radio setup

Before MacRats can talk to the TH-D75, you must configure four things on
the radio itself. These settings persist on the radio across power cycles.

1. **Switch the radio to D-STAR DV mode** on the frequency you want to use.
   D-Rats data only works in DV mode, not FM or DV/FM auto.
2. **Enable Data Mode (slow data).** On the TH-D75 this is in the menu under
   *Data Mode*. The radio's busy/data LED behavior changes when this is on.
3. **Set Menu 614 (Data TX End Timing) to `0.5` seconds.** This is the most
   important step. If Menu 614 is set to `Off` (the factory default), the
   TH-D75 silently discards inbound serial bytes when MacRats tries to
   transmit, despite being in Data Mode. **The radio will refuse to key up**
   and you will see no error — just nothing happening on the air. This
   behavior is undocumented in the TH-D75 manual; AI5OS discovered it
   during the MacRats Phase 1 over-the-air test on 2026-04-07. Set Menu 614
   to `0.5` (the lowest non-Off value) and the problem disappears.
4. **(Optional) Switch to MMDVM Terminal Mode via Menu 650** if you want
   MacRats to use the higher-throughput MMDVM framing instead of the
   default. In MMDVM terminal mode the radio's USB serial port runs at
   38400 baud instead of 9600. MacRats auto-detects which mode the radio
   is in.

### Connecting

1. Plug the TH-D75 into your Mac with a USB-C cable. macOS should expose
   it as a `/dev/cu.usbmodem...` device within a second or two.
2. Open MacRats Preferences (`⌘,`) → **Radio** tab.
3. Set **Connection type** to **Kenwood TH-D75 (USB serial)**.
4. The **Serial port** dropdown will list every `/dev/cu.*` device on your
   Mac. Pick the one corresponding to the TH-D75. If you're not sure which
   one is the radio, you can use the bundled `macrats-probe` command-line
   tool from a Terminal — it sends an identification probe and reports
   what's on the other end of each port.
5. Confirm the baud rate matches the radio's mode (9600 for normal CAT,
   38400 for MMDVM Terminal Mode).
6. Close Preferences and press `⌘K` to connect.

When the indicator turns green, MacRats is talking to the radio. Outgoing
messages will key the transmitter. Incoming D-STAR data frames from other
stations will appear in the chat log and stations sidebar.

---

## Sending and receiving chat messages

To send a message: click in the compose field at the bottom of the chat
pane, type your message, and press **Return**. The message appears in your
chat log immediately, marked as outgoing, and is broadcast to all stations
on the channel (or all users on the ratflector).

To send a **direct message** to a specific station — one that other
stations on the channel will see is addressed only to that callsign — type
the message and use the address field in the compose row. Other clients will
display the message but most will ignore it unless their own callsign matches.

Incoming messages from other stations appear in the chat log automatically.
If VoiceOver is running, MacRats also speaks an announcement when a new
message arrives so you don't have to be focused on the chat pane to know
something happened.

---

## Pinging another station

A "ping" is the D-Rats equivalent of "are you there?". You send a ping
addressed to a specific callsign; if that station's D-Rats client is
running and listening, it automatically sends a ping response back. The
round-trip is logged in your chat pane.

To ping a station from the GUI: select the station in the sidebar and
click **Ping**.

To ping from the CLI:

```text
/ping W9FYI
```

(in the `macrats-chat` REPL or as a slash-command in the GUI compose field).

Pings are useful for confirming a path is working before you start a longer
conversation, and as a low-bandwidth way to keep a contact list current.

---

## Setting your status

Your "status" is a one-shot broadcast that tells other stations on the
channel what you're doing right now. D-Rats defines three levels:

- **Online** — at the keyboard, ready to chat
- **Unattended** — connected but not actively reading messages
- **Offline** — leaving / shutting down

You set your status from the **My Status** popover in the toolbar (or via
the `/status` slash-command in the compose field). Each status level can
carry a short free-text message, like `online QRV on 2m` or
`unattended dinner break, back at 1900Z`.

Status broadcasts are not the same thing as the automatic sign-on and
sign-off messages from the setup wizard — those fire once per connection,
status broadcasts can be sent any time.

---

## The stations sidebar

Every callsign MacRats hears (from a chat message, ping, status, or any
other DDT2 frame) appears in the **Stations** sidebar with a "last heard"
timestamp. The list is sorted with the most recently heard station at the
top.

Click a station to:

- **See their last status broadcast** (if any)
- **Send them a direct message**
- **Send them a ping**

Stations age out of the sidebar after a configurable time (default: 24
hours). The age-out value is in Preferences → Stations.

---

## Preferences reference

Open Preferences with `⌘,`. The window has three tabs:

### General tab

- **Callsign** — your amateur radio callsign. Required.
- **Sign-on message** — auto-broadcast on connect. Optional.
- **Sign-off message** — auto-broadcast just before disconnect. Optional.
- **My Status default** — which status level the My Status popover starts
  at when you open it.

### Radio tab

- **Connection type** — Kenwood TH-D75 (USB serial), Ratflector (Internet),
  or TCP loopback (testing).
- For **USB serial**:
  - **Serial port** — picker showing all `/dev/cu.*` devices.
  - **Baud rate** — 9600 for normal CAT, 38400 for MMDVM terminal mode.
  - **Force TX delay** — adds an extra delay before sending each frame to
    accommodate radios with slow PTT relays. Most users can leave at 0.
- For **Ratflector**:
  - **Public ratflector** — picker that loads from the upstream
    `ham-radio-software/ratflectors` directory.
  - **Host** and **Port** — auto-filled when you pick from the list, or
    type your own.
  - **Password** — leave blank for anonymous public ratflectors.
- For **TCP loopback**:
  - **Mode** — server (listen) or client (connect)
  - **Host** and **Port**

### Stations tab

- **Station age-out** — how long a station stays in the sidebar after the
  last time you heard from it. Default 24 hours.

---

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘,`     | Open Preferences |
| `⌘K`     | Connect / Disconnect |
| `⌘N`     | New chat message (focus the compose field) |
| `⌘W`     | Close window |
| `⌘Q`     | Quit MacRats |
| `Tab`    | Move focus to next control |
| `⇧Tab`   | Move focus to previous control |
| `Return` | Send the message in the compose field |
| `Esc`    | Close popover or sheet |

---

## VoiceOver tips

MacRats was built accessibility-first. Every control has a meaningful
accessible label, every list row reads as a single sentence, and live-region
announcements fire when something interesting happens (new message, ping
reply, connection state change).

A few habits that work well:

- **Use Tab and Shift-Tab to move through the toolbar and main panes**
  rather than VoiceOver-cursor navigation. The keyboard focus order is
  designed to match the order you'd want to act in.
- **The compose field auto-focuses when you open the main window** so you
  can start typing immediately after pressing `⌘K` to connect.
- **Live-region announcements use the polite priority** so they don't
  interrupt whatever VoiceOver is currently reading. You'll hear them at
  the next natural pause.
- **The Stations sidebar reads as a list** with one row per station. Each
  row says the callsign first and the last-heard relative time second.
- **Preferences sheet is fully keyboard-navigable.** Tab cycles through
  every control in the visible tab. Use the segment control at the top of
  the sheet to switch tabs.

If you find a control that doesn't read sensibly with VoiceOver, please
file an issue at <https://github.com/w9fyi/macrats/issues> — accessibility
regressions are treated as bugs, not feature requests.

---

## Where MacRats stores its data

| What | Where |
|------|-------|
| Settings (callsign, transport, etc.) | `~/Library/Application Support/MacRats/settings.json` |
| Chat log (NDJSON, auto-rotates at 10 MB) | `~/Library/Application Support/MacRats/chat.log.jsonl` |
| Cached ratflector directory | `~/Library/Application Support/MacRats/ratflectors.json` |

Delete the entire `~/Library/Application Support/MacRats/` folder to reset
MacRats to a fresh-install state. The setup wizard will appear again on
the next launch.

---

## Troubleshooting

### "MacRats cannot be opened because the developer cannot be verified"
See [First launch and Gatekeeper](#first-launch-and-gatekeeper) above.
Right-click → Open, or `xattr -dr com.apple.quarantine /Applications/MacRats.app`.

### Connect button does nothing / status indicator stays red
Check Preferences → Radio:

- For **USB serial**, make sure the right `/dev/cu.*` is selected and the
  radio is plugged in. Run `ls /dev/cu.*` in Terminal to confirm the radio
  shows up. The TH-D75 typically appears as `/dev/cu.usbmodem20112xx`.
- For **Ratflector**, make sure your Mac has Internet, the host is spelled
  correctly, and the port is not blocked by a firewall. Try a different
  ratflector from the picker.

### Indicator goes yellow then back to red
The transport opened but the handshake failed. Common causes:

- Wrong baud rate for the radio's current mode (9600 vs 38400)
- The ratflector requires a password and you didn't provide one
- The serial port is held open by another application (close any other
  TNC, CAT, or D-Rats program)

### TH-D75 connects but won't transmit
**Check Menu 614** on the radio. If it's set to `Off`, change it to `0.5`
seconds. See [Connecting to a Kenwood TH-D75 over USB](#connecting-to-a-kenwood-th-d75-over-usb)
for the full explanation.

### Chat messages I send don't appear on other stations' D-Rats
- Confirm your status indicator is green (not yellow)
- Confirm the other station is on the same frequency, same DV mode, and
  has Data Mode enabled on their radio
- Run `macrats-sniff /dev/cu.usbmodem...` in a Terminal alongside MacRats
  to see the raw bytes flowing — if you see outbound bytes leaving but
  no echo from the radio, it's the Menu 614 issue
- Try a ratflector connection first to confirm MacRats itself is working,
  then come back to the radio path

### App crashes on launch
File a bug report at <https://github.com/w9fyi/macrats/issues> with the
crash log from `~/Library/Logs/DiagnosticReports/MacRats-*.crash` and the
output of `sw_vers` (your macOS version).

---

## Known limitations in 0.1.0

These are intentional scope cuts for the alpha release. Most are tracked
for v1.1 or v1.2.

- **No file transfer** — chat, ping, and status only. Planned for v1.2.
- **No structured forms** (ICS-213, etc.) — planned for v1.2.
- **No map view** — planned for v1.2 using MapKit.
- **No Bluetooth SPP** — USB serial only for v1.0. Bluetooth is planned
  for v1.1 and will require an `IOBluetooth` coordinator to bring up the
  RFCOMM channel before the existing serial transport can use the radio.
- **No Winlink / email gateway** — planned for v1.2+.
- **TH-D75 only** — other radios will work in principle if they expose
  D-STAR slow data over a serial-like interface, but only the TH-D75 is
  tested. IC-705 and ID-52 support is on the roadmap.
- **No notarization** — see [First launch and Gatekeeper](#first-launch-and-gatekeeper).
- **No LZHuf compression** — the upstream D-Rats LZHuf legacy compression
  path is not implemented. MacRats negotiates uncompressed framing, which
  is compatible with all current D-Rats clients.

If you need any of the deferred features and would like to help bring them
forward, contributions are welcome — see the README's project layout for
where to start.

---

## Getting help

- **Bug reports and feature requests**: <https://github.com/w9fyi/macrats/issues>
- **Discussion**: post in the upstream D-Rats community or directly on the
  MacRats GitHub repo
- **Author**: AI5OS / Justin Mann

73 and good DX.
