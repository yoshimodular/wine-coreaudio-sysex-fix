# Wine on macOS silently discards any SysEx larger than 498 bytes

**A `winmm` proxy DLL that fixes it, the measurements that pin it down, and a
proposed patch for Wine.**

Affects any Windows application that sends System Exclusive to a real MIDI port
under **Wine or CrossOver on macOS**. Linux is not affected. Unfixed upstream
since 2015.

---

## The symptom

A MIDI editor transmits a bank dump — a patch librarian, a synth editor,
anything that uses `midiOutLongMsg`. The program reports success. Nothing
reaches the synthesizer, or the synthesizer sits waiting forever for a message
that never closes.

Short messages — editing a parameter, changing program — work perfectly in both
directions. Only the large dumps fail, and they fail *silently*: the application
gets `MMSYSERR_NOERROR` and a `MOM_DONE` notification, exactly as if the send
had worked.

## The cause

`dlls/winecoreaudio.drv/coremidi.c`, function `midi_send`, verbatim:

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

A fixed 512-byte stack buffer and **a single** `MIDIPacketListAdd` call with the
whole message, with no chunking loop. If the message does not fit,
`MIDIPacketListAdd` returns `NULL` — documented Apple behaviour — and the `if`
skips the send entirely.

The caller, `midi_out_long_data` (the `MODM_LONGDATA` handler), does not chunk
either, and cannot tell that anything went wrong because `midi_send` returns
`void`:

```c
else if (dest->caps.wTechnology == MOD_MIDIPORT)
    midi_send(midi_out_port, dest->dest, (UInt8 *)hdr->lpData, hdr->dwBufferLength);

hdr->dwFlags &= ~MHDR_INQUEUE;
hdr->dwFlags |= MHDR_DONE;
set_out_notify(notify, dest, dev_id, MOM_DONE, (UINT_PTR)hdr, 0);
return MMSYSERR_NOERROR;
```

It marks the header completed, notifies `MOM_DONE`, and returns **success**.

Only the `MOD_MIDIPORT` path (real MIDI ports) is affected. The `MOD_SYNTH` path
uses `MusicDeviceSysEx` with the full length and does not have the problem.

## The exact number: 498 bytes

`MIDIServices.h` packs both structures to 4 bytes, so this holds identically on
arm64 and on x86_64:

```
offsetof(MIDIPacketList, packet) =  4
offsetof(MIDIPacket, data)       = 10
512 − 4 − 10                     = 498
```

Confirmed by reproducing the call with the same buffer and sweeping sizes:

```
last size that FITS : 498 bytes
first that does NOT : 499 bytes
```

## Measured live

`wmiditest.exe` (included) sends a SysEx of an arbitrary size through
`midiOutLongMsg` from inside the bottle; `midisniff` (included) creates a
virtual CoreMIDI destination and counts what actually arrives.

| Sent | Received | `midiOutLongMsg` returns |
|---:|---:|---|
| 498 bytes | **498** | `MMSYSERR_NOERROR` |
| 499 bytes | **0** | `MMSYSERR_NOERROR` |
| 15,549 bytes | **0** | `MMSYSERR_NOERROR` |

One byte separates working from vanishing without a trace while reporting
success.

## Upstream history

- **2007** — commit `622ee1c4cc3b` introduces `MIDIOut_Send` with the 512-byte
  buffer, for short 3-byte messages, where it is more than enough.
