// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * sl3bridge: moves audio between the Rane SL3 (via libusb) and a BlackHole
 * loopback device, so DJ software such as Mixxx can use the SL3.
 *
 * Channel map on BlackHole (16ch):
 *   SL3 inputs 1..6  -> BlackHole channels 1..6   (Mixxx: vinyl control inputs)
 *   BlackHole 7..12  -> SL3 outputs 1..6          (Mixxx: deck outputs)
 * The bridge writes only channels 1..6 and reads only 7..12, so Mixxx must
 * send its outputs to 7..12 and never to 1..6.
 *
 * The SL3 and BlackHole run on different clocks. Each direction goes through
 * a ring buffer whose consumer resamples (linear interpolation) at a ratio
 * steered by the ring's smoothed fill level.
 *
 * The SL3 only plays USB audio while a host keeps it out of analog thru
 * (see docs/PROTOCOL.md). The bridge does that, hands the decks back to thru
 * on exit, and reconnects if the box is unplugged or loses power.
 *
 * Build: make
 * Run:   build/sl3bridge [--device NAME] [--buffer FRAMES] [--target FRAMES]
 */
#include <CoreAudio/CoreAudio.h>
#include <libusb.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>

/* longest gap between callbacks since last stats line, in ms */
static double g_gap_usb, g_gap_io;
static uint64_t g_usb_frames, g_io_frames;
/* peak per channel since last stats line: SL3 inputs, and BlackHole 7..12 headed to SL3 outputs */
static float g_pk_in[6], g_pk_out[6];
static void peak(float *pk, const float *fr) { for (int c = 0; c < 6; c++) { float a = fabsf(fr[c]); if (a > pk[c]) pk[c] = a; } }
static double dbfs(float v) { return v > 1e-6f ? 20 * log10(v) : -120; }
static double ms_now(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6; }
static void note_gap(double *last, double *maxgap) { double t = ms_now(); if (*last > 0 && t - *last > *maxgap) *maxgap = t - *last; *last = t; }

#define VID 0x1cc5
#define PID 0x0001
#define IF_AC   0
#define IF_PLAY 1
#define IF_CAP  2
#define EP_PLAY 0x06
#define EP_CAP  0x82
#define IF_HID  3
#define EP_HID_OUT 0x01
#define EP_HID_IN  0x81
#define HID_REPORT 64
#define HEARTBEAT_MS 100
#define NCH 6
#define FRAME_BYTES 18
#define PKT_MAX 126
/* microframes queued: capture 16 x 32 = 64 ms, playback 8 x 16 = 16 ms */
#define CAP_PKTS 32
#define CAP_NXF 16
#define PLAY_PKTS 16
#define PLAY_NXF 8
#define SKIP_PACKETS 3
#define RATE 44100.0
#define BH_IN_FIRST  0   /* BlackHole channel index (0-based) for SL3 input 1 */
#define BH_OUT_FIRST 6   /* BlackHole channel index (0-based) read for SL3 output 1 */
#define MAX_RATIO_DEV 0.002

static volatile sig_atomic_t g_stop;
static void on_sigint(int s) { (void)s; g_stop = 1; }

/* ---- lock-free single-producer single-consumer ring of 6-ch float frames ---- */
#define RING_FRAMES 16384
typedef struct {
    float buf[RING_FRAMES * NCH];
    _Atomic uint64_t w, r;
    uint64_t overruns;
} ring_t;

static uint64_t ring_fill(ring_t *q) { return atomic_load(&q->w) - atomic_load(&q->r); }

static void ring_push(ring_t *q, const float *fr) {
    uint64_t w = atomic_load_explicit(&q->w, memory_order_relaxed);
    if (w - atomic_load_explicit(&q->r, memory_order_acquire) >= RING_FRAMES) { q->overruns++; return; }
    memcpy(&q->buf[(w % RING_FRAMES) * NCH], fr, sizeof(float) * NCH);
    atomic_store_explicit(&q->w, w + 1, memory_order_release);
}

