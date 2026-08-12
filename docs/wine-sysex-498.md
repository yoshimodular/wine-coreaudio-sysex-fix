# Wine silently discards any SysEx larger than 498 bytes

**Affects:** any Windows application that sends System Exclusive to a real MIDI
port under Wine or CrossOver **on macOS**. It does not happen on Linux.

**Upstream status:** unfixed, since 2015.

---

## The symptom

A MIDI editor transmits a bank dump. The program reports success. Nothing
reaches the synthesizer, or the synthesizer waits indefinitely for a message
that is never closed.

Short messages — editing a parameter, changing program — work perfectly in both
directions. Only the large dumps fail.

## The cause

`dlls/winecoreaudio.drv/coremidi.c`, function `midi_send`:

```c
static void midi_send(MIDIPortRef port, MIDIEndpointRef dest, UInt8 *buffer, unsigned len)
{
    Byte packet_buf[512];
    MIDIPacketList *packet_list = (MIDIPacketList *)packet_buf;
    MIDIPacket *packet = MIDIPacketListInit(packet_list);

    packet = MIDIPacketListAdd(packet_list, sizeof(packet_buf), packet,
                               mach_absolute_time(), len, buffer);
    if (packet) MIDISend(port, dest, packet_list);
}
```

A fixed 512-byte buffer and **a single** call to `MIDIPacketListAdd`, with the
whole message. If it does not fit, the function returns `NULL` — behaviour
documented by Apple — and the `if` skips the send.

And its caller, `midi_out_long_data` (the `MODM_LONGDATA` handler), does not
chunk either:

```c
else if (dest->caps.wTechnology == MOD_MIDIPORT)
    midi_send(midi_out_port, dest->dest, (UInt8 *)hdr->lpData, hdr->dwBufferLength);

hdr->dwFlags &= ~MHDR_INQUEUE;
hdr->dwFlags |= MHDR_DONE;
set_out_notify(notify, dest, dev_id, MOM_DONE, (UINT_PTR)hdr, 0);
return MMSYSERR_NOERROR;
```

It marks the header as completed, notifies `MOM_DONE` and returns **success**.
The application has no way of finding out.

Only the `MOD_MIDIPORT` path (real MIDI ports) is affected. The `MOD_SYNTH`
path uses `MusicDeviceSysEx` with the full length and does not have the problem.

## The exact number: 498 bytes

`MIDIServices.h` packs both structures to 4 bytes, so on arm64 and on x86_64
alike:

```
offsetof(MIDIPacketList, packet) =  4
offsetof(MIDIPacket, data)       = 10
512 − 4 − 10                     = 498
```

Verified by reproducing the call with the same buffer and sweeping sizes:

```
last size that FITS    : 498 bytes
first that does NOT    : 499 bytes
```

## Measured live

With `wmiditest.exe` (included) sending through `midiOutLongMsg` from inside
the bottle to a virtual capture port:

| Sent | Received | Returns |
|---:|---:|---|
| 498 bytes | **498** | `MMSYSERR_NOERROR` |
| 499 bytes | **0** | `MMSYSERR_NOERROR` |
| 15,549 bytes | **0** | `MMSYSERR_NOERROR` |

One byte separates working from vanishing without a trace while reporting
success.

## History

- **2007** — commit `622ee1c4cc3b` introduces `MIDIOut_Send` with the 512-byte
  buffer, for short 3-byte messages, where it is more than enough.
- **Nov 2015** — commit `387fbdc7a164` ("winecoreaudio: Handle sysex MIDI
  messages", Wine 1.7.55) wires SysEx into that very same function. It adds
  chunking **on input**, but not on output.
- **Today** — no changes in `midi_send`.

The ALSA driver (`dlls/winealsa.drv/alsamidi.c`) hands the whole buffer to the
sequencer and does not have this limit. `winmm` does not cap or chunk anything
either: it passes `MODM_LONGDATA` straight through. It is a defect specific to
the CoreAudio backend.

## The workaround in this repository

A **`winmm` proxy DLL** that sits in front of Wine's: it forwards its 186
exports untouched and only intercepts `midiOutOpen`, `midiOutClose` and
`midiOutLongMsg`. Anything under 498 bytes passes through unmodified; anything
longer is split into 400-byte chunks with a pause between them (≈2500 B/s,
below the 3125 of the DIN cable, which incidentally also avoids overrunning the
interface).

Details that were hard to find:

1. **You cannot open a second handle to the same device** — Wine returns
   `MMSYSERR_ALLOCATED`. That is why the chunking **reuses the application's own
   `MIDIHDR`**, saving and restoring `lpData`/`dwBufferLength` and clearing
   `MHDR_DONE`/`MHDR_INQUEUE` between chunks: that way every pointer that comes
   back to it is its own and is still valid.

2. So that it does not receive one `MOM_DONE` per chunk, `midiOutOpen`
   **substitutes the callback** when it is `CALLBACK_FUNCTION` and swallows the
   intermediate ones.

3. **Wine fires `MOM_OPEN` during the `midiOutOpen` call itself.** If the
   handle-table entry is filled in *after* opening, that callback runs with
   half-written data, or with the pointer of the previous handle if closing only
   cleared the handle field. The entry must be reserved and filled in
   **entirely before** opening, and cleared entirely on close.

## The correct fix

In Wine, a loop in `midi_send` sending chunks of ≤498 bytes, re-initialising the
packet list on each pass. Apple explicitly documents that a packet may contain
**part** of a SysEx, so chunking is sanctioned by the API. Alternatively,
allocate the buffer at the required size, respecting the documented ceiling of
65536 bytes per list.

See [wine-patch.md](wine-patch.md) for a proposed patch.

## A second, independent ceiling

**CoreMIDI truncates at 12001 bytes** any SysEx delivered in a single
`MIDISend` call, also without reporting an error. See
[coremidi-12001.md](coremidi-12001.md). That is why the solution has to chunk,
not merely enlarge the buffer.
