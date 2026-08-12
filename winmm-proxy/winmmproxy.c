/* winmm.dll proxy - splits long System Exclusive messages into chunks.
 *
 * Wine (dlls/winecoreaudio.drv/coremidi.c, midi_send) builds the CoreMIDI
 * packet list in a fixed 512-byte buffer and makes a SINGLE call to
 * MIDIPacketListAdd. If the SysEx does not fit -- more than 498 bytes -- that
 * function returns NULL, Wine skips the MIDISend and sends nothing at all,
 * but still marks the header MHDR_DONE and returns MMSYSERR_NOERROR. The
 * application believes the dump went out. Never fixed upstream.
 *
 * This DLL sits in front of winmm and splits long messages into chunks that
 * do fit, with a pause between them so as not to exceed the real speed of a
 * MIDI cable (31250 baud = 3125 bytes/s). Everything else is forwarded
 * untouched to the real winmm, which is installed alongside under the name
 * wmmreal.dll.
 *
 * Tunable through environment variables:
 *   WINMM_CHUNK  bytes per chunk   (default 400, the safe maximum is 498)
 *   WINMM_DELAY  ms between chunks (default 160 -> ~2500 B/s)
 *   WINMM_LOG    path to a log     (unset: logs nothing)
 */

#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>
#include <stdlib.h>

#define WINE_LIMIT 498

static HMODULE real;
static CRITICAL_SECTION cs;
static int inited;

static MMRESULT (WINAPI *p_open)(LPHMIDIOUT, UINT, DWORD_PTR, DWORD_PTR, DWORD);
static MMRESULT (WINAPI *p_close)(HMIDIOUT);
static MMRESULT (WINAPI *p_long)(HMIDIOUT, LPMIDIHDR, UINT);
static MMRESULT (WINAPI *p_prep)(HMIDIOUT, LPMIDIHDR, UINT);
static MMRESULT (WINAPI *p_unprep)(HMIDIOUT, LPMIDIHDR, UINT);

static unsigned chunk_size = 400;
static unsigned chunk_delay = 160;
static char log_path[MAX_PATH];

/* Table of open handles. Every access goes under the critical section: it is
 * touched by the application's thread and by the MIDI callback as well. */
#define MAXH 32
static struct {
    HMIDIOUT  h;
    UINT      dev;
    DWORD_PTR cb;         /* the application's real callback */
    DWORD_PTR inst;       /* its instance data */
    DWORD     type;       /* CALLBACK_FUNCTION, _WINDOW, ... */
    int       suppress;   /* swallow the notifications of the chunks */
    MIDIHDR  *chunk_hdr;  /* our own header, the one the chunks are sent with */
} handles[MAXH];

typedef void (CALLBACK *MIDIOUTPROC)(HMIDIOUT, UINT, DWORD_PTR, DWORD_PTR, DWORD_PTR);

/* A free slot has h == NULL. While it is being opened it is marked RESERVED,
 * so that no other thread reuses it and slot_of() does not mistake it. */
#define RESERVED ((HMIDIOUT)(ULONG_PTR)-1)

/* Lock-free: only to be called with the critical section already held. */
static int slot_of_locked(HMIDIOUT h)
{
    if (!h || h == RESERVED) return -1;
    for (int i = 0; i < MAXH; i++) if (handles[i].h == h) return i;
    return -1;
}

static int slot_of(HMIDIOUT h)
{
    EnterCriticalSection(&cs);
    int i = slot_of_locked(h);
    LeaveCriticalSection(&cs);
    return i;
}

/* Our callback: swallows the notifications of intermediate chunks so that the
 * application receives a single MOM_DONE per send of its own, as it expects. */
static void CALLBACK proxy_cb(HMIDIOUT h, UINT msg, DWORD_PTR inst,
                              DWORD_PTR p1, DWORD_PTR p2)
{
    int i = (int)inst;
    if (i < 0 || i >= MAXH) return;

    EnterCriticalSection(&cs);
    HMIDIOUT alive = handles[i].h;
    int swallow = handles[i].suppress;
    DWORD_PTR cb = handles[i].cb, app_inst = handles[i].inst;
    LeaveCriticalSection(&cs);

    if (!alive) return;                        /* slot released: touch nothing */
    if (msg == MOM_DONE && swallow) return;    /* notification of a chunk of ours */
    if (cb) ((MIDIOUTPROC)cb)(h, msg, app_inst, p1, p2);
}

