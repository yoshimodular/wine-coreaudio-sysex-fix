# CoreMIDI truncates at 12001 bytes

Measured on macOS 15.7.3, Apple Silicon.

**Any SysEx handed to CoreMIDI in a single `MIDISend` call is truncated at
12001 bytes.** `MIDISend` returns `noErr` and the leftover bytes disappear
without warning.

## The measurement

Sweeping sizes towards a virtual destination:

| Sent | Received |
|---:|---:|
| 12,000 | 12,000 |
| 12,002 | 12,002 |
| 12,500 | **12,001** |
| 15,549 | **12,001** |

The same content chunked into 256-byte blocks with ~100 ms pauses arrives
**identical byte for byte**.

It is not the sender's fault: `MIDIPacketListAdd` correctly builds lists of up
to 40,000 bytes (verified locally). The cut happens in the handover to the
`MIDIServer`.

> Note on the table: the 12,002 row is reproduced verbatim from the original
> measurements. Taken together with the 12,000 and 12,500 rows it means the
> ceiling is not a clean cut-off at exactly 12001 for every size; what is
> reliably established is that sufficiently large messages arrive capped at
> 12,001 bytes. The practical conclusion — chunk on the sending side — is the
> same either way.

## Practical consequences

**The chunking has to be done by the sending application.** There is no way to
fix it from outside:

- **`kMIDIPropertyMaxSysExSpeed` is no use.** It is the property CoreMIDI uses
  to pace SysEx, but **only `MIDISendSysex` honours it, not `MIDISend`** — and
  `MIDISend` is what Wine and most applications use. Verified by setting it to
  3125 and measuring: it slows nothing down. Network ports (RTP-MIDI) do not
  even declare it.

- **An intermediate virtual port is no use either**: its input suffers the same
  ceiling, so it receives the message already truncated.

- **Nor is an intermediate CoreMIDI driver.** Checked with the MIDI Monitor spy
  ("Spy on output to destinations"), which observes from inside the
  `MIDIServer`: when sending 15,549 bytes in one call, the spy reports
  **12,001**. The cut happens before any driver could see it.

## Two traps when measuring

Both produce false data and cost hours:

**1. Not copying the `MIDIPacket` by value.** The `data` field is a fixed
256-byte tuple; reading past it returns stack garbage, and `MIDIPacketNext` on
the copy computes the next address incorrectly:

```swift
// WRONG
var p = pl.pointee.packet
// RIGHT: pointers into the original list
let pktOffset  = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!
var pkt = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(pl))
    .advanced(by: pktOffset).assumingMemoryBound(to: MIDIPacket.self)
```

**2. The receive callback has to be extremely fast.** If it writes to disk on
every packet, CoreMIDI drops whatever arrives meanwhile and you end up measuring
the slowness of your own instrument, not the limit you were looking for.

## And when sending

Chunking into **small** fragments is no good either: with blocks of a dozen
bytes CoreMIDI mangles the message from the first one onwards. With 256 bytes it
arrives intact. That is the size used by the tools in this repository.
