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

A **`winmm.dll` proxy** in front of Wine's: it forwards all 186 exports untouched and intercepts only `midiOutOpen`, `midiOutClose` and `midiOutLongMsg`.

Anything at or below 498 bytes is passed straight through. Longer messages are split into 400-byte blocks with a 160 ms pause (~2500 B/s, below the 3125 B/s of the DIN cable, which also avoids overrunning the interface). Tunable with `WINMM_CHUNK`, `WINMM_DELAY` and `WINMM_LOG`.

### Internals

**The application's `MIDIHDR` is never touched.** Chunks are sent with a separate header, allocated **per send**:

| Callback type | Where the chunk header lives |
|---|---|
| `CALLBACK_FUNCTION`, `CALLBACK_NULL` | on the stack — completions are filtered and serviced synchronously inside the call |
| `CALLBACK_WINDOW`, `_THREAD`, `_EVENT` | on the heap — the driver *posts* messages the app reads later, so it must outlive the call |

Heap headers go into a **ring bounded at 16 per handle**, freed on close. They cannot be freed earlier: a queued message may still point at them.

**Sends on one handle are serialized** by a per-handle critical section, and `midiOutClose` waits for an in-flight send before freeing anything.

**Completions are filtered by pointer:** `midiOutOpen` substitutes the callback for `CALLBACK_FUNCTION`, and only the `MOM_DONE` whose header is exactly the in-flight chunk is swallowed — so a short message sent meanwhile keeps its own completion. One completion is emitted at the end with the application's header intact, and **only if the send succeeded**.

### Known limitation — and it is not harmless

With `CALLBACK_WINDOW`, `CALLBACK_EVENT` or `CALLBACK_THREAD` there is no way to filter the driver's notifications from outside, so the application receives one per chunk. They carry *our* header rather than its own, but that **does not make it safe**: that header's `lpData` points into the middle of the application's buffer, so the ordinary handler (`unprepare(); free(hdr->lpData);`) would free an interior pointer just the same.

**With those callback types the proxy is not safe for large dumps.** They are still sent, because without it nothing goes out at all — but if your application uses a window callback and cleans up on completion, do not use this yet.

### Four things that were hard to find

1. **You cannot open a second handle to the same device.** Wine returns `MMSYSERR_ALLOCATED`, so the obvious idea — sending the chunks on a private handle — is not available.
2. **Wine services `MOM_DONE` synchronously inside `midiOutLongMsg`.** That is why mutating the application's header was memory corruption: the final chunk's completion reached it pointing into the middle of the buffer.
3. **Wine fires `MOM_OPEN` during the `midiOutOpen` call itself.** The handle-table slot must be claimed and filled **entirely before** opening, and cleared entirely on close.
4. **One in-flight marker per handle is not enough.** With two concurrent sends the second overwrites the first, and the loser's completions reach the application pointing into the middle of its buffer. Hence the serialization.

### Verification status

Measured end to end, from inside the bottle to a capture port: **498, 499, 15,549 and 18,749 bytes each arrive as a single SysEx of exactly the right size**.

What is **not** verified, stated plainly:

- The `CALLBACK_WINDOW`/`_THREAD`/`_EVENT` path has not been exercised with a real application, only reasoned about. See the limitation above.
- Multi-threaded sending is addressed by design (serialization), not demonstrated by a test.
- The Swift tools and shell scripts compile and pass `sh -n`, but the systematic review of that part is incomplete.

This code has been through four adversarial review rounds, finding 11, 2, 9 and 13 defects. Several rounds introduced new defects while fixing old ones, almost all in the concurrency handling. Treat it accordingly.

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
