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

## The fix in this repository

A **`winmm.dll` proxy** that sits in front of Wine's. It forwards all 186
exports untouched and intercepts only three: `midiOutOpen`, `midiOutClose` and
`midiOutLongMsg`. The real Wine `winmm.dll` is installed alongside it as
`wmmreal.dll`, which doubles as the backup copy.

Anything at or under 498 bytes is passed straight through, unmodified. Anything
longer is split into 400-byte chunks with a pause between them — by default
≈2500 B/s, below the 3125 B/s of a MIDI DIN cable, which incidentally also stops
the dump overrunning the receiving interface.

Tunable through environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `WINMM_CHUNK` | 400 | bytes per chunk (the safe maximum is 498) |
| `WINMM_DELAY` | 160 | ms between chunks (160 → ~2500 B/s) |
| `WINMM_LOG` | unset | path to a log file; unset means no logging |

### Four implementation details that are not obvious

These cost real debugging time and are the reason the proxy is not a ten-line
wrapper.

1. **You cannot open a second handle to the same device.** The natural design —
   open a private handle, chunk on it, leave the application's handle alone —
   does not work: Wine returns `MMSYSERR_ALLOCATED` on a second `midiOutOpen` to
   the same device. The chunks therefore have to go out on the application's own
   handle.

2. **The application's `MIDIHDR` is never touched.** The chunks are sent with a
   header of the proxy's own, one per handle, allocated on first use and freed
   on close. Reusing the application's — mutating its `lpData` /
   `dwBufferLength` / `dwBytesRecorded` for each chunk — corrupts the heap: Wine
   services `MOM_DONE` *synchronously* inside `midiOutLongMsg`, so the
   application's completion handler runs while its own header still points into
   the middle of the buffer, and an ordinary handler (`unprepare();
   free(hdr->lpData);`) then frees a pointer 15 KB into the allocation.

3. **The callback is intercepted so that a `CALLBACK_FUNCTION` application sees
   one `MOM_DONE`, not N.** An application that sends one buffer expects exactly
   one completion notification. `midiOutOpen` therefore substitutes its own
   callback when the application asked for `CALLBACK_FUNCTION`; the notification
   of every chunk is swallowed, and once the whole buffer is out the proxy
   emits a single `MOM_DONE` itself, with the application's header intact.

   **This filtering only works for `CALLBACK_FUNCTION`.** With
   `CALLBACK_WINDOW`, `CALLBACK_EVENT` and `CALLBACK_THREAD` the driver posts
   the notification directly to the window, event or thread, and there is no way
   to intercept it from outside winmm — so such an application receives one
   notification per chunk. They are at least harmless: they carry the *proxy's*
   header, not the application's, so the application never sees its own header
   in a bogus state; and after the last chunk the proxy delivers one final
   notification carrying the real header, via `PostMessageA` /
   `PostThreadMessageA` / `SetEvent`. An application of this kind that expects
   exactly one `MM_MOM_DONE` per send may still behave oddly on large dumps.
   This is a known limitation, and the first place to look.

4. **Wine fires `MOM_OPEN` *during* the `midiOutOpen` call itself.** If the
   handle-table slot is filled in *after* `midiOutOpen` returns, that callback
   runs against a half-written slot — or, worse, against the callback pointer of
   a previous handle, if closing had only cleared the handle field. The slot must
   be reserved and filled in **entirely before** opening, and cleared
   **entirely** on close.

### What it does not do

It does not fix Wine. It works around the bug for the application it is
installed under. Deriving the proxy's export table from the actual Wine
`winmm.dll` means it must be rebuilt after any Wine or CrossOver upgrade — the
upgrade overwrites the DLL, and the export ordinals may change.

---

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