static int ring_pop(ring_t *q, float *fr) {
    uint64_t r = atomic_load_explicit(&q->r, memory_order_relaxed);
    if (atomic_load_explicit(&q->w, memory_order_acquire) == r) return 0;
    memcpy(fr, &q->buf[(r % RING_FRAMES) * NCH], sizeof(float) * NCH);
    atomic_store_explicit(&q->r, r + 1, memory_order_release);
    return 1;
}

/* ---- resampling consumer, ratio steered by smoothed ring fill ---- */
typedef struct {
    ring_t *q;
    double target, alpha, avg, ratio, frac;
    float cur[NCH], next[NCH];
    int primed;
    uint64_t underruns, resets;
} reader_t;

static void reader_init(reader_t *rd, ring_t *q, double target, double alpha) {
    memset(rd, 0, sizeof *rd);
    rd->q = q; rd->target = target; rd->alpha = alpha; rd->avg = target; rd->ratio = 1;
}

/* Call once per block before reading, so the fill is sampled at a steady phase. */
static void ring_drop_to(ring_t *q, uint64_t keep) {
    uint64_t w = atomic_load_explicit(&q->w, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&q->r, memory_order_relaxed);
    if (w - r > keep) atomic_store_explicit(&q->r, w - keep, memory_order_release);
}

static void reader_update(reader_t *rd) {
    double fill = (double)ring_fill(rd->q);
    /* far off target (startup backlog, stall): jump back to target instead of slewing */
    if (rd->primed && fill > 4 * rd->target) { ring_drop_to(rd->q, (uint64_t)rd->target); rd->resets++; fill = rd->target; rd->avg = fill; }
    if (!rd->primed) {
        if (fill < rd->target) return;
        ring_drop_to(rd->q, (uint64_t)rd->target);
        fill = rd->target; rd->primed = 1; rd->avg = fill;
        ring_pop(rd->q, rd->cur); ring_pop(rd->q, rd->next);
    }
    rd->avg += rd->alpha * (fill - rd->avg);
    double dev = 0.001 * (rd->avg - rd->target) / rd->target * 4;
    if (dev > MAX_RATIO_DEV) dev = MAX_RATIO_DEV;
    if (dev < -MAX_RATIO_DEV) dev = -MAX_RATIO_DEV;
    rd->ratio = 1 + dev;
}

static void reader_read(reader_t *rd, float *out) {
    if (!rd->primed) { memset(out, 0, sizeof(float) * NCH); return; }
    for (int c = 0; c < NCH; c++) out[c] = rd->cur[c] + (rd->next[c] - rd->cur[c]) * (float)rd->frac;
    rd->frac += rd->ratio;
    while (rd->frac >= 1) {
        rd->frac -= 1;
        memcpy(rd->cur, rd->next, sizeof rd->cur);
        if (!ring_pop(rd->q, rd->next)) { rd->underruns++; rd->primed = 0; rd->frac = 0; break; }
    }
}

static ring_t g_in, g_out;     /* g_in: SL3 -> BlackHole, g_out: BlackHole -> SL3 */
static reader_t rd_in, rd_out; /* rd_in consumed by the IOProc, rd_out by the USB thread */

/* ---- USB side ---- */
#define FIFO_N 4096
static int fifo[FIFO_N];
static unsigned fifo_w, fifo_r;
static struct { long cap_pkts, cap_err, play_err, fallback, xfer_err, skip; double acc; int inflight, stop; } U;

static int32_t get24(const uint8_t *p) {
    int32_t v = p[0] | p[1] << 8 | p[2] << 16;
    return (v & 0x800000) ? v - (1 << 24) : v;
}
static void put24(uint8_t *p, int32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; }

