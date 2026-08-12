/* wmiditest - sends a SysEx of arbitrary size through midiOutLongMsg from
 * inside Wine, to check how much of it actually gets out.
 *
 *   wmiditest.exe                       lists the MIDI output ports
 *   wmiditest.exe "SNIFF PORT" 15549    sends a SysEx of that size
 *   wmiditest.exe "SNIFF PORT" 15549 400   sends it in 400-byte chunks
 *
 * The SysEx is F0 42 30 36 4C 00 00 ... 00 F7 (valid 7-bit padding).
 */

#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void list_ports(void)
{
    UINT n = midiOutGetNumDevs();
    printf("%u MIDI output ports:\n", n);
    for (UINT i = 0; i < n; i++) {
        MIDIOUTCAPSA c;
        if (midiOutGetDevCapsA(i, &c, sizeof(c)) == MMSYSERR_NOERROR)
            printf("  %2u  %s\n", i, c.szPname);
    }
}

int main(int argc, char **argv)
{
    if (argc < 2) { list_ports(); return 0; }

    const char *want = argv[1];
    unsigned len = (argc > 2) ? (unsigned)strtoul(argv[2], NULL, 10) : 15549;
    /* 5 header bytes plus the trailing F7 get written: below that the memset
     * and the indices run outside the allocation */
    if (len < 8) len = 8;

    int dev = -1;
    UINT n = midiOutGetNumDevs();
    for (UINT i = 0; i < n; i++) {
        MIDIOUTCAPSA c;
        if (midiOutGetDevCapsA(i, &c, sizeof(c)) == MMSYSERR_NOERROR &&
            strcmp(c.szPname, want) == 0) { dev = (int)i; break; }
    }
    if (dev < 0) { printf("cannot find port \"%s\"\n", want); list_ports(); return 1; }
    printf("port %d = %s\n", dev, want);

    HMIDIOUT h = NULL;
    MMRESULT r = midiOutOpen(&h, (UINT)dev, 0, 0, CALLBACK_NULL);
    if (r != MMSYSERR_NOERROR) { printf("midiOutOpen failed: %u\n", r); return 1; }

    char *buf = malloc(len);
    if (!buf) { printf("out of memory\n"); midiOutClose(h); return 1; }
    memset(buf, 0x00, len);
    buf[0] = (char)0xF0; buf[1] = 0x42; buf[2] = 0x30; buf[3] = 0x36; buf[4] = 0x4C;
    buf[len-1] = (char)0xF7;

    /* chunked mode: wmiditest.exe PORT LENGTH CHUNK
     * Checks whether splitting the SysEx across several midiOutLongMsg calls
     * arrives intact at the other end, which is the basis of the fix. */
    unsigned chunk = (argc > 3) ? (unsigned)strtoul(argv[3], NULL, 10) : 0;

    if (chunk) {
        unsigned off = 0, pieces = 0;
        while (off < len) {
            unsigned n2 = len - off; if (n2 > chunk) n2 = chunk;
            MIDIHDR hh;
            memset(&hh, 0, sizeof(hh));
            hh.lpData = buf + off;
            hh.dwBufferLength = n2;
            hh.dwBytesRecorded = n2;
            midiOutPrepareHeader(h, &hh, sizeof(hh));
            r = midiOutLongMsg(h, &hh, sizeof(hh));
            if (r != MMSYSERR_NOERROR) { printf("  chunk at %u failed: %u\n", off, r); break; }
            midiOutUnprepareHeader(h, &hh, sizeof(hh));
            off += n2; pieces++;
            Sleep(5);
        }
        printf("chunked: %u bytes in %u pieces of %u -> last code %u\n",
               len, pieces, chunk, r);
        Sleep(1500);
        midiOutClose(h);
        free(buf);
        return 0;
    }

    MIDIHDR hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.lpData = buf;
    hdr.dwBufferLength = len;
    hdr.dwBytesRecorded = len;

    r = midiOutPrepareHeader(h, &hdr, sizeof(hdr));
    printf("midiOutPrepareHeader -> %u\n", r);

    r = midiOutLongMsg(h, &hdr, sizeof(hdr));
    printf("midiOutLongMsg(%u bytes) -> %u  (%s)\n", len, r,
           r == MMSYSERR_NOERROR ? "MMSYSERR_NOERROR: reports success" : "error");

    Sleep(1500);
    midiOutUnprepareHeader(h, &hdr, sizeof(hdr));
    midiOutClose(h);
    free(buf);
    return 0;
}
