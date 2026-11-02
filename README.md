# Galaxy Buds auto-switch for macOS

A small tool that gives a Mac the audio hand-off behaviour Samsung ships on Galaxy devices,
using the earbuds' own Bluetooth protocol rather than any Samsung software.

Two Galaxy Buds will only ever serve one audio source at a time. What they do offer is a
take-over request: a host can ask for the earbuds, and the earbuds move audio to it. Samsung's
Windows and Android software sends that request when it starts producing sound. macOS never
does, so a Mac silently loses audio to a phone and never asks for it back.

This implements the missing half.

## Status

Working, tested against Buds4 Pro on macOS 26:

- audio started on the Mac, earbuds held by a phone: the Mac asks and gets audio back
- the request uses the same frame Samsung's Windows host sends
- the earbuds answer and hand audio over within one to two seconds

Not implemented: two hosts holding the earbuds at once. That is not offered by this hardware.

## Running it

The tools need the earbuds Bluetooth address, supplied in `BUDS_ADDR`:

```
export BUDS_ADDR=aa-bb-cc-dd-ee-ff     # lowercase, dashes, as macOS prints it
```

macOS grants Bluetooth access per binary, and silently denies anything outside an app bundle.
Wrap any tool in a minimal `.app` before running it, otherwise the channel open is refused.

```
swiftc -O buds-sync.swift -o buds-sync
./buds-sync
```

## What each tool does

| File | Purpose |
| --- | --- |
| `buds-sync.swift` | the auto-switch daemon: watches local audio, reads earbud status, asks for audio, stands down during calls |
| `buds-auto.swift` | earlier, simpler version: reclaim only after losing audio |
| `budsctl.swift` | manual `take`, `release` and `status` |
| `smep-host.swift` | holds the vendor channel and answers property reads |
| `smep-read.swift` / `gear.swift` | single-frame send and receive on the vendor and standard channels |

## Protocol notes

Two channels matter. The standard channel (service `GEARMANAGER`) carries ordinary messages,
including the multipoint status reply and the setting-info announcement. The vendor channel
(service `SPPSERVICE4`) carries metadata writes.

Frames are `FE length 00 <id> <payload> crc16 EE` on the standard channel and
`FC length 00 01 <id> <payload> crc16 CC` on the vendor one.

The frames that matter:

```
setting info     id 0x73, 17 bytes, first byte 01, then transport 01 Bluetooth or 02 LE Audio
metadata         id 0x43 with the version field at 0x0B, value 3 for auto-switch, 0 for generic
take-over        id 0x71, one byte payload, device class 1 meaning computer
```

Behaviour follows Samsung's Windows host. Sound must persist for one second before it counts.
A lost earbud is not requested again for three seconds. A request gives up after twelve seconds.
A call on the other device makes the host stand down instead of competing.

## Where the knowledge came from

The three frames above were recovered from Samsung's own Windows software, by decompiling the
auto-switch library and the native packet builder it calls. The earbuds' status fields come
from the open source Galaxy Buds Client project.

Nothing here is Samsung code. It is a reimplementation from observed behaviour and decompiled
protocol structures.