static void LIBUSB_CALL cap_cb(struct libusb_transfer *t) {
    static double last; note_gap(&last, &g_gap_usb);
    if (t->status == LIBUSB_TRANSFER_COMPLETED) {
        for (int i = 0; i < t->num_iso_packets; i++) {
            struct libusb_iso_packet_descriptor *pd = &t->iso_packet_desc[i];
            U.cap_pkts++;
            if (pd->status != LIBUSB_TRANSFER_COMPLETED) { U.cap_err++; continue; }
            int n = pd->actual_length / FRAME_BYTES;
            if (fifo_w - fifo_r < FIFO_N) fifo[fifo_w++ % FIFO_N] = n;
            if (U.skip < SKIP_PACKETS) { U.skip++; continue; }
            const uint8_t *p = libusb_get_iso_packet_buffer_simple(t, i);
            for (int f = 0; f < n; f++) {
                float fr[NCH];
                for (int c = 0; c < NCH; c++) fr[c] = get24(p + f * FRAME_BYTES + c * 3) / 8388608.0f;
                ring_push(&g_in, fr);
                peak(g_pk_in, fr);
                g_usb_frames++;
            }
        }
    } else if (t->status != LIBUSB_TRANSFER_CANCELLED) U.xfer_err++;
    if (U.stop || t->status == LIBUSB_TRANSFER_CANCELLED || t->status == LIBUSB_TRANSFER_NO_DEVICE) { U.inflight--; return; }
    if (libusb_submit_transfer(t) != 0) { U.inflight--; U.stop = 1; }
}

static void fill_play(struct libusb_transfer *t) {
    uint8_t *p = t->buffer;
    int total = 0;
    reader_update(&rd_out);
    for (int i = 0; i < t->num_iso_packets; i++) {
        int n;
        if (fifo_r != fifo_w) n = fifo[fifo_r++ % FIFO_N];
        else { U.fallback++; U.acc += RATE * 125e-6; n = (int)U.acc; U.acc -= n; }
        if (n < 0 || n > PKT_MAX / FRAME_BYTES) n = 5;
        for (int f = 0; f < n; f++) {
            float fr[NCH];
            reader_read(&rd_out, fr);
            for (int c = 0; c < NCH; c++) {
                float v = fr[c];
                if (v > 1) v = 1;
                if (v < -1) v = -1;
                put24(p + total + f * FRAME_BYTES + c * 3, (int32_t)lrintf(v * 8388607.0f));
            }
        }
        t->iso_packet_desc[i].length = n * FRAME_BYTES;
        total += n * FRAME_BYTES;
    }
    t->length = total;
}

static void LIBUSB_CALL play_cb(struct libusb_transfer *t) {
    if (t->status == LIBUSB_TRANSFER_COMPLETED) {
        for (int i = 0; i < t->num_iso_packets; i++)
            if (t->iso_packet_desc[i].status != LIBUSB_TRANSFER_COMPLETED) U.play_err++;
    } else if (t->status != LIBUSB_TRANSFER_CANCELLED) U.xfer_err++;
    if (U.stop || t->status == LIBUSB_TRANSFER_CANCELLED || t->status == LIBUSB_TRANSFER_NO_DEVICE) { U.inflight--; return; }
    fill_play(t);
    if (libusb_submit_transfer(t) != 0) { U.inflight--; U.stop = 1; }
}

static libusb_context *g_ctx;

/*
 * Interface 3 control channel. Report: [cmd][seq u32 LE][payload], 64 bytes,
 * on the interrupt EPs. A deck plays USB audio only while
 *   - its switch byte is 01 (control indices 8, 14, 20: the last byte of each
 *     6-byte deck block; 01 is the factory value, 00 forces thru), and
 *   - a host keeps sending command 0x37 (8-byte challenge, box answers with 8
 *     bytes; Scratch Live uses the answer to authenticate the box, the box
 *     only needs the traffic).
 * Once switched, the box stays in USB mode even after the heartbeat stops, so
 * on exit we set the switch bytes to 00 to hand the decks back to thru.
 */
static libusb_device_handle *g_h;
static uint32_t g_hid_seq = 1;
static long g_hb_sent, g_hb_replies;

