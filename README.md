# MacRats

A native macOS Swift/SwiftUI client that speaks the [D-Rats](https://github.com/ham-radio-software/D-Rats) protocol over D-STAR slow-data. Built **accessibility-first** for VoiceOver users — the existing Python+GTK D-Rats is structurally inaccessible to blind users on macOS, and no amount of metadata can fix that ([upstream issue #315](https://github.com/ham-radio-software/D-Rats/issues/315)).

MacRats is **not** a fork of D-Rats. It is a clean-room implementation of the DDT2 wire protocol in Swift, designed to interoperate with D-Rats over the air. The protocol layer is faithfully ported from the upstream Python sources and verified byte-for-byte against captured golden vectors.

## Status

**Alpha — Phase 1 passed over the air 2026-04-07.** MacRats v0.1 has transmitted real D-STAR data on 446.100 MHz simplex via a Kenwood TH-D75, confirmed by an independent receiver hearing the digital squawk. Protocol, session, view-model, SwiftUI app, and live-radio interop are all in place and verified. The v1.0 target is feature parity with the core D-Rats chat tab plus a receiving-peer integration test (Phase 3).

### Working today

- ✅ DDT2 frame encode/decode + `[SOB]...[EOB]` envelope with yEncoding
- ✅ CRC-16 + zlib compression, byte-for-byte compatible with Python upstream
- ✅ D-Rats-compatible warmup frame (type 254, `"!"` stations, `[0x01]*16` payload) emitted before the first real frame after idle, matching `d_rats/transport.py` exactly
- ✅ `USBSerialTransport` for Kenwood TH-D75 over USB-C (TIOCEXCL, manual DTR/RTS, POLLHUP detection, IOSSIOSPEED)
- ✅ `TCPLoopbackTransport` for testing two MacRats instances on the same Mac
- ✅ `DDT2FrameSplitter` — reassembles arbitrarily chunked inbound bytes
- ✅ `WireLogger` — tailable `~/Downloads/MacRats/wire.log` file for bench debugging (VoiceOver-friendly via Terminal `tail -f`)
- ✅ MMDVM host↔modem protocol for TH-D75 Menu 650 terminal mode (for future reflector support)
- ✅ Chat session state machine (T_DEF / T_PNG_REQ / T_PNG_RSP / T_PNG_ERQ / T_PNG_ERS / T_STATUS)
- ✅ Sign-on / sign-off automatic broadcasts on connect/disconnect (500 ms post-signoff delay on serial for TX tail-out)
- ✅ Station status broadcasts (online / unattended / offline + free-form message)
- ✅ Chat log persistence to disk (NDJSON, rotating)
- ✅ SwiftUI app shell: `NavigationSplitView` with stations sidebar + chat view
- ✅ First-run setup wizard (callsign → connection → device → finish)
- ✅ 5-tab macOS Settings sheet (Preferences / Radio / GPS / Appearance / Chat) with Transport Tuning subsection for warmup length, warmup timeout, force delay, and wire logging toggle
- ✅ My Status popover in the toolbar
- ✅ VoiceOver-first throughout: single-sentence row labels, `@FocusState` autofocus, live-region announcements for notice matches, `NSAccessibilityEnabled=true` in the bundle
- ✅ Ad-hoc signed `.app` bundle produced by `scripts/make-app-bundle.sh`
- ✅ **Phase 1 over-the-air test passed** — 17 byte-perfect DDT2 frames transmitted over 446.100 MHz simplex, verified by a second receiver hearing the D-STAR digital signal
- ✅ Upstream accessibility issue filed at [ham-radio-software/D-Rats#315](https://github.com/ham-radio-software/D-Rats/issues/315)

### Planned

- ⬜ Phase 3 — receive-side test against a second D-Rats-compatible station (needs a peer)
- ⬜ Bluetooth SPP transport (v1.1 — needs `BluetoothCoordinator` to bring up RFCOMM channel 2)
- ⬜ Ratflector (Internet) connections (v1.1)
- ⬜ Events tab + sound alerts (v1.1)
- ⬜ Map view with MapKit + offline tiles (v1.2)
- ⬜ File transfer sessions, structured form messages, Winlink (v1.2+ — see `memory/macrats_feature_parity.md` for the full matrix)

## Test status

```text
162 tests, 17 suites, all passing in ~3 seconds.
```

- Every golden vector from upstream Python D-Rats is reproduced byte-for-byte
- Two `MacRatsAppModel` instances exchange chat, ping, and status over TCP loopback in integration tests
- `ChatLogStore` round-trips every `ChatMessage.Kind`, handles corruption, rotates automatically
- `WarmupFrameTests` (11 tests) verify the D-Rats warmup frame behavior end-to-end
- `WireLoggerTests` (11 tests) verify the bench-debugging log file
- **Live on-air test passed** against a real Kenwood TH-D75 on 446.100 MHz simplex D-STAR (2026-04-07)

## Why a Swift rewrite

D-Rats is built on Python + GTK 3 via PyGObject. GTK on macOS draws its own widgets via Quartz; the host AppKit / NSAccessibility layer sees a single opaque `NSView` for the entire window. The `ATK → NSAccessibility` bridge that would expose individual GTK widgets to VoiceOver was never finished and is not part of upstream GTK on macOS. This means **even if every widget in `ui/mainwindow.glade` had perfect accessibility metadata, VoiceOver would still see one giant unlabeled "Window" element with nothing inside it**.

There are three honest paths forward for an accessible D-Rats experience on macOS:

1. **Replace the toolkit** in upstream D-Rats with Toga or PySide6 — significant work, requires upstream buy-in, benefits all platforms.
2. **Build a native Swift client that speaks the protocol** — this project.
3. **Headless D-Rats core + web UI** — requires a substantial refactor of upstream `mainapp.py` / `mainwindow.py`.

MacRats is option 2. It exists because GTK on macOS is a structural dead end for screen reader users, and a native SwiftUI app gets first-class VoiceOver support for free. If upstream ever pursues option 1, this project becomes redundant and that's a great outcome.

## Hardware

Primary test radio: **Kenwood TH-D75** (built-in TNC, USB-C serial, D-STAR DV slow-data). Enumerates on macOS as `/dev/cu.usbmodem*` (CDC-ACM, no driver needed on macOS — the built-in CDC-ACM driver handles it).

**v1.0 transport: USB only.** Bluetooth SPP is planned for v1.1 but is **not** a free addition — although macOS exposes paired Bluetooth SPP devices as `/dev/cu.*` device files, the device file is a stale shim until an `IOBluetooth` ACL connection is open AND an `IOBluetoothRFCOMMChannel` reference is held alive in memory. Specifically for the TH-D75, the data channel is **RFCOMM channel 2** (not the SDP-advertised SPP channel — this is hard-won knowledge from the sibling `th-programmer` project's `BluetoothManager.swift`). v1.1 will add a thin `BluetoothCoordinator` modeled on that proven pattern, then hand the resulting cu.* path to the existing `USBSerialTransport`.

Future support beyond TH-D75: any radio that can carry D-STAR DV slow-data and exposes a serial / Bluetooth SPP / KISS TNC interface.

## Configuring the TH-D75 for MacRats

These front-panel menu settings are **required** before MacRats can make the radio transmit. They come from the [TH-D75 user manual](https://www.kenwood.com) plus one critical gotcha discovered empirically during MacRats's Phase 1 over-the-air test on 2026-04-07 (and not documented anywhere in the manual).

| Step | Setting | Value | Notes |
| ---- | ------- | ----- | ----- |
| 1 | **Menu 610** — My Callsign | `AI5OS` (your call) | Slot 1. Up to 8 chars + optional 4-char memo after `/`. |
| 2 | **Digital Function Menu → Data Mode** | Active | `[F] [MODE] → Data Mode`. NOT plain DV or DR. Voice guide will announce "Data Mode" when active. A `< >` icon appears on the display. |
| 3 | **Frequency** | `446.100 MHz` | Kenwood-documented simplex test frequency. Use any DV simplex freq you like once you're comfortable. |
| 4 | **Destination** | `Local CQ` | `[F] [MODE] → Destination Select → Local CQ → ENT`. Sets `[TO]` to `CQCQCQ`. |
| 5 | **Menu 650** — DV Gateway Mode | `Off` | NOT `Reflector TERM Mode`. Menu 650 is for Internet reflector operation via third-party MMDVM apps, not direct-radio D-Rats data. |
| 6 | **Menu 984** — DV/DR mode PC I/O | `USB` | Routes the application data lane to the USB cable (vs Bluetooth). |
| 7 | **Menu 630** — GPS data TX mode | `Off` | Prevents NMEA sentences from being injected into the slow-data field alongside MacRats's DDT2 frames. |
| 8 | **Menu 618** — Data Frame Output | `All` | Forwards all received D-STAR data to the USB port (vs filtering by callsign squelch). |
| 9 | **Menu 614** — Data TX End Timing | **`0.5`** ← **GOTCHA** | **Must NOT be `Off`.** See note below. |
| 10 | **Menu 980** — USB Operation | `COM + AF/IF Output` | Not `Mass Storage` (that mode makes the radio appear as a disk, with no serial port). |
| 11 | TX Power | `Low (0.5 W)` | Fine for bench tests. |

### The Menu 614 gotcha

The TH-D75 user manual describes Menu 614 as *"the delay time until return from fast data TX to RX in accordance with the TX timing of the PC software"* — making it sound like a simple tail-out duration control. In practice, **setting Menu 614 to `Off` silently disables the entire fast-data auto-TX path.** The radio accepts bytes from the serial port, writes them into internal buffers, and **never keys the transmitter.** No error, no warning, no observable feedback. The bytes just vanish.

Setting Menu 614 to `0.5` (seconds) — the lowest non-Off value — restores normal behavior. MacRats transmits, the TX relay keys, the D-STAR signal hits the air.

This is undocumented in the TH-D75 user manual, the IDM (Instruction Data Manual), and the D-Rats wiki. As far as we can tell, MacRats is the first project to hit and document this.

If you're configuring a TH-D75 for any D-Rats-compatible client (MacRats, upstream D-Rats on Linux, or something else), **check Menu 614 first if the radio refuses to transmit.** This has a good chance of being the answer.

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
