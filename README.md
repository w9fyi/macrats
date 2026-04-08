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
- ✅ `BluetoothRFCOMMTransport` for Kenwood TH-D75 over Bluetooth SPP — direct IOBluetooth RFCOMM channel 2, `writeAsync` + `rfcommChannelData` delegate, Tahoe-compatible via `openRFCOMMChannelAsync`. TX verified over the air 2026-04-08
- ✅ `TCPLoopbackTransport` for testing two MacRats instances on the same Mac
- ✅ `DDT2FrameSplitter` — reassembles arbitrarily chunked inbound bytes
- ✅ `WireLogger` — tailable `~/Downloads/MacRats/wire.log` file for bench debugging (VoiceOver-friendly via Terminal `tail -f`)
- ✅ MMDVM host↔modem protocol for TH-D75 Menu 650 terminal mode (for future reflector support)
- ✅ Chat session state machine (T_DEF / T_PNG_REQ / T_PNG_RSP / T_PNG_ERQ / T_PNG_ERS / T_STATUS)
- ✅ Sign-on / sign-off automatic broadcasts on connect/disconnect (500 ms post-signoff delay on serial for TX tail-out)
- ✅ Station status broadcasts (online / unattended / offline + free-form message)
- ✅ Fixed-position GPS beacon — D-Rats APRS `$$CRC` format, byte-for-byte compatible with upstream's `GPSPosition.to_aprs()` + `gpsa_checksum()`. Send-on-demand button in the GPS preferences tab; received beacons update the heard-station list with latitude/longitude/comment and appear as green entries in the chat log
- ✅ **Stateful reliability layer** (`StatefulSession`) ported from upstream `d_rats/sessions/stateful.py` — sliding window, T_DAT / T_ACK / T_REQACK protocol, in-order delivery with out-of-order buffering and duplicate suppression, 8-bit sequence numbers for interop with older D-Rats clients, 10-retry REQACK cap with progressive backoff, graceful and force-close modes. End-to-end verified over TCP loopback including a 20-block-through-4-block-window retransmit torture test.
- ✅ **File transfer** (`FileTransferSession`) on top of StatefulSession — full D-Rats file wire protocol (4-byte little-endian size + UTF-8 filename offer block, `OK` / `RESUME:` negotiation, zlib-compressed payload stream). Send File… (⇧⌘S) and Prepare to Receive File… (⇧⌘R) menu commands with native NSOpenPanel + NSAlert dialogs. Progress reported as system-event lines in the chat log at 10% increments. Byte-for-byte verified roundtrip through the DDT2 + stateful + TCP loopback stack.
- ✅ Chat log persistence to disk (NDJSON, rotating)
- ✅ SwiftUI app shell: `NavigationSplitView` with stations sidebar + chat view
- ✅ First-run setup wizard (callsign → connection → device → finish)
- ✅ 5-tab macOS Settings sheet (Preferences / Radio / GPS / Appearance / Chat) with Transport Tuning subsection for warmup length, warmup timeout, force delay, and wire logging toggle
- ✅ My Status popover in the toolbar
- ✅ VoiceOver-first throughout: single-sentence row labels, `@FocusState` autofocus, live-region announcements for notice matches, `NSAccessibilityEnabled=true` in the bundle
- ✅ Ad-hoc signed `.app` bundle produced by `scripts/make-app-bundle.sh`
- ✅ **Phase 1 over-the-air test passed** — 17 byte-perfect DDT2 frames transmitted over 446.100 MHz simplex, verified by a second receiver hearing the D-STAR digital signal
- ✅ **Ratflector (Internet) connections** — `RatflectorTransport` performs the D-Rats authentication handshake (`100 Authentication not required` / `101` + `USER`/`PASS` flow with `102`/`200`/`500` response codes), falls back to "old-school" mode on servers that don't send a banner, and integrates with the public ratflector directory fetched from `ham-radio-software/ratflectors`. Live-tested against `sewx.ratflector.com`.
- ✅ Upstream accessibility issue filed at [ham-radio-software/D-Rats#315](https://github.com/ham-radio-software/D-Rats/issues/315) + TH-D75 configuration recipe contributed as [#316](https://github.com/ham-radio-software/D-Rats/issues/316)

### Planned

- ⬜ Phase 3 — receive-side test against a second D-Rats-compatible station (needs a peer). Applies to both USB RX and Bluetooth RX verification, inbound GPS beacon decoding, and file transfer reception.
- ⬜ File transfer: drag-and-drop UI (polish over the current menu commands), resume support for interrupted transfers (v1.1)
- ⬜ Events tab + sound alerts (v1.1)
- ⬜ Map view with MapKit + offline tiles (v1.2)
- ⬜ Structured form messages (ICS-213, etc.), Winlink email gateway (v1.2+ — see `memory/macrats_feature_parity.md` for the full matrix)

## Test status

```text
249 tests, 23 suites, all passing in ~16 seconds.
```

(Most of the extra ~13 seconds is the new `StatefulSessionTests` suite — the reliability-protocol integration tests deliberately push data through several REQACK/ACK roundtrips over TCP loopback, which takes wall-clock time even on a loopback with no network latency.)

- Every golden vector from upstream Python D-Rats is reproduced byte-for-byte
- Two `MacRatsAppModel` instances exchange chat, ping, and status over TCP loopback in integration tests
- `ChatLogStore` round-trips every `ChatMessage.Kind`, handles corruption, rotates automatically
- `WarmupFrameTests` (11 tests) verify the D-Rats warmup frame behavior end-to-end
- `WireLoggerTests` (11 tests) verify the bench-debugging log file
- `RatflectorHandshakeTests` (13 tests) cover every branch of the text-based auth flow (code 100, 101→200, 101→102→200, 101→500, timeout→old-school, EOF→old-school, unknown code, missing callsign, missing password, rejected password, etc.)
- `RatflectorDirectoryTests` (17 tests) including the real captured `ratflectors.yml` fixture
- `GPSBeaconTests` (22 tests) covering the APRS checksum, `deg2nmea` / `nmea2deg`, encode of three golden vectors (Austin, Chicago, Southern hemisphere), comment clipping, station-name space-to-dash conversion, and the full encode→decode roundtrip
- `StatefulSessionTests` (8 tests) covering single-block, multi-block, bidirectional, and out-of-window (20 blocks through a 4-block window) reliable delivery scenarios over TCP loopback
- `FileTransferSessionTests` (5 tests) covering zlib roundtrip, zlib header byte signature, full end-to-end file transfer through the DDT2 + stateful layers, and error handling for wrong role and missing files
- **Live USB over-the-air test passed** against a real Kenwood TH-D75 on 446.100 MHz simplex D-STAR (2026-04-07)
- **Live Bluetooth over-the-air TX test passed** against the same TH-D75 (2026-04-08) — chat frames transmitted over Bluetooth SPP, confirmed with a second receiver. RX verification pending a second station.
- **Live Internet test passed** against `sewx.ratflector.com:9000` — handshake, broadcast send, clean disconnect (2026-04-07)

## Why a Swift rewrite

D-Rats is built on Python + GTK 3 via PyGObject. GTK on macOS draws its own widgets via Quartz; the host AppKit / NSAccessibility layer sees a single opaque `NSView` for the entire window. The `ATK → NSAccessibility` bridge that would expose individual GTK widgets to VoiceOver was never finished and is not part of upstream GTK on macOS. This means **even if every widget in `ui/mainwindow.glade` had perfect accessibility metadata, VoiceOver would still see one giant unlabeled "Window" element with nothing inside it**.

There are three honest paths forward for an accessible D-Rats experience on macOS:

1. **Replace the toolkit** in upstream D-Rats with Toga or PySide6 — significant work, requires upstream buy-in, benefits all platforms.
2. **Build a native Swift client that speaks the protocol** — this project.
3. **Headless D-Rats core + web UI** — requires a substantial refactor of upstream `mainapp.py` / `mainwindow.py`.

MacRats is option 2. It exists because GTK on macOS is a structural dead end for screen reader users, and a native SwiftUI app gets first-class VoiceOver support for free. If upstream ever pursues option 1, this project becomes redundant and that's a great outcome.

## Hardware

Primary test radio: **Kenwood TH-D75** (built-in TNC, USB-C serial, D-STAR DV slow-data). Enumerates on macOS as `/dev/cu.usbmodem*` (CDC-ACM, no driver needed on macOS — the built-in CDC-ACM driver handles it).

**v1.0 transports: USB and Bluetooth SPP** for the TH-D75, plus TCP loopback and ratflector (Internet) for development and radioless use. The Bluetooth path is **not** a thin wrapper over the USB path — although macOS exposes paired Bluetooth SPP devices as `/dev/cu.*` device files, reading and writing through those device files does not carry data on the TH-D75's DV data TNC. The Bluetooth transport speaks to `IOBluetoothRFCOMMChannel` directly via `writeAsync` + the `rfcommChannelData` delegate callback and hard-codes **RFCOMM channel 2** (the data channel confirmed via the sibling `th-programmer` project's `RFCOMMTransport` and the `d75link` binary). See the [Bluetooth SPP section below](#bluetooth-spp-for-the-th-d75) for the full explanation.

## Radio compatibility

**Short version: MacRats v0.1.0 works with the Kenwood TH-D75. That's the entire supported list.** It does *not* work with Icom radios, Yaesu radios, generic D-STAR radios, generic "MMDVM-compliant" hardware, or radios driven by an external soundcard TNC. The longer story is below — it matters because "supports D-STAR" and "speaks the protocol MacRats needs" are not the same set.

### What MacRats actually speaks over the wire

MacRats's USB serial transport speaks the [G4KLX MMDVMHost](https://github.com/g4klx/MMDVMHost) host↔modem protocol — the same one used by hotspot boards (ZUMspot, openSPOT, DVMega, MMDVM_HS_Hat). The TH-D75 is unusual because Kenwood put a real MMDVM-compliant modem inside the radio and exposes it over USB at 38400 baud whenever the radio is switched into Terminal Mode (Menu 650). MacRats then stuffs DDT2 bytes into the 3-byte slow-data slots inside each MMDVM voice frame, the radio packs them into D-STAR DV frames, and they go out on the air.

So **"MMDVM-compliant"** in MacRats's vocabulary specifically means *"speaks the G4KLX host↔modem serial protocol over a serial port and is wired to a transmitter that puts D-STAR slow data on the air"*. That's a much narrower definition than "supports D-STAR" or "supports digital voice modes".

### Supported today

| Hardware | Status | Notes |
|---|---|---|
| **Kenwood TH-D75 over USB-C** | ✅ Tested, working | The reference radio. Phase 1 over-the-air pass on 2026-04-07. Requires the [Menu 614 fix](#configuring-the-th-d75-for-macrats). |
| **Kenwood TH-D75 over Bluetooth SPP** | 🟢 Implemented via a dedicated `BluetoothRFCOMMTransport` | Same radio, wireless. Requires pairing in System Settings → Bluetooth first, plus Menu 984 set to `Bluetooth` on the radio. MacRats brings up an `IOBluetooth` ACL + RFCOMM channel 2 link and talks to the channel object directly — no `/dev/cu.*` device file is involved. First connect may show a macOS Bluetooth permission prompt. |

### Should work in theory but untested

| Hardware | Status | Notes |
|---|---|---|
| **MMDVM hotspot boards** (ZUMspot, openSPOT, DVMega, MMDVM_HS_Hat) plugged directly into the Mac via USB | 🟡 Untested | They speak the right protocol natively. You'd be transmitting at hotspot power levels (10–20 mW) into your local D-STAR reflector world, not over a real radio link, but the bytes should flow. Init sequence and RF config quirks may differ from the TH-D75 path. |
| **A custom MMDVM modem board** wired to any D-STAR-capable transmitter | 🟡 Untested | Same caveat — protocol is right, mechanical and init details may differ. |

If anyone has one of these boards and wants to try it, please file an issue with what you saw. Adding init quirks is much easier than the work it took to get the first radio working.

### Won't work without new code

| Hardware | Why | What it would take |
|---|---|---|
| **Icom IC-705 / ID-52 / ID-51 PLUS2 / IC-9700 / ID-5100** | Icom's "Internet Gateway" Terminal Mode is an Icom-proprietary protocol, not G4KLX MMDVM. Same air mode (D-STAR), completely different USB framing and command set. | A new `IcomTerminalTransport` parallel to the existing MMDVM path. On the v1.1/v1.2 roadmap. |
| **Yaesu C4FM / Fusion radios** | Different mode (C4FM, not D-STAR) and a different slow-data layer. | A separate transport plus a separate session layer — large effort, lower priority. |
| **Any analog FM radio + soundcard TNC** (Mobilinkd, PicoAPRS, Direwolf, etc.) | These speak AFSK over a soundcard interface, not a USB serial modem protocol. | A KISS TNC transport plus the existing audio TNC stack (Direwolf integration). v1.2+ roadmap. |
| **Any radio + KISS-mode TNC** | MacRats has no KISS framing layer yet. | A `KISSTransport` layer between `RadioTransport` and the session layer. Modest effort once specified. |
| **Older Kenwood TH-D74 / TM-D710 / TS-2000** | These have built-in TNCs but NOT in MMDVM terminal mode — they expose the TNC as a KISS-style packet interface (TH-D74) or AX.25 (others). | The KISS transport above. |

### Roadmap

In rough priority order (subject to change based on what hardware shows up):

1. ~~**Bluetooth SPP for the TH-D75**~~ — **implemented in dev, awaiting live test.** See the [Bluetooth section below](#bluetooth-spp-for-the-th-d75).
2. **Icom IC-705 / ID-52 transport** (v1.1 or v1.2) — second radio family, biggest user-facing impact
3. **KISS TNC transport** (v1.2) — opens the door to packet radios in general, including the TH-D74
4. **Hotspot board verification** (low effort, will be done as a side effect of helping anyone who tries)

If you want to help move any of these forward — especially the Icom transport, since it requires actual hardware to test — please open an issue and say so.

## Bluetooth SPP for the TH-D75

MacRats can talk to the TH-D75 wirelessly over Bluetooth Serial Port Profile (SPP). The radio must be paired through **System Settings → Bluetooth** first — MacRats does not do its own device inquiry. After pairing, pick the radio in Preferences → Radio, set connection type to "Bluetooth (TH-D74/D75)", and press Connect.

### How it works

The TH-D75 advertises a Bluetooth SPP service, and macOS will create a `/dev/cu.TH-D75` device file for the paired radio, but that `cu.*` file is **not** how MacRats exchanges bytes with the radio. Reading and writing through `cu.*` sends TX bytes into the void and never delivers RX bytes at all — the kernel BT serial driver is wired to a different endpoint than the TH-D75's DV data TNC.

Instead, MacRats uses a dedicated `BluetoothRFCOMMTransport` (in `MacRatsCore`) that:

1. Opens an `IOBluetooth` **ACL connection** to the paired radio.
2. Opens **RFCOMM channel 2** directly via `openRFCOMMChannelAsync` with a real delegate. Channel 2 is the TH-D75's data channel — knowledge borrowed from the sibling `th-programmer` project's `RFCOMMTransport`, confirmed via the `d75link` binary and the SDP service enumeration the radio advertises.
3. Sends TX bytes via `channel.writeAsync(pointer, length:)` directly to the channel object.
4. Receives RX bytes from the `rfcommChannelData(_:data:length:)` delegate callback and forwards them up to the DDT2 session layer.
5. Holds the channel reference alive for the lifetime of the connection.

No `/dev/cu.*` file is involved on the Bluetooth path. This is a hard divergence from the USB path, which does use a POSIX serial device file — Bluetooth and USB look identical up at the `RadioTransport` protocol layer, but the transports are two separate implementations.

Why the async API: on macOS Tahoe (26.x), the legacy `openRFCOMMChannelSync` blocks for ~3 seconds and returns generic `kIOReturnError` for every channel ID, even when a channel object is allocated. The modern `openRFCOMMChannelAsync` + `rfcommChannelOpenComplete:status:` delegate callback works correctly on Tahoe and is the supported path on current macOS.

### First-run TCC prompt

The first time MacRats opens an RFCOMM channel, macOS shows a Bluetooth permission prompt: *"MacRats would like to use Bluetooth."* Click **Allow**. If you accidentally deny, fix it in System Settings → Privacy & Security → Bluetooth. Without this permission, `openRFCOMMChannelSync` returns `kIOReturnNotPermitted` and the bring-up fails — MacRats will retry once after 1.5 seconds (to cover the case where the prompt is still on screen) and then surface a clear error.

The `NSBluetoothAlwaysUsageDescription` key in `scripts/macrats-Info.plist` is what triggers the prompt. Without it, TCC denies silently.

### Troubleshooting

- **"Pair a TH-D74 or TH-D75 in System Settings → Bluetooth"**: MacRats doesn't see a paired radio. Pair in System Settings, then click Refresh in Preferences → Radio → Bluetooth.
- **"ACL connection failed"**: the radio is out of range, powered off, or its Bluetooth radio is disabled. Turn Bluetooth on at the radio's front panel and try again.
- **"Could not open RFCOMM channel 2"**: usually means the radio is linked via System Settings but the baseband connection has gone stale after a power cycle. MacRats will close and reopen the ACL link automatically, but you can force this by toggling Bluetooth off and back on at the radio.
- **"The Bluetooth serial port did not appear"**: the RFCOMM channel opened but macOS didn't create the `cu.*` file within 10 seconds. Turn the radio off and back on.
- **"macOS denied Bluetooth permission"**: open System Settings → Privacy & Security → Bluetooth and toggle MacRats on.

### Required radio-side settings for Bluetooth

Bluetooth SPP carries the same DDT2 bytes that the USB path carries — it's a different pipe into the same radio — so the full [one-time radio setup](#configuring-the-th-d75-for-macrats) below still applies. Two menus need particular attention before Bluetooth will carry DV data:

- **Menu 984 (Data Band DV/DR Interface) must be set to `Bluetooth`** while MacRats is connecting over Bluetooth. The TH-D75 routes DV slow-data to exactly one interface at a time; leaving Menu 984 on `USB` is the single most common reason Bluetooth "connects" but carries no data. See [The Menu 984 gotcha](#the-menu-984-gotcha) below.
- **Menu 614 (Data TX End Timing) must be set to `0.5` seconds, not `Off`**, regardless of transport. See [The Menu 614 gotcha](#the-menu-614-gotcha) below.

## Configuring the TH-D75 for MacRats

These front-panel menu settings are **required** before MacRats can make the radio transmit. They come from the [TH-D75 user manual](https://www.kenwood.com) plus one critical gotcha discovered empirically during MacRats's Phase 1 over-the-air test on 2026-04-07 (and not documented anywhere in the manual).

| Step | Setting | Value | Notes |
| ---- | ------- | ----- | ----- |
| 1 | **Menu 610** — My Callsign | `AI5OS` (your call) | Slot 1. Up to 8 chars + optional 4-char memo after `/`. |
| 2 | **Digital Function Menu → Data Mode** | Active | `[F] [MODE] → Data Mode`. NOT plain DV or DR. Voice guide will announce "Data Mode" when active. A `< >` icon appears on the display. |
| 3 | **Frequency** | `446.100 MHz` | Kenwood-documented simplex test frequency. Use any DV simplex freq you like once you're comfortable. |
| 4 | **Destination** | `Local CQ` | `[F] [MODE] → Destination Select → Local CQ → ENT`. Sets `[TO]` to `CQCQCQ`. |
| 5 | **Menu 650** — DV Gateway Mode | `Off` | NOT `Reflector TERM Mode`. Menu 650 is for Internet reflector operation via third-party MMDVM apps, not direct-radio D-Rats data. |
| 6 | **Menu 984** — Data Band (DV/DR) Interface | `USB` *or* `Bluetooth` | **Must match the transport you're using.** Set to `USB` when connecting MacRats over USB, or `Bluetooth` when connecting over Bluetooth SPP. The TH-D75 routes DV slow-data to exactly one interface at a time — if this is wrong, your TX frames reach the radio over the wire you picked but the radio dumps them into the wrong subsystem, and nothing hits the air (or comes back from it). See [The Menu 984 gotcha](#the-menu-984-gotcha) below. |
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

### The Menu 984 gotcha

The TH-D75 has four separate interface-routing menus — each data subsystem picks USB *or* Bluetooth as its target, independently:

| Menu | Subsystem |
| ---- | --------- |
| **981** | PC I/O (CAT / MCP memory programming) |
| **982** | PC Output — APRS |
| **983** | Data Band (KISS) |
| **984** | **Data Band (DV/DR)** ← what D-Rats / MacRats uses |
| **985** | Data Band (DV Gateway) — for BlueDV and similar reflector apps |

Each menu is a radio button, not a checkbox. The radio only routes DV slow-data to **one** interface at a time. If Menu 984 is set to `USB` but MacRats is connecting over Bluetooth, the radio accepts the Bluetooth SPP link at the transport level (the RFCOMM channel opens cleanly, the Bluetooth connected icon lights up, and writes `succeed`), but internally the DV/DR router ignores Bluetooth entirely. Your TX frames never reach the DV modem and inbound RX frames are delivered to the USB port that nothing is listening on. Symptom: TX looks fine, RX is completely silent, no errors anywhere.

**Set Menu 984 to match the transport you're currently using.** Change it when you swap wires. This is particularly easy to miss because Menu 614 (and the rest of the radio setup) is unchanged — only the routing has to flip.

MacRats discovered this during Bluetooth bring-up — the RFCOMM channel opened, `writeAsync` succeeded, the radio's Bluetooth icon was lit, but `RFCOMM RX +N bytes` lines never appeared in the bring-up log across multiple TX bursts. Confirmed transmission from a second receiver proved MacRats's bytes *were* hitting the air via USB-routed output, while the Bluetooth side got nothing because Menu 984 was pinned to `USB`.

## Connecting to a ratflector (no radio needed)

A **ratflector** is a public D-Rats server on the Internet that relays chat, pings, and status messages between connected clients. Point MacRats at one and you can talk to other D-Rats users from your couch with no radio at all. This is the easiest way to try MacRats if you don't have a D-STAR HT handy, or to test against real peers before taking things to the air.

### In the app

1. Open Preferences (`⌘,`) → Radio tab
2. Set **Connection type** to **Ratflector (Internet)**
3. The **Public ratflector** picker loads the directory from [ham-radio-software/ratflectors](https://github.com/ham-radio-software/ratflectors) automatically the first time you switch to this mode. Click **Refresh** to re-fetch the list.
4. Pick a ratflector — MacRats fills in the host and port for you
5. Leave the password field blank unless the operator of a specific ratflector gave you one (most public ratflectors accept anonymous connections)
6. Close Preferences and press `⌘K` to connect

The connection status indicator turns green when MacRats has completed the ratflector's authentication handshake. Any chat messages you type go to all other users currently connected to the same ratflector. Incoming messages from other users appear in your chat log and populate the stations sidebar.

### From the CLI (`macrats-chat`)

```bash
macrats-chat --callsign AI5OS --ratflector sewx.ratflector.com
macrats-chat --callsign AI5OS --ratflector sewx.ratflector.com:9000
```

Then type a message and hit Return. The CLI REPL supports `/ping <callsign>`, `/status <online|unattended|offline> <message>`, and `/quit`.

### What the handshake actually does

Most public ratflectors are anonymous and MacRats's handshake completes in one round-trip:

```text
Server → Client:  "100 Authentication not required\r\n"
(handshake done, DDT2 frames flow)
```

For private ratflectors that require authentication, the full flow is:

```text
Server → Client:  "101 Authorization required\r\n"
Client → Server:  "USER AI5OS\r\n"
Server → Client:  "102 Password required\r\n"
Client → Server:  "PASS <password>\r\n"
Server → Client:  "200 Welcome\r\n"
(handshake done, DDT2 frames flow)
```

If the server sends no banner at all (pre-handshake legacy ratflectors), MacRats falls through to "old-school" mode after a 5-second timeout and proceeds to send/receive DDT2 frames without any handshake — matching upstream D-Rats's fallback behavior exactly.

**No encryption** — ratflector traffic is plaintext TCP. Treat it like a public ham radio channel, because that's functionally what it is.

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
- **`macrats-chat --callsign <CALL> --server <PORT> | --client <HOST> <PORT> | --serial <DEVICE> | --ratflector <HOST[:PORT]>`** — interactive chat REPL. Run two instances on localhost with `--server` and `--client` to exercise the full protocol stack without a radio, or `--ratflector sewx.ratflector.com` to talk to real D-Rats users on the public Internet.

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