/* Synchronous request; only used when no other thread is running USB events. */
static int hid_request(uint8_t cmd, const uint8_t *payload, int len, uint8_t *reply) {
    uint8_t out[HID_REPORT] = {0};
    uint32_t seq = g_hid_seq++;
    out[0] = cmd;
    memcpy(out + 1, &seq, 4);
    if (len) memcpy(out + 5, payload, len);
    int n;
    if (libusb_interrupt_transfer(g_h, EP_HID_OUT, out, HID_REPORT, &n, 500)) return -1;
    double t0 = ms_now();
    while (ms_now() - t0 < 500) {
        if (libusb_interrupt_transfer(g_h, EP_HID_IN, reply, HID_REPORT, &n, 50) || n < 5) continue;
        uint32_t s; memcpy(&s, reply + 1, 4);
        if (reply[0] == cmd && s == seq) return 0;
    }
    return -1;
}

static void dump_controls(const char *tag, const uint8_t *c) {
    printf("  %s:", tag);
    for (int i = 0; i < 22; i++) printf(" %02x", c[i]);
    printf("\n");
}

/* Set the three per-deck switch bytes to v (01 = USB audio, 00 = thru). */
static int set_usb_switches(uint8_t v) {
    static const int idx[] = {8, 14, 20};
    uint8_t in[HID_REPORT], c[22];
    if (hid_request(0x32, NULL, 0, in)) { printf("  warning: could not read controls\n"); return -1; }
    memcpy(c, in + 5, 22);
    dump_controls("controls before", c);
    int changed = 0, err = 0;
    for (int i = 0; i < 3; i++) {
        if (c[idx[i]] == v) continue;
        uint8_t p[3] = {(uint8_t)idx[i], 1, v};
        if (hid_request(0x33, p, 3, in)) { printf("  warning: control write %d got no reply\n", idx[i]); err = -1; }
        changed = 1;
    }
    if (changed && hid_request(0x32, NULL, 0, in) == 0) dump_controls("controls after ", in + 5);
    return err;
}

/* Asynchronous heartbeat, driven from the USB event thread. */
static struct libusb_transfer *g_hb_out, *g_hb_in;
static uint8_t g_hb_out_buf[HID_REPORT], g_hb_in_buf[HID_REPORT];
static uint32_t g_hb_seq;
static int g_hb_busy;
static double g_hb_last;

static void LIBUSB_CALL hb_out_cb(struct libusb_transfer *t) {
    if (t->status == LIBUSB_TRANSFER_COMPLETED) g_hb_sent++;
    g_hb_busy = 0;
    U.inflight--;
}

static void LIBUSB_CALL hb_in_cb(struct libusb_transfer *t) {
    if (t->status == LIBUSB_TRANSFER_COMPLETED && t->actual_length >= 5) {
        uint32_t s; memcpy(&s, t->buffer + 1, 4);
        if (t->buffer[0] == 0x37 && s == g_hb_seq) g_hb_replies++;
    }
    if (U.stop || t->status == LIBUSB_TRANSFER_CANCELLED || t->status == LIBUSB_TRANSFER_NO_DEVICE) { U.inflight--; return; }
    if (libusb_submit_transfer(t) != 0) U.inflight--;
}

static int heartbeat_start(void) {
    g_hb_out = libusb_alloc_transfer(0);
    g_hb_in = libusb_alloc_transfer(0);
    libusb_fill_interrupt_transfer(g_hb_out, g_h, EP_HID_OUT, g_hb_out_buf, HID_REPORT, hb_out_cb, NULL, 500);
    libusb_fill_interrupt_transfer(g_hb_in, g_h, EP_HID_IN, g_hb_in_buf, HID_REPORT, hb_in_cb, NULL, 0);
    if (libusb_submit_transfer(g_hb_in)) return -1;
    U.inflight++;
    return 0;
}