- **Nov 2015** — commit `387fbdc7a164` ("winecoreaudio: Handle sysex MIDI
  messages", Wine 1.7.55) wires SysEx into that very same function. It adds
  chunking **on input**, but never adds it on output.
- **Today** — `midi_send` is unchanged.

The ALSA driver (`dlls/winealsa.drv/alsamidi.c`) hands the whole buffer to the
sequencer and has no such limit. `winmm` itself neither caps nor chunks: it
passes `MODM_LONGDATA` straight through. This is a defect specific to the
CoreAudio backend, which is why it only shows up on macOS.

## A second, independent ceiling

Even with Wine's buffer fixed, **CoreMIDI truncates at 12001 bytes** any SysEx
handed to it in a single `MIDISend` call — also silently, also returning
success. Enlarging Wine's buffer therefore would not be enough on its own; the
data has to be split across several `MIDISend` calls. Full measurements and the
three approaches that do *not* work around it (`kMIDIPropertyMaxSysExSpeed`, an
intermediate virtual port, an intermediate CoreMIDI driver) are in
[docs/coremidi-12001.md](docs/coremidi-12001.md).

---

## How the proxy works

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

## Building and installing

### Prerequisites

- **mingw-w64** — `brew install mingw-w64`. This provides
  `i686-w64-mingw32-gcc` and `i686-w64-mingw32-objdump`, both required.
- **Python 3** — used by the build script to turn the export dump into a `.def`
  file. macOS ships it; `python3` must be on `PATH`.
- **Xcode command line tools** for `swiftc`, if you want the measurement tools.

### CrossOver

```sh
winmm-proxy/build.sh "My Bottle"
```

The script is self-contained. It:

1. Runs `i686-w64-mingw32-objdump -p` on the CrossOver `winmm.dll` and generates
   `winmm.def` from the real export table — 186 entries, each pinned to its real
   ordinal, all of them forwarders (`Name = wmmreal.Name @ord`) except the three
   that are intercepted. Generating it rather than shipping it is what keeps the
   proxy in step with whatever Wine build you have.
2. Compiles the DLL and the test program:
   ```sh
   i686-w64-mingw32-gcc -O2 -shared -o winmm.dll winmmproxy.c winmm.def \
       -lkernel32 -static-libgcc -Wl,--enable-stdcall-fixup
   i686-w64-mingw32-gcc -O2 -o wmiditest.exe wmiditest.c -lwinmm
   ```
3. Copies Wine's `winmm.dll` to `syswow64/wmmreal.dll`, installs the proxy as
   `syswow64/winmm.dll`, and drops `wmiditest.exe` into `C:\`.
4. Sets the DLL override to `native,builtin` — **never** a bare `native`:
   without the builtin fallback, any process that fails to find the native DLL
   ends up with no `winmm` at all.
5. Kills `wineserver` so the change takes effect.

To undo it: `winmm-proxy/uninstall.sh "My Bottle"` restores `wmmreal.dll` over
`winmm.dll` and removes the override.

Set `CROSSOVER=/path/to/CrossOver` if CrossOver is not in the default location.

### Plain Wine

The install scripts target CrossOver, because that is where this was developed
and measured. The mechanism is not CrossOver-specific and the steps are the
same, only the paths differ: build `winmm.dll` against the export table of *your*
Wine's `winmm.dll`, copy that original to `$WINEPREFIX/drive_c/windows/syswow64/wmmreal.dll`,
put the proxy in its place, and set the override with `winecfg` (Libraries →
`winmm` → native then builtin). This path has **not** been tested here; adapt
the script and report back if you try it.

### The measurement tools

```sh
tools/build.sh      # builds the Swift tools into ~/bin
```

## Verifying

From inside the bottle:

```
C:\wmiditest.exe                      lists the MIDI output ports
C:\wmiditest.exe "PORT NAME" 498      sends a 498-byte SysEx
C:\wmiditest.exe "PORT NAME" 15549    sends a 15,549-byte SysEx
C:\wmiditest.exe "PORT NAME" 15549 400   sends it in 400-byte chunks
```

From macOS, in another terminal, to count what actually arrives:

```sh
~/bin/midisniff -v "SNIFF"            creates a virtual destination named SNIFF
```

`midisniff` writes the raw bytes to `sniff.bin` and a running summary to
`sniff.bin.txt` — total bytes, packet count, complete SysEx messages, truncated
ones, largest message. Point `wmiditest` at the `SNIFF` port and compare.

## Repository layout

```
winmm-proxy/     the fix
  winmmproxy.c     the proxy DLL
  wmiditest.c      test program: sends a SysEx of any size from inside Wine
  build.sh         generates the .def, compiles, installs into a bottle
  uninstall.sh     restores the bottle
tools/           CoreMIDI measurement tools (Swift, macOS-native)
  sysexsend.swift  sends a .syx file at a controlled rate
  midisniff.swift  captures MIDI and checks SysEx integrity
  midirecv.swift   listens to an existing source and describes the SysEx
  midislow.swift   virtual port that forwards at real cable speed
  midispeed.swift  reads/sets kMIDIPropertyMaxSysExSpeed
  build.sh
docs/
  wine-sysex-498.md    the Wine bug, with the measurements
  coremidi-12001.md    the second, independent CoreMIDI limit
  wine-patch.md        proposed upstream fix (untested — see below)
  es/                  the Spanish originals of the two bug documents
```

`winmm.def` is generated by `build.sh` and is deliberately not committed: it is
specific to the Wine build it was extracted from.

## What is verified and what is not

- The bug analysis, the 498-byte arithmetic, the measurement tables and the
  12001-byte CoreMIDI ceiling are all from live runs on **macOS 15.7.3, Apple
  Silicon, under CrossOver**.
- The `winmm` proxy is in daily use and does what it says on that setup.
- [`docs/wine-patch.md`](docs/wine-patch.md) is a **proposal**. It has not been
  compiled inside a Wine tree, has not been run, and has not been submitted to
  wine-devel. It is a starting point for someone with a Wine build to hand.
- The plain-Wine (non-CrossOver) install path is untested.
- Whether the CoreMIDI 12001-byte ceiling varies across macOS versions is
  unknown; it was measured on one.

## Origin

This came out of getting a 1995 Korg synth editor to dump banks from an Apple
Silicon Mac. The Korg-specific parts live elsewhere; what is here is the part
that applies to anyone sending SysEx through Wine on macOS.

## License

MIT — see [LICENSE](LICENSE).

The Wine source quoted in the documentation is from the Wine project and is LGPL
2.1+; it is reproduced here for identification and analysis of the defect.
