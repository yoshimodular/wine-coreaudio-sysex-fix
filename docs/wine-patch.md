# Proposed upstream fix for `midi_send`

> **Status: proposed, not tested against a Wine build.** The bug analysis and
> the measurements in [wine-sysex-498.md](wine-sysex-498.md) come from live
> runs; this patch does not. It has not been compiled inside a Wine tree, it has
> not been run, and it has not been submitted to wine-devel. Treat it as a
> concrete starting point for someone with a Wine build handy, not as a verified
> fix. The tested workaround in this repository is the
> [`winmm` proxy](../winmm-proxy/), which lives outside Wine.

## What has to change

`dlls/winecoreaudio.drv/coremidi.c`, function `midi_send`, builds the CoreMIDI
packet list in a fixed 512-byte stack buffer and makes a single
`MIDIPacketListAdd` call. Anything over 498 bytes makes that call return `NULL`
and the message is dropped, while `midi_out_long_data` still reports
`MMSYSERR_NOERROR` to the application.

The fix is a chunking loop: slice the message into pieces that fit, and
re-initialise the packet list on every pass.

## Why chunking rather than a bigger buffer

Two independent reasons:

1. **Apple sanctions it.** The CoreMIDI headers state that a packet may contain
   a *partial* System Exclusive message — a SysEx can legitimately be spread
   across several packets, and across several packet lists, as long as the byte
   order is preserved. So slicing is not a hack around the API; it is the
   documented way to send a long SysEx.

2. **A bigger buffer would not be enough anyway.** A `MIDIPacketList` is capped
   at 65536 bytes, so growing the buffer only moves the cliff. More importantly,
   CoreMIDI itself truncates at 12001 bytes any SysEx handed over in a single
   `MIDISend` call, silently — see [coremidi-12001.md](coremidi-12001.md). Only
   splitting across multiple `MIDISend` calls gets a large dump through intact.

Since the chunk size has to stay well under 12001 regardless, keeping the
existing 512-byte stack buffer and deriving the chunk size from it is the
smallest change that actually works. No allocation is introduced.

## Illustrative diff

```diff
--- a/dlls/winecoreaudio.drv/coremidi.c
+++ b/dlls/winecoreaudio.drv/coremidi.c
@@
 static void midi_send(MIDIPortRef port, MIDIEndpointRef dest, UInt8 *buffer, unsigned len)
 {
     Byte packet_buf[512];
     MIDIPacketList *packet_list = (MIDIPacketList *)packet_buf;
-    MIDIPacket *packet = MIDIPacketListInit(packet_list);
-
-    packet = MIDIPacketListAdd(packet_list, sizeof(packet_buf), packet,
-                               mach_absolute_time(), len, buffer);
-    if (packet) MIDISend(port, dest, packet_list);
+    MIDIPacket *packet;
+    unsigned sent = 0;
+
+    /* The largest payload that fits in packet_buf. MIDIServices.h packs both
+     * structures to 4 bytes, which makes this 512 - 4 - 10 = 498 on every
+     * architecture macOS supports. */
+    const unsigned max_chunk = sizeof(packet_buf)
+                             - offsetof(MIDIPacketList, packet)
+                             - offsetof(MIDIPacket, data);
+
+    /* A packet may carry a partial SysEx, so a long message is split across
+     * several packet lists. Sending it in one go is not an option: a single
+     * MIDIPacketListAdd larger than max_chunk returns NULL and the message
+     * would be dropped, and CoreMIDI additionally truncates a SysEx handed to
+     * one MIDISend call at around 12000 bytes without reporting an error. */
+    do
+    {
+        unsigned chunk = len - sent;
+        if (chunk > max_chunk) chunk = max_chunk;
+
+        packet = MIDIPacketListInit(packet_list);
+        packet = MIDIPacketListAdd(packet_list, sizeof(packet_buf), packet,
+                                   mach_absolute_time(), chunk, buffer + sent);
+        if (!packet)
+        {
+            WARN("MIDIPacketListAdd failed for %u bytes at offset %u\n", chunk, sent);
+            return;
+        }
+        MIDISend(port, dest, packet_list);
+        sent += chunk;
+    } while (sent < len);
 }
```

`offsetof` needs `<stddef.h>`, which `coremidi.c` may or may not already pull
in; add the include if it does not.

The `do ... while` keeps the existing behaviour for `len == 0` (one call with an
empty payload) rather than silently changing it to no call at all. If upstream
prefers, a plain `while (sent < len)` is equivalent for every real message.

## Points a reviewer will raise

- **Timestamps.** Each chunk is stamped with `mach_absolute_time()` at the
  moment it is built, i.e. "now", which is what the original code did. That
  keeps the chunks in order and lets CoreMIDI deliver them as fast as the
  destination allows. An alternative is to stamp them all with the same instant
  taken once before the loop; both preserve ordering.

- **Pacing.** This patch does not pace the output. A real MIDI DIN cable runs at
  3125 bytes/s, and firing a 15 KB dump at a hardware interface as fast as
  CoreMIDI will take it can overrun the receiving synthesizer. The `winmm` proxy
  in this repository deliberately inserts a delay between chunks for that
  reason. Whether the driver is the right place to do that, or whether it should
  be left to `kMIDIPropertyMaxSysExSpeed` (which `MIDISend` does not honour —
  see [coremidi-12001.md](coremidi-12001.md)), is a design question for
  wine-devel rather than something this patch should decide.

- **Error reporting.** `midi_send` returns `void`, so `midi_out_long_data`
  cannot tell the application that anything went wrong; it unconditionally sets
  `MHDR_DONE` and returns `MMSYSERR_NOERROR`. Making `midi_send` return a status
  and propagating it would be a separate, larger change. It is worth doing —
  the silent success is what makes this bug so hard to diagnose — but it is not
  needed to stop the data loss.

- **Where to cap the chunk.** 498 comes from the existing 512-byte buffer, and
  it is comfortably below every other ceiling involved, so it needs no
  justification beyond "it is what fits". Anyone enlarging the buffer must keep
  the chunk well under the ~12000-byte CoreMIDI ceiling and under the 65536-byte
  packet list maximum.

## Verifying a build

`wmiditest.exe` in [`winmm-proxy/`](../winmm-proxy/) sends a SysEx of any size
through `midiOutLongMsg` from inside the prefix, and `midisniff` in
[`tools/`](../tools/) creates a virtual destination that counts what actually
arrives. Before the patch, 499 bytes in gives 0 bytes out; after it, the byte
count in and out should match at 499, at 15,549 and beyond.