static void heartbeat_tick(void) {
    if (!g_hb_out || g_hb_busy || ms_now() - g_hb_last < HEARTBEAT_MS) return;
    g_hb_last = ms_now();
    g_hb_seq = g_hid_seq++;
    memset(g_hb_out_buf, 0, sizeof g_hb_out_buf);
    g_hb_out_buf[0] = 0x37;
    memcpy(g_hb_out_buf + 1, &g_hb_seq, 4);
    arc4random_buf(g_hb_out_buf + 5, 8);
    if (libusb_submit_transfer(g_hb_out) == 0) { g_hb_busy = 1; U.inflight++; }
}

static void heartbeat_cancel(void) {
    if (g_hb_in) libusb_cancel_transfer(g_hb_in);
    if (g_hb_out && g_hb_busy) libusb_cancel_transfer(g_hb_out);
}

static void make_realtime(void) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double ms = 1e6 * tb.denom / tb.numer; /* mach ticks per ms */
    thread_time_constraint_policy_data_t p = { (uint32_t)(1 * ms), (uint32_t)(0.3 * ms), (uint32_t)(1 * ms), 1 };
    if (thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                          (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT) != KERN_SUCCESS)
        printf("  warning: could not make USB thread real-time\n");
}

static void *usb_thread(void *arg) {
    (void)arg;
    make_realtime();
    struct timeval tv = {0, 20000};
    double stopped_at = 0;
    while (U.inflight > 0) {
        libusb_handle_events_timeout(g_ctx, &tv);
        if (g_stop && !U.stop) U.stop = 1;
        if (!U.stop) heartbeat_tick();
        else if (!stopped_at) stopped_at = ms_now();
        else if (ms_now() - stopped_at > 2000) break; /* device gone, transfers stuck */
    }
    return NULL;
}

/* ---- CoreAudio side ---- */
static AudioDeviceID find_device(const char *needle) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz)) return 0;
    int n = sz / sizeof(AudioDeviceID);
    AudioDeviceID *ids = malloc(sz), found = 0;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    for (int i = 0; i < n && !found; i++) {
        CFStringRef name = NULL; UInt32 s = sizeof name;
        AudioObjectPropertyAddress na = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &s, &name) || !name) continue;
        char buf[256];
        if (CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8) && strstr(buf, needle)) {
            found = ids[i];
            printf("  device: %s (id %u)\n", buf, (unsigned)found);
        }
        CFRelease(name);
    }
    free(ids);
    return found;
}

static uint64_t g_io_calls, g_bad_format;

/* Copy channel ch (0-based, counted across all buffers) of frame f. */
static float *chan_ptr(AudioBufferList *bl, int ch, UInt32 f) {
    for (UInt32 b = 0; b < bl->mNumberBuffers; b++) {
        AudioBuffer *ab = &bl->mBuffers[b];
        if (ch < (int)ab->mNumberChannels) return (float *)ab->mData + f * ab->mNumberChannels + ch;
        ch -= ab->mNumberChannels;
    }
    return NULL;
}

static OSStatus io_proc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in,
                        const AudioTimeStamp *in_t, AudioBufferList *out, const AudioTimeStamp *out_t, void *ctx) {
    (void)dev; (void)now; (void)in_t; (void)out_t; (void)ctx;
    g_io_calls++;
    static double last; note_gap(&last, &g_gap_io);
    UInt32 frames = 0;
    if (out->mNumberBuffers && out->mBuffers[0].mNumberChannels)
        frames = out->mBuffers[0].mDataByteSize / (sizeof(float) * out->mBuffers[0].mNumberChannels);
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);

    /* BlackHole 7..12 -> SL3 outputs */
    AudioBufferList *inl = (AudioBufferList *)in;
    UInt32 in_frames = 0;
    if (inl->mNumberBuffers && inl->mBuffers[0].mNumberChannels)
        in_frames = inl->mBuffers[0].mDataByteSize / (sizeof(float) * inl->mBuffers[0].mNumberChannels);
    for (UInt32 f = 0; f < in_frames; f++) {
        float fr[NCH];
        for (int c = 0; c < NCH; c++) { float *p = chan_ptr(inl, BH_OUT_FIRST + c, f); fr[c] = p ? *p : 0; }
        ring_push(&g_out, fr);
        peak(g_pk_out, fr);
    }

    /* SL3 inputs -> BlackHole 1..6 */
    reader_update(&rd_in);
    g_io_frames += frames;
    for (UInt32 f = 0; f < frames; f++) {
        float fr[NCH];
        reader_read(&rd_in, fr);
        for (int c = 0; c < NCH; c++) { float *p = chan_ptr(out, BH_IN_FIRST + c, f); if (p) *p = fr[c]; }
    }
    return noErr;
}

