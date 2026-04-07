# MacRats

A native macOS Swift/SwiftUI client that speaks the [D-Rats](https://github.com/ham-radio-software/D-Rats) protocol over D-STAR slow-data. Built **accessibility-first** for VoiceOver users — the existing Python+GTK D-Rats is structurally inaccessible to blind users on macOS, and no amount of metadata can fix that ([upstream issue #315](https://github.com/ham-radio-software/D-Rats/issues/315)).

MacRats is **not** a fork of D-Rats. It is a clean-room implementation of the DDT2 wire protocol in Swift, designed to interoperate with D-Rats over the air. The protocol layer is faithfully ported from the upstream Python sources and verified byte-for-byte against captured golden vectors.

## Status

**Alpha — full v1.0 stack working end-to-end.** Protocol, session, view-model, and SwiftUI app layers are all in place and tested. Feature parity with the core D-Rats chat tab is the v1.0 target.

### Working today

- ✅ DDT2 frame encode/decode + `[SOB]...[EOB]` envelope with yEncoding
- ✅ CRC-16 + zlib compression, byte-for-byte compatible with Python upstream
- ✅ `USBSerialTransport` for Kenwood TH-D75 over USB-C (TIOCEXCL, manual DTR/RTS, POLLHUP detection, IOSSIOSPEED)
- ✅ `TCPLoopbackTransport` for testing two MacRats instances on the same Mac
- ✅ `DDT2FrameSplitter` — reassembles arbitrarily chunked inbound bytes
- ✅ MMDVM host↔modem protocol (TH-D75 Menu 650 terminal mode) — full D-STAR TX/RX path
- ✅ Chat session state machine (T_DEF / T_PNG_REQ / T_PNG_RSP / T_PNG_ERQ / T_PNG_ERS / T_STATUS)
- ✅ Sign-on / sign-off automatic broadcasts on connect/disconnect
- ✅ Station status broadcasts (online / unattended / offline + free-form message)
- ✅ Chat log persistence to disk (NDJSON, rotating)
- ✅ SwiftUI app shell: `NavigationSplitView` with stations sidebar + chat view
- ✅ First-run setup wizard (callsign → connection → device → finish)
- ✅ 5-tab macOS Settings sheet (Preferences / Radio / GPS / Appearance / Chat)
- ✅ My Status popover in the toolbar
- ✅ VoiceOver-first throughout: single-sentence row labels, `@FocusState` autofocus, live-region announcements for notice matches, `NSAccessibilityEnabled=true` in the bundle
- ✅ Ad-hoc signed `.app` bundle produced by `scripts/make-app-bundle.sh`
- ✅ Upstream accessibility issue filed at [ham-radio-software/D-Rats#315](https://github.com/ham-radio-software/D-Rats/issues/315)

### Planned

- ⬜ Bluetooth SPP transport (v1.1 — needs `BluetoothCoordinator` to bring up RFCOMM channel 2)
- ⬜ Ratflector (Internet) connections (v1.1)
- ⬜ Events tab + sound alerts (v1.1)
- ⬜ Map view with MapKit + offline tiles (v1.2)
- ⬜ File transfer sessions, structured form messages, Winlink (v1.2+ — see `memory/macrats_feature_parity.md` for the full matrix)

## Test status

```text
140 tests, 15 suites, all passing in ~3 seconds.
```

- Every golden vector from upstream Python D-Rats is reproduced byte-for-byte
- Two `MacRatsAppModel` instances exchange chat, ping, and status over TCP loopback in integration tests
- `ChatLogStore` round-trips every `ChatMessage.Kind`, handles corruption, rotates automatically
- Live smoke-tested against the real TH-D75 over USB (normal CAT handshake confirmed with `macrats-probe`)

## Why a Swift rewrite

D-Rats is built on Python + GTK 3 via PyGObject. GTK on macOS draws its own widgets via Quartz; the host AppKit / NSAccessibility layer sees a single opaque `NSView` for the entire window. The `ATK → NSAccessibility` bridge that would expose individual GTK widgets to VoiceOver was never finished and is not part of upstream GTK on macOS. This means **even if every widget in `ui/mainwindow.glade` had perfect accessibility metadata, VoiceOver would still see one giant unlabeled "Window" element with nothing inside it**.

There are three honest paths forward for an accessible D-Rats experience on macOS:

1. **Replace the toolkit** in upstream D-Rats with Toga or PySide6 — significant work, requires upstream buy-in, benefits all platforms.
2. **Build a native Swift client that speaks the protocol** — this project.
3. **Headless D-Rats core + web UI** — requires a substantial refactor of upstream `mainapp.py` / `mainwindow.py`.

MacRats is option 2. It exists because GTK on macOS is a structural dead end for screen reader users, and a native SwiftUI app gets first-class VoiceOver support for free. If upstream ever pursues option 1, this project becomes redundant and that's a great outcome.

## Hardware

Primary test radio: **Kenwood TH-D75** (built-in TNC, USB-C serial, D-STAR DV slow-data). Enumerates on macOS as `/dev/cu.usbmodem*` (CDC-ACM, no driver needed). The TH-D75's **Menu 650 (Terminal Mode)** puts the radio into MMDVM-host protocol over its USB port, which is the transport MacRats uses for D-STAR data frames.

**v1.0 transport: USB only.** Bluetooth SPP is planned for v1.1 but is **not** a free addition — although macOS exposes paired Bluetooth SPP devices as `/dev/cu.*` device files, the device file is a stale shim until an `IOBluetooth` ACL connection is open AND an `IOBluetoothRFCOMMChannel` reference is held alive in memory. Specifically for the TH-D75, the data channel is **RFCOMM channel 2** (not the SDP-advertised SPP channel — this is hard-won knowledge from the sibling `th-programmer` project's `BluetoothManager.swift`). v1.1 will add a thin `BluetoothCoordinator` modeled on that proven pattern, then hand the resulting cu.* path to the existing `USBSerialTransport`.

Future support beyond TH-D75: any radio that can carry D-STAR DV slow-data and exposes a serial / Bluetooth SPP / KISS TNC interface.

## Building and running

### Build everything with SwiftPM

```bash
swift build          # debug build of MacRatsCore + all executables
swift test           # run all 140 tests
swift build -c release
```

### Build a real macOS `.app` bundle

```bash
scripts/make-app-bundle.sh               # debug, ad-hoc signed
scripts/make-app-bundle.sh release       # release build
scripts/make-app-bundle.sh release open  # release + launch when done
```

Produces `build/MacRats.app` — a real macOS bundle with a proper `Info.plist`, `PkgInfo`, and ad-hoc code signature. Bundle ID is `com.ai5os.macrats`, CFBundleDisplayName is `MacRats`, and the app registers with LaunchServices. You can drag it to `/Applications/` or run it via `open build/MacRats.app`.

### Command-line tools

Three executables are built alongside the app, useful for testing and debugging:

- **`macrats-sniff <device>`** — read-only serial sniffer. Opens a `/dev/cu.*` device and prints any bytes it receives, attempting to decode DDT2 envelopes. Safe with an idle radio.
- **`macrats-probe <device>`** — identifies what's on the other end of a serial port by sending a Kenwood `ID\r` probe and an MMDVM `getVersion` probe. Use this to confirm which USB port is your TH-D75 and whether it's in normal CAT or terminal mode.
- **`macrats-chat --callsign <CALL> --server <PORT> | --client <HOST> <PORT> | --serial <DEVICE>`** — interactive chat REPL. Run two instances on localhost with `--server` and `--client` to exercise the full protocol stack without a radio.

### Quickstart: talk to yourself over TCP loopback

Easiest way to verify the stack end-to-end with no hardware:

```bash
# Terminal 1
.build/debug/macrats-chat --callsign AI5OS --server 9876

# Terminal 2
.build/debug/macrats-chat --callsign W9FYI --client 127.0.0.1 9876
```

Type in Terminal 2 and watch the messages appear in Terminal 1 with timestamps and delegate decoding. `/ping AI5OS` and `/status online At the beach` also work.

### Data locations

- Settings: `~/Library/Application Support/MacRats/settings.json`
- Chat log: `~/Library/Application Support/MacRats/chat.log.jsonl` (NDJSON, one record per line, auto-rotates at 10 MB)

## License

GPL-3.0 — same as upstream D-Rats. The protocol port is a derivative work of the upstream Python sources for the wire format, so the license is required to match.

## Lineage and credit

The DDT2 wire protocol was designed by Dan Smith (KK7DS) for the original D-Rats. The Python 3 conversion and ongoing maintenance is by John Malmberg (WB8TYW) and Maurizio Andreotti (IZ2LXI) at [ham-radio-software/D-Rats](https://github.com/ham-radio-software/D-Rats). MacRats reimplements the wire format in Swift; it does not carry over any Python source code. The two projects are independent codebases that share only the on-air bytes.

## Author

AI5OS / Justin Mann