static void dbg(const char *fmt, ...)
{
    if (!log_path[0]) return;
    FILE *f = fopen(log_path, "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static void init(void)
{
    if (inited) return;
    EnterCriticalSection(&cs);
    if (!inited) {
        char buf[64];
        if (GetEnvironmentVariableA("WINMM_CHUNK", buf, sizeof(buf))) {
            unsigned v = (unsigned)atoi(buf);
            if (v >= 16 && v <= WINE_LIMIT) chunk_size = v;
        }
        if (GetEnvironmentVariableA("WINMM_DELAY", buf, sizeof(buf))) {
            int v = atoi(buf);
            if (v >= 0 && v <= 5000) chunk_delay = (unsigned)v;
        }
        GetEnvironmentVariableA("WINMM_LOG", log_path, sizeof(log_path));

        real = LoadLibraryA("wmmreal.dll");
        if (real) {
            p_open   = (void *)GetProcAddress(real, "midiOutOpen");
            p_close  = (void *)GetProcAddress(real, "midiOutClose");
            p_long   = (void *)GetProcAddress(real, "midiOutLongMsg");
            p_prep   = (void *)GetProcAddress(real, "midiOutPrepareHeader");
            p_unprep = (void *)GetProcAddress(real, "midiOutUnprepareHeader");
        }
        dbg("[winmmproxy] init: real=%p chunk=%u delay=%u",
             real, chunk_size, chunk_delay);
        inited = 1;
    }
    LeaveCriticalSection(&cs);
}

MMRESULT WINAPI midiOutOpen(LPHMIDIOUT ph, UINT dev, DWORD_PTR cb,
                            DWORD_PTR inst, DWORD flags)
{
    init();
    if (!p_open) return MMSYSERR_ERROR;
    DWORD type = flags & CALLBACK_TYPEMASK;
    int slot = -1;

    /* The slot is reserved and filled in COMPLETELY before opening: Wine can
     * fire MOM_OPEN during the midiOutOpen call itself, and proxy_cb would
     * then run against a half-filled slot -- or worse, against the callback
     * of the previous handle, which no longer exists. */
    EnterCriticalSection(&cs);
    for (int i = 0; i < MAXH; i++)
        if (!handles[i].h) {
            slot = i;
            handles[i].h = RESERVED;
            handles[i].dev = dev;
            handles[i].cb = cb;
            handles[i].inst = inst;
            handles[i].type = type;
            handles[i].suppress = 0;
            break;
        }
    LeaveCriticalSection(&cs);

    /* If the application uses a function callback, we put ours in front so we
     * can filter out the notifications of the chunks. */
    DWORD_PTR use_cb = cb, use_inst = inst;
    DWORD use_flags = flags;
    if (slot >= 0 && type == CALLBACK_FUNCTION && cb) {
        use_cb = (DWORD_PTR)proxy_cb;
        use_inst = (DWORD_PTR)slot;
    }

    MMRESULT r = p_open(ph, dev, use_cb, use_inst, use_flags);

    if (slot >= 0) {
        EnterCriticalSection(&cs);
        if (r == MMSYSERR_NOERROR && ph)
            handles[slot].h = *ph;
        else
            ZeroMemory(&handles[slot], sizeof(handles[slot]));
        LeaveCriticalSection(&cs);
    }
    if (r == MMSYSERR_NOERROR && ph)
        dbg("[winmmproxy] open dev=%u handle=%p callback=%s",
            dev, (void *)*ph,
            type == CALLBACK_FUNCTION ? "function (filtered)" :
            type == CALLBACK_WINDOW ? "window" :
            type == CALLBACK_NULL ? "none" : "other");
    return r;
}

MMRESULT WINAPI midiOutClose(HMIDIOUT h)
{
    init();
    if (!p_close) return MMSYSERR_ERROR;
    MMRESULT r = p_close(h);
    /* the slot is cleared COMPLETELY: leaving the callback pointer alive would
     * make the next open that reused the slot jump into dead code */
    EnterCriticalSection(&cs);
    for (int i = 0; i < MAXH; i++)
        if (handles[i].h == h) {
            free(handles[i].chunk_hdr);
            ZeroMemory(&handles[i], sizeof(handles[i]));
            break;
        }
    LeaveCriticalSection(&cs);
    return r;
}

/* Delivers ONE single completion notification to the application, with ITS
 * header untouched, imitating what the driver would do. Called once per
 * chunked send. */
static void notify_done(int slot, HMIDIOUT h, LPMIDIHDR hdr)
{
    if (slot < 0) return;
    EnterCriticalSection(&cs);
    DWORD_PTR cb = handles[slot].cb, inst = handles[slot].inst;
    DWORD type = handles[slot].type;
    UINT dev = handles[slot].dev;
    LeaveCriticalSection(&cs);
    if (!cb) return;

    switch (type) {
    case CALLBACK_FUNCTION:
        ((MIDIOUTPROC)cb)(h, MOM_DONE, inst, (DWORD_PTR)hdr, 0);
        break;
    case CALLBACK_WINDOW:
        PostMessageA((HWND)cb, MM_MOM_DONE, (WPARAM)dev, (LPARAM)hdr);
        break;
    case CALLBACK_THREAD:
        PostThreadMessageA((DWORD)cb, MM_MOM_DONE, (WPARAM)dev, (LPARAM)hdr);
        break;
    case CALLBACK_EVENT:
        SetEvent((HANDLE)cb);
        break;
    default:
        break;
    }
}

MMRESULT WINAPI midiOutLongMsg(HMIDIOUT h, LPMIDIHDR hdr, UINT size)
{
    init();
    if (!p_long) return MMSYSERR_ERROR;

    /* whatever fits in Wine's buffer is passed straight through */
    if (!hdr || hdr->dwBufferLength <= WINE_LIMIT)
        return p_long(h, hdr, size);

    if (!(hdr->dwFlags & MHDR_PREPARED)) return MIDIERR_UNPREPARED;

    dbg("[winmmproxy] long message: %lu bytes (Wine only accepts %d)",
        hdr->dwBufferLength, WINE_LIMIT);

    /* The application's header is NOT touched. The chunks are sent with a
     * header of our own, one per handle, reused and freed on close.
     *
     * It used to reuse the application's, mutating its lpData and
     * dwBufferLength. Wine services MOM_DONE synchronously inside p_long, so
     * the notification of the last chunk reached the application with the
     * header pointing into the middle of the block: an ordinary handler
     * ("unprepare and free(lpData)") freed a pointer 15 KB into the
     * allocation. Heap corruption. */
    int slot = slot_of(h);
    if (slot < 0) {
        dbg("[winmmproxy] unknown handle: cannot chunk safely");
        return p_long(h, hdr, size);   /* better to fail like Wine than corrupt */
    }

    EnterCriticalSection(&cs);
    if (!handles[slot].chunk_hdr)
        handles[slot].chunk_hdr = (MIDIHDR *)calloc(1, sizeof(MIDIHDR));
    MIDIHDR *ch = handles[slot].chunk_hdr;
    handles[slot].suppress = 1;           /* for the WHOLE send */
    LeaveCriticalSection(&cs);

    if (!ch) return MMSYSERR_NOMEM;

    char  *data  = hdr->lpData;
    DWORD  total = hdr->dwBufferLength;
    DWORD  off   = 0;
    unsigned pieces = 0;
    MMRESULT r = MMSYSERR_NOERROR;

    while (off < total) {
        DWORD n = total - off;
        if (n > chunk_size) n = chunk_size;

        ZeroMemory(ch, sizeof(*ch));
        ch->lpData = data + off;
        ch->dwBufferLength = n;
        ch->dwBytesRecorded = n;

        if (p_prep(h, ch, sizeof(*ch)) != MMSYSERR_NOERROR) { r = MMSYSERR_ERROR; break; }
        r = p_long(h, ch, sizeof(*ch));
        p_unprep(h, ch, sizeof(*ch));
        if (r != MMSYSERR_NOERROR) {
            dbg("[winmmproxy] chunk at %lu failed with %u", off, r);
            break;
        }
        off += n;
        pieces++;
        if (off < total && chunk_delay) Sleep(chunk_delay);
    }

    EnterCriticalSection(&cs);
    if (handles[slot].h == h) handles[slot].suppress = 0;
    LeaveCriticalSection(&cs);

    hdr->dwFlags &= ~MHDR_INQUEUE;
    hdr->dwFlags |= MHDR_DONE;
    notify_done(slot, h, hdr);

    dbg("[winmmproxy] sent %lu bytes in %u chunks -> %u", total, pieces, r);
    return r;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID res)
{
    if (reason == DLL_PROCESS_ATTACH) {
        InitializeCriticalSection(&cs);
        DisableThreadLibraryCalls(inst);
    } else if (reason == DLL_PROCESS_DETACH && !res) {
        DeleteCriticalSection(&cs);
    }
    return TRUE;
}