static int set_prop(AudioDeviceID d, AudioObjectPropertySelector sel, AudioObjectPropertyScope sc, UInt32 sz, const void *v) {
    AudioObjectPropertyAddress a = {sel, sc, kAudioObjectPropertyElementMain};
    return AudioObjectSetPropertyData(d, &a, 0, NULL, sz, v);
}
static int get_prop(AudioDeviceID d, AudioObjectPropertySelector sel, AudioObjectPropertyScope sc, UInt32 sz, void *v) {
    AudioObjectPropertyAddress a = {sel, sc, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, v);
}

/* ---- SL3 session: open, stream, and tear down (repeatable for reconnects) ---- */
static libusb_device_handle *g_dev;
static struct libusb_transfer *g_cx[CAP_NXF], *g_px[PLAY_NXF];
static int g_hid_ok;
static pthread_t g_usb_th;

static int sl3_connect(void) {
    libusb_device_handle *h = libusb_open_device_with_vid_pid(g_ctx, VID, PID);
    if (!h) return -1;
    printf("[SL3] connected\n");
    int cfg = 0; libusb_get_configuration(h, &cfg);
    if (cfg != 1) libusb_set_configuration(h, 1);
    libusb_claim_interface(h, IF_AC);
    int r;
    if ((r = libusb_claim_interface(h, IF_CAP)) || (r = libusb_set_interface_alt_setting(h, IF_CAP, 1)) ||
        (r = libusb_claim_interface(h, IF_PLAY)) || (r = libusb_set_interface_alt_setting(h, IF_PLAY, 1))) {
        printf("  interface setup failed: %s\n", libusb_error_name(r));
        libusb_close(h);
        return -1;
    }

    /* fresh USB-side state; the CoreAudio side keeps running throughout */
    memset(&U, 0, sizeof U);
    fifo_w = fifo_r = 0;
    rd_out.primed = 0;
    g_hb_out = g_hb_in = NULL;
    g_hb_busy = 0; g_hb_sent = g_hb_replies = 0;

    for (int i = 0; i < CAP_NXF; i++) {
        g_cx[i] = libusb_alloc_transfer(CAP_PKTS);
        libusb_fill_iso_transfer(g_cx[i], h, EP_CAP, malloc(CAP_PKTS * PKT_MAX), CAP_PKTS * PKT_MAX, CAP_PKTS, cap_cb, NULL, 1000);
        libusb_set_iso_packet_lengths(g_cx[i], PKT_MAX);
        if (libusb_submit_transfer(g_cx[i]) == 0) U.inflight++;
    }
    struct timeval tv = {0, 10000};
    for (int i = 0; i < 5; i++) libusb_handle_events_timeout(g_ctx, &tv);
    fifo_r = fifo_w;
    for (int i = 0; i < PLAY_NXF; i++) {
        g_px[i] = libusb_alloc_transfer(PLAY_PKTS);
        libusb_fill_iso_transfer(g_px[i], h, EP_PLAY, malloc(PLAY_PKTS * PKT_MAX), 0, PLAY_PKTS, play_cb, NULL, 1000);
        fill_play(g_px[i]);
        if (libusb_submit_transfer(g_px[i]) == 0) U.inflight++;
    }
    g_h = g_dev = h;
    g_hid_ok = (r = libusb_claim_interface(h, IF_HID)) == 0;
    if (!g_hid_ok) printf("  warning: claim interface 3 failed (%s); box will stay in thru\n", libusb_error_name(r));
    else {
        set_usb_switches(0x01);
        if (heartbeat_start()) printf("  warning: could not start heartbeat\n");
    }
    pthread_create(&g_usb_th, NULL, usb_thread, NULL);
    fflush(stdout);
    return 0;
}

/* present: the box is still there, so hand the decks back to thru. */
static void sl3_disconnect(int present) {
    libusb_device_handle *h = g_dev;
    U.stop = 1;
    for (int i = 0; i < CAP_NXF; i++) libusb_cancel_transfer(g_cx[i]);
    for (int i = 0; i < PLAY_NXF; i++) libusb_cancel_transfer(g_px[i]);
    heartbeat_cancel();
    pthread_join(g_usb_th, NULL);
    int drained = U.inflight <= 0;
    if (present && g_hid_ok) {
        printf("  returning decks to thru\n");
        set_usb_switches(0x00);
    }
    if (g_hid_ok) libusb_release_interface(h, IF_HID);
    printf("  heartbeat: sent %ld, replies %ld\n", g_hb_sent, g_hb_replies);
    if (present) {
        libusb_set_interface_alt_setting(h, IF_PLAY, 0);
        libusb_set_interface_alt_setting(h, IF_CAP, 0);
    }
    libusb_release_interface(h, IF_PLAY);
    libusb_release_interface(h, IF_CAP);
    libusb_release_interface(h, IF_AC);
    /* transfers still in flight after a yank can't be freed safely; leak them */
    if (drained) {
        for (int i = 0; i < CAP_NXF; i++) { free(g_cx[i]->buffer); libusb_free_transfer(g_cx[i]); }
        for (int i = 0; i < PLAY_NXF; i++) { free(g_px[i]->buffer); libusb_free_transfer(g_px[i]); }
        if (g_hb_out) libusb_free_transfer(g_hb_out);
        if (g_hb_in) libusb_free_transfer(g_hb_in);
    }
    g_hb_out = g_hb_in = NULL;
    libusb_close(h);
    g_dev = g_h = NULL;
    fflush(stdout);
}

int main(int argc, char **argv) {
    const char *devname = "BlackHole 16ch";
    UInt32 bufsz = 256;
    double target = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--device") && i + 1 < argc) devname = argv[++i];
        else if (!strcmp(argv[i], "--buffer") && i + 1 < argc) bufsz = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--target") && i + 1 < argc) target = atof(argv[++i]);
        else { fprintf(stderr, "usage: %s [--device NAME] [--buffer FRAMES] [--target FRAMES]\n", argv[0]); return 2; }
    }
    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);
    signal(SIGHUP, on_sigint);   /* terminal closed: still hand the decks back to thru */
    signal(SIGPIPE, SIG_IGN);    /* stdout may be gone after SIGHUP */

    printf("[1] CoreAudio\n");
    AudioDeviceID dev = find_device(devname);
    if (!dev) { printf("  no device matching \"%s\"\n", devname); return 1; }
    Float64 rate = RATE;
    if (set_prop(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, sizeof rate, &rate))
        printf("  warning: could not set 44100 Hz\n");
    usleep(200000);
    get_prop(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, sizeof rate, &rate);
    set_prop(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, sizeof bufsz, &bufsz);
    get_prop(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, sizeof bufsz, &bufsz);
    printf("  rate %.0f Hz, buffer %u frames\n", rate, (unsigned)bufsz);
    if (rate != RATE) { printf("  device is not at 44100 Hz; set it in Audio MIDI Setup\n"); return 1; }
    AudioStreamBasicDescription fmt; UInt32 fsz = sizeof fmt;
    AudioObjectPropertyAddress sa = {kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(dev, &sa, 0, NULL, &fsz, &fmt) == 0) {
        printf("  stream format: %u ch, %u bits, %s\n", (unsigned)fmt.mChannelsPerFrame, (unsigned)fmt.mBitsPerChannel,
               (fmt.mFormatFlags & kAudioFormatFlagIsFloat) ? "float" : "NOT float");
        if (!(fmt.mFormatFlags & kAudioFormatFlagIsFloat) || fmt.mBitsPerChannel != 32 || fmt.mChannelsPerFrame < 12) {
            printf("  need a 32-bit float device with at least 12 channels\n"); return 1;
        }
    }

    if (target <= 0) target = 4.0 * bufsz;
    printf("  ring target %.0f frames (%.1f ms per direction)\n", target, target / RATE * 1000);
    reader_init(&rd_in, &g_in, target, 0.02);        /* updated once per IO cycle */
    reader_init(&rd_out, &g_out, target, 0.0005);    /* updated once per USB transfer (1 ms) */

    libusb_init(&g_ctx);
    AudioDeviceIOProcID pid;
    if (AudioDeviceCreateIOProcID(dev, io_proc, NULL, &pid) || AudioDeviceStart(dev, pid)) {
        printf("  could not start CoreAudio IOProc\n"); return 1;
    }
    printf("[2] Running. SL3 in 1-6 -> %s 1-6, %s 7-12 -> SL3 out 1-6. Ctrl-C to stop.\n", devname, devname);
    printf("    If the SL3 is unplugged or loses power, the bridge waits for it and reconnects.\n");

    int connected = 0, waiting_msg = 0;
    double t_start = 0; uint64_t uf0 = 0, if0 = 0; int warm = 0;
    while (!g_stop) {
        if (!connected) {
            if (sl3_connect() == 0) {
                connected = 1; waiting_msg = 0; warm = 0;
                continue;
            }
            if (!waiting_msg) { printf("[SL3] waiting for the SL3...\n"); fflush(stdout); waiting_msg = 1; }
            usleep(500000);
            continue;
        }
        if (U.stop) {
            printf("[SL3] lost the SL3 (unplugged or powered off); it will be in thru until it comes back\n");
            sl3_disconnect(0);
            connected = 0;
            continue;
        }
        sleep(1);
        if (++warm == 3) { t_start = ms_now(); uf0 = g_usb_frames; if0 = g_io_frames; }
        if (warm > 3) { double el = (ms_now() - t_start) / 1000; printf("  rates: usb %.1f Hz, coreaudio %.1f Hz\n", (g_usb_frames - uf0) / el, (g_io_frames - if0) / el); }
        printf("  in: fill %5llu ratio %.6f under %llu over %llu reset %llu | out: fill %5llu ratio %.6f under %llu over %llu reset %llu | usb err %ld/%ld/%ld hb %ld/%ld | max gap usb %.1f ms io %.1f ms\n",
               (unsigned long long)ring_fill(&g_in), rd_in.ratio, (unsigned long long)rd_in.underruns, (unsigned long long)g_in.overruns, (unsigned long long)rd_in.resets,
               (unsigned long long)ring_fill(&g_out), rd_out.ratio, (unsigned long long)rd_out.underruns, (unsigned long long)g_out.overruns, (unsigned long long)rd_out.resets,
               U.cap_err, U.play_err, U.xfer_err, g_hb_replies, g_hb_sent, g_gap_usb, g_gap_io);
        g_gap_usb = g_gap_io = 0;
        printf("  peaks dBFS  SL3 in 1-6:");
        for (int c = 0; c < NCH; c++) { printf(" %6.1f", dbfs(g_pk_in[c])); g_pk_in[c] = 0; }
        printf("  | BH 7-12 -> SL3 out 1-6:");
        for (int c = 0; c < NCH; c++) { printf(" %6.1f", dbfs(g_pk_out[c])); g_pk_out[c] = 0; }
        printf("\n");
        fflush(stdout);
    }

    printf("[3] Stopping\n");
    AudioDeviceStop(dev, pid);
    AudioDeviceDestroyIOProcID(dev, pid);
    if (connected) sl3_disconnect(1);
    libusb_exit(g_ctx);
    (void)g_bad_format;
    return 0;
}
