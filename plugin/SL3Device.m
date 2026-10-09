// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * SL3 Core Audio device: an AudioServerPlugIn that drives the SL3 directly
 * through IOUSBHost and publishes it as one 6-in/6-out device at 44.1 kHz.
 *
 * The device runs on the SL3's own clock: its sample time is the count of
 * captured frames, and GetZeroTimeStamp maps sample time to host time with
 * the controller timestamps of the capture transfers. No resampling here;
 * Core Audio handles clock drift against other devices like any USB device.
 *
 * Rings are indexed by device sample time, with a per-frame stamp holding
 * the sample time last written to that slot, so stale or missing frames
 * read as silence.
 *
 * USB session (interfaces 1-3, heartbeat, switch bytes) follows
 * src/iousbhost_streams.m. It starts on the first StartIO and stops on the
 * last StopIO, handing the decks back to thru.
 *
 * Log: log stream --predicate 'subsystem == "sl3.device"'
 */
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>

#define VID 0x1cc5
#define PID 0x0001
#define IF_PLAY 1
#define IF_CAP  2
#define IF_HID  3
#define EP_PLAY 0x06
#define EP_CAP  0x82
#define EP_HID_OUT 0x01
#define EP_HID_IN  0x81
#define HID_REPORT 64
#define HEARTBEAT_MS 100
#define NCH 6
#define FRAME_BYTES 18
#define PKT_MAX 126
#define RATE 44100.0
#define CAP_PKTS 8      /* microframes per transfer: 1 ms, must be a multiple of 8 */
#define CAP_NXF 64      /* 64 ms of capture queued */
#define PLAY_PKTS 8
/* Playback queue depth in ms. Completions are sometimes delivered 15-20 ms
 * late; a shorter queue then runs dry and a few ms of output are lost. */
#ifndef PLAY_NXF
#define PLAY_NXF 20
#endif
#define RING 16384      /* frames, power of two */
#define ZTS_PERIOD 2048 /* frames between zero timestamps */
/* Safety offsets (frames): input must lag the hardware by the worst
 * completion delay, output must lead it by the playback queue plus margin. */
#ifndef IN_SAFETY
#define IN_SAFETY  800
#endif
#ifndef OUT_SAFETY
#define OUT_SAFETY (PLAY_NXF * 44 + 80)
#endif
/* Converter latency (frames) beyond the USB timeline. sl3loop measured a
 * steady 47-frame round trip (deck 3 out -> deck 2 in, line), split evenly. */
#ifndef LAT_IN
#define LAT_IN  23
#endif
#ifndef LAT_OUT
#define LAT_OUT 24
#endif

enum { kObjPlugIn = kAudioObjectPlugInObject, kObjDevice = 2, kObjStreamIn = 3, kObjStreamOut = 4 };
#define DEVICE_UID CFSTR("SL3Device_UID")
#define MODEL_UID  CFSTR("SL3Device_Model")

static os_log_t g_log;
static AudioServerPlugInHostRef g_host;
static ULONG g_refs = 1;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_io_clients;        /* StartIO count */
static double g_tick_ns;        /* ns per mach tick */

/* ---- sample-time rings ---- */
typedef struct {
    float buf[RING * NCH];
    _Atomic uint64_t stamp[RING];   /* sample time + 1 written to this slot; 0 = never */
} sring_t;
static sring_t g_in, g_out;

static void sring_put(sring_t *r, uint64_t s, const float *fr) {
    unsigned i = s & (RING - 1);
    memcpy(&r->buf[i * NCH], fr, sizeof(float) * NCH);
    atomic_store_explicit(&r->stamp[i], s + 1, memory_order_release);
}
static int sring_get(sring_t *r, uint64_t s, float *fr) {
    unsigned i = s & (RING - 1);
    if (atomic_load_explicit(&r->stamp[i], memory_order_acquire) != s + 1) { memset(fr, 0, sizeof(float) * NCH); return 0; }
    memcpy(fr, &r->buf[i * NCH], sizeof(float) * NCH);
    return 1;
}
static void sring_clear(sring_t *r) { for (int i = 0; i < RING; i++) atomic_store(&r->stamp[i], 0); }

static struct { long cap_err, play_err, xfer_err, in_miss, out_miss, hb_sent, hb_replies, resyncs, in_jumps, out_jumps, play_resyncs; double max_err_us, rate, max_delay_ms; } S;

/* ---- clock model: host ticks = a_host + (sample - a_s) * tpf ---- */
static struct { _Atomic uint32_t seq; double a_s, a_host, tpf; uint64_t seed; int valid; } g_clk;

static void clk_read(double *a_s, double *a_host, double *tpf, uint64_t *seed, int *valid) {
    uint32_t q;
    do {
        while ((q = atomic_load_explicit(&g_clk.seq, memory_order_acquire)) & 1) ;
        *a_s = g_clk.a_s; *a_host = g_clk.a_host; *tpf = g_clk.tpf; *seed = g_clk.seed; *valid = g_clk.valid;
        atomic_thread_fence(memory_order_acquire);
    } while (atomic_load_explicit(&g_clk.seq, memory_order_relaxed) != q);
}
static void clk_write(double a_s, double a_host, double tpf, int new_seed) {
    atomic_fetch_add_explicit(&g_clk.seq, 1, memory_order_acq_rel);
    g_clk.a_s = a_s; g_clk.a_host = a_host; g_clk.tpf = tpf; g_clk.valid = 1;
    if (new_seed) g_clk.seed++;
    atomic_fetch_add_explicit(&g_clk.seq, 1, memory_order_release);
}
static double clk_sample_at(double host) {
    double a_s, a_h, tpf; uint64_t seed; int v;
    clk_read(&a_s, &a_h, &tpf, &seed, &v);
    return a_s + (host - a_h) / tpf;
}

/* SL3 rate from the oldest and newest of the last RATE_N (timestamp, frames)
 * pairs, one per 100 ms (as rate_est_t in src/sl3bridge.c). */
#define RATE_N 100
static struct { double t[RATE_N], f[RATE_N]; int n, i; } g_rate;
static double rate_add(double t_ms, double frames) {
    if (g_rate.n && t_ms - g_rate.t[(g_rate.i + RATE_N - 1) % RATE_N] < 100) return 0;
    g_rate.t[g_rate.i] = t_ms; g_rate.f[g_rate.i] = frames;
    g_rate.i = (g_rate.i + 1) % RATE_N;
    if (g_rate.n < RATE_N) g_rate.n++;
    if (g_rate.n < 20) return 0;
    int o = (g_rate.i + RATE_N - g_rate.n) % RATE_N, l = (g_rate.i + RATE_N - 1) % RATE_N;
    double r = (g_rate.f[l] - g_rate.f[o]) / (g_rate.t[l] - g_rate.t[o]) * 1000;
    return fabs(r / RATE - 1) < 0.01 ? r : 0;
}

static int g_reanchor, g_cap_done;   /* both only touched on the USB queue once streaming */

/* One capture transfer done: frames up to sample s_end were stamped at host tick t_end. */
static void clk_update(double s_end, double t_end) {
    double a_s, a_h, tpf; uint64_t seed; int v;
    clk_read(&a_s, &a_h, &tpf, &seed, &v);
    double r = rate_add(t_end * g_tick_ns / 1e6, s_end);
    if (r > 0) tpf = 1e9 / r / g_tick_ns;
    if (!v || g_reanchor) { g_reanchor = 0; clk_write(s_end, t_end, v ? tpf : 1e9 / RATE / g_tick_ns, 1); return; }
    if (r > 0) S.rate = r;
    double pred = a_h + (s_end - a_s) * tpf, err = t_end - pred;
    if (fabs(err) * g_tick_ns / 1e3 > S.max_err_us) S.max_err_us = fabs(err) * g_tick_ns / 1e3;
    if (fabs(err) > 2e6 / g_tick_ns) { S.resyncs++; clk_write(s_end, t_end, tpf, 1); return; }   /* >2 ms off: resync */
    clk_write(s_end, pred + 0.02 * err, tpf, 0);
}

/* ---- USB session ---- */
static dispatch_queue_t g_q;
static IOUSBHostInterface *g_cap, *g_play, *g_hid;
static IOUSBHostPipe *g_cpipe, *g_ppipe, *g_hout, *g_hin;
static NSMutableData *g_cbuf[CAP_NXF], *g_pbuf[PLAY_NXF], *g_req_out, *g_req_in, *g_hb_out, *g_hb_in;
static IOUSBHostIsochronousTransaction g_ctl[CAP_NXF][CAP_PKTS], g_ptl[PLAY_NXF][PLAY_PKTS];
static uint64_t g_cframe, g_pframe;
static _Atomic int g_inflight, g_hb_inflight, g_stop;
static uint64_t g_cap_s, g_play_s;      /* next capture / playback sample time */
static int g_play_resync;
#define FIFO_N 4096
static int g_fifo[FIFO_N];
static unsigned g_fifo_w, g_fifo_r;
static double g_acc;
static uint32_t g_hid_seq = 1, g_hb_seq;
static int g_hb_busy;
static dispatch_source_t g_hb_timer;
static float g_pk_hal[NCH], g_pk_usb[NCH];   /* output peaks written by the HAL / sent to USB */
static uint64_t g_in_next, g_out_next;   /* expected next HAL sample times */
static dispatch_source_t g_stat_timer;

static void make_realtime(void) {
    static __thread int done;
    if (done) return;
    done = 1;
    double ms = 1e6 / g_tick_ns;
    thread_time_constraint_policy_data_t p = { (uint32_t)(1 * ms), (uint32_t)(0.3 * ms), (uint32_t)(1 * ms), 1 };
    thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                      (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

static io_service_t usb_find(const char *cls, int ifnum) {
    CFMutableDictionaryRef m = IOServiceMatching(cls);
    NSMutableDictionary *p = [@{@"idVendor": @VID, @"idProduct": @PID} mutableCopy];
    if (ifnum >= 0) p[@"bInterfaceNumber"] = @(ifnum);
    CFDictionarySetValue(m, CFSTR(kIOPropertyMatchKey), (__bridge CFDictionaryRef)p);
    return IOServiceGetMatchingService(kIOMainPortDefault, m);
}
static int usb_present(void) { io_service_t s = usb_find("IOUSBHostDevice", -1); if (s) IOObjectRelease(s); return s != 0; }

static IOUSBHostInterface *usb_open(int ifnum) {
    io_service_t s = usb_find("IOUSBHostInterface", ifnum);
    if (!s) return nil;
    NSError *e = nil;
    IOUSBHostInterface *i = [[IOUSBHostInterface alloc] initWithIOService:s options:IOUSBHostObjectInitOptionsNone
                                                                    queue:g_q error:&e interestHandler:nil];
    IOObjectRelease(s);
    if (!i) os_log_error(g_log, "open interface %d failed: %{public}@", ifnum, e.localizedDescription);
    return i;
}

static int usb_fatal(IOReturn st) {
    return st == kIOReturnAborted || st == kIOReturnNoDevice || st == kIOReturnNotAttached || st == kIOReturnOffline;
}

/* Host tick at which USB frame f starts, from the interface's current frame. */
static double usb_frame_host(IOUSBHostInterface *intf, uint64_t f) {
    uint64_t t = 0;
    uint64_t cur = [intf frameNumberWithTime:(IOUSBHostTime *)&t];
    return (double)t + ((double)f - (double)cur) * 1e6 / g_tick_ns;
}

static BOOL usb_enqueue(IOUSBHostPipe *pipe, IOUSBHostInterface *intf, NSMutableData *d, IOUSBHostIsochronousTransaction *tl,
                        int n, uint64_t *frame, IOUSBHostIsochronousTransactionCompletionHandler h) {
    for (int attempt = 0; attempt < 2; attempt++) {
        NSError *e = nil;
        if ([pipe enqueueIORequestWithData:d transactionList:tl transactionListCount:n firstFrameNumber:*frame
                                   options:IOUSBHostIsochronousTransferOptionsNone error:&e completionHandler:h]) {
            *frame += n / 8;
            return YES;
        }
        S.xfer_err++;
        uint64_t now = [intf frameNumberWithTime:NULL];
        os_log_error(g_log, "%{public}s enqueue for frame %llu failed (now %llu): %{public}@", pipe == g_cpipe ? "capture" : "playback",
                     *frame, now, e.localizedDescription);
        *frame = now + 2;
        if (pipe == g_ppipe) g_play_resync = 1;
    }
    return NO;
}

static void cap_submit(int i) {
    IOUSBHostIsochronousTransaction *tl = g_ctl[i];
    for (int k = 0; k < CAP_PKTS; k++) tl[k] = (IOUSBHostIsochronousTransaction){ .requestCount = PKT_MAX, .offset = k * PKT_MAX };
    NSMutableData *d = g_cbuf[i];
    BOOL ok = usb_enqueue(g_cpipe, g_cap, d, tl, CAP_PKTS, &g_cframe, ^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
        make_realtime();
        if (st == kIOReturnSuccess) {
            const uint8_t *p = d.bytes;
            for (int k = 0; k < CAP_PKTS; k++) {
                if (done[k].status != kIOReturnSuccess) S.cap_err++;
                int n = done[k].completeCount / FRAME_BYTES;
                if (g_fifo_w - g_fifo_r < FIFO_N) g_fifo[g_fifo_w++ % FIFO_N] = n;
                for (int f = 0; f < n; f++) {
                    const uint8_t *q = p + done[k].offset + f * FRAME_BYTES;
                    float fr[NCH];
                    for (int c = 0; c < NCH; c++) {
                        int32_t v = q[c * 3] | q[c * 3 + 1] << 8 | q[c * 3 + 2] << 16;
                        if (v & 0x800000) v -= 1 << 24;
                        fr[c] = v / 8388608.0f;
                    }
                    sring_put(&g_in, g_cap_s++, fr);
                }
            }
            g_cap_done++;
            double dl = ((double)mach_absolute_time() - (double)done[CAP_PKTS - 1].timeStamp) * g_tick_ns / 1e6;
            if (done[CAP_PKTS - 1].timeStamp && dl > S.max_delay_ms) S.max_delay_ms = dl;
            if (done[CAP_PKTS - 1].timeStamp) clk_update((double)g_cap_s, (double)done[CAP_PKTS - 1].timeStamp);
        } else if (!usb_fatal(st)) S.xfer_err++;
        if (st != kIOReturnSuccess && !g_stop) os_log_error(g_log, "capture transfer status 0x%x", st);
        if (g_stop || usb_fatal(st)) { g_stop = 1; g_inflight--; return; }
        cap_submit(i);
    });
    if (!ok) { g_inflight--; g_stop = 1; }
}

static void play_submit(int i) {
    IOUSBHostIsochronousTransaction *tl = g_ptl[i];
    uint8_t *p = g_pbuf[i].mutableBytes;
    if (g_play_resync) {   /* schedule slipped: re-derive the sample time of this transfer's first frame */
        g_play_resync = 0;
        S.play_resyncs++;
        g_play_s = (uint64_t)llround(clk_sample_at(usb_frame_host(g_play, g_pframe)));
    }
    int off = 0;
    for (int k = 0; k < PLAY_PKTS; k++) {
        int n;
        if (g_fifo_r != g_fifo_w) n = g_fifo[g_fifo_r++ % FIFO_N];
        else { g_acc += RATE * 125e-6; n = (int)g_acc; g_acc -= n; }
        if (n < 0 || n > PKT_MAX / FRAME_BYTES) n = 5;
        for (int f = 0; f < n; f++) {
            float fr[NCH];
            if (!sring_get(&g_out, g_play_s, fr)) S.out_miss++;
            for (int c = 0; c < NCH; c++) { float a = fabsf(fr[c]); if (a > g_pk_usb[c]) g_pk_usb[c] = a; }
            g_play_s++;
            uint8_t *q = p + off + f * FRAME_BYTES;
            for (int c = 0; c < NCH; c++) {
                float v = fr[c] > 1 ? 1 : fr[c] < -1 ? -1 : fr[c];
                int32_t x = (int32_t)lrintf(v * 8388607.0f);
                q[c * 3] = x; q[c * 3 + 1] = x >> 8; q[c * 3 + 2] = x >> 16;
            }
        }
        tl[k] = (IOUSBHostIsochronousTransaction){ .requestCount = (uint32_t)(n * FRAME_BYTES), .offset = (uint32_t)off };
        off += n * FRAME_BYTES;
    }
    BOOL ok = usb_enqueue(g_ppipe, g_play, g_pbuf[i], tl, PLAY_PKTS, &g_pframe, ^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
        make_realtime();
        if (st == kIOReturnSuccess) { for (int k = 0; k < PLAY_PKTS; k++) if (done[k].status != kIOReturnSuccess) S.play_err++; }
        else if (!usb_fatal(st)) S.xfer_err++;
        if (st != kIOReturnSuccess && !g_stop) os_log_error(g_log, "playback transfer status 0x%x", st);
        if (g_stop || usb_fatal(st)) { g_stop = 1; g_inflight--; return; }
        play_submit(i);
    });
    if (!ok) { g_inflight--; g_stop = 1; }
}

/* Interface 3: synchronous request, only while the heartbeat is not running. */
static int hid_request(uint8_t cmd, const uint8_t *payload, int len, uint8_t *reply) {
    uint8_t *out = g_req_out.mutableBytes;
    uint32_t seq = g_hid_seq++;
    memset(out, 0, HID_REPORT);
    out[0] = cmd;
    memcpy(out + 1, &seq, 4);
    if (len) memcpy(out + 5, payload, len);
    NSUInteger n = 0;
    if (![g_hout sendIORequestWithData:g_req_out bytesTransferred:&n completionTimeout:0 error:nil]) return -1;
    uint64_t t0 = mach_absolute_time();
    while ((mach_absolute_time() - t0) * g_tick_ns < 500e6) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block IOReturn st = kIOReturnError;
        __block NSUInteger got = 0;
        if (![g_hin enqueueIORequestWithData:g_req_in completionTimeout:0 error:nil
                           completionHandler:^(IOReturn s2, NSUInteger n2) { st = s2; got = n2; dispatch_semaphore_signal(sem); }])
            return -1;
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC))) {
            [g_hin abortWithError:nil];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        }
        if (st != kIOReturnSuccess || got < 5) continue;
        memcpy(reply, g_req_in.bytes, HID_REPORT);
        uint32_t s; memcpy(&s, reply + 1, 4);
        if (reply[0] == cmd && s == seq) return 0;
    }
    return -1;
}

/* The 22 control bytes as hex, grouped per 6-byte deck block (indices 3-8, 9-14, 15-20). */
static void log_controls(const char *tag, const uint8_t *c) {
    char b[100]; int o = 0;
    for (int i = 0; i < 22; i++) o += snprintf(b + o, sizeof b - o, "%s%02x", i == 3 || i == 9 || i == 15 || i == 21 ? " | " : i ? " " : "", c[i]);
    os_log(g_log, "%{public}s: %{public}s", tag, b);
}

/* Per-deck switch bytes (indices 8, 14, 20): 01 = USB audio, 00 = thru. */
static int set_usb_switches(uint8_t v) {
    static const int idx[] = {8, 14, 20};
    uint8_t in[HID_REPORT];
    if (hid_request(0x32, NULL, 0, in)) { os_log_error(g_log, "could not read controls"); return -1; }
    log_controls(v ? "controls before USB" : "controls before thru", in + 5);
    int err = 0, changed = 0;
    for (int i = 0; i < 3; i++) {
        if (in[5 + idx[i]] == v) continue;
        uint8_t p[3] = {(uint8_t)idx[i], 1, v};
        uint8_t r[HID_REPORT];
        if (hid_request(0x33, p, 3, r)) err = -1;
        changed = 1;
    }
    if (changed && hid_request(0x32, NULL, 0, in) == 0) log_controls("controls after", in + 5);
    return err;
}

static void hb_read(void) {
    g_hb_inflight++;
    BOOL ok = [g_hin enqueueIORequestWithData:g_hb_in completionTimeout:0 error:nil completionHandler:^(IOReturn st, NSUInteger n) {
        const uint8_t *b = g_hb_in.bytes;
        if (st == kIOReturnSuccess && n >= 5) { uint32_t s; memcpy(&s, b + 1, 4); if (b[0] == 0x37 && s == g_hb_seq) S.hb_replies++; }
        g_hb_inflight--;
        if (!g_stop && !usb_fatal(st)) hb_read();
    }];
    if (!ok) g_hb_inflight--;
}

static void hb_tick(void) {
    if (g_stop || g_hb_busy) return;
    uint8_t *b = g_hb_out.mutableBytes;
    g_hb_seq = g_hid_seq++;
    memset(b, 0, HID_REPORT);
    b[0] = 0x37;
    memcpy(b + 1, &g_hb_seq, 4);
    arc4random_buf(b + 5, 8);
    g_hb_busy = 1;
    g_hb_inflight++;
    BOOL ok = [g_hout enqueueIORequestWithData:g_hb_out completionTimeout:0 error:nil completionHandler:^(IOReturn st, NSUInteger n) {
        (void)n;
        if (st == kIOReturnSuccess) S.hb_sent++;
        g_hb_busy = 0;
        g_hb_inflight--;
    }];
    if (!ok) { g_hb_busy = 0; g_hb_inflight--; }
}

static void usb_close(int present);
static int usb_open_all(void);
static void log_stats(const char *tag);
static _Atomic int g_restarting;

/* Streams died while IO is running: tear down and start again, retrying until
 * the box is back or IO stops. The device keeps its timeline; the clock model
 * resyncs with a new seed. */
static void usb_restart(void) {
    pthread_mutex_lock(&g_lock);
    if (g_io_clients > 0) {
        log_stats("restarting");
        int present = usb_present();
        usb_close(present);
        while (g_io_clients > 0 && usb_open_all()) {
            pthread_mutex_unlock(&g_lock);
            sleep(1);
            pthread_mutex_lock(&g_lock);
        }
    }
    g_restarting = 0;
    pthread_mutex_unlock(&g_lock);
}

static void log_stats(const char *tag) {
    char pk[200]; int o = 0;
    o += snprintf(pk + o, sizeof pk - o, "out peaks hal");
    for (int c = 0; c < NCH; c++) { o += snprintf(pk + o, sizeof pk - o, " %.3f", g_pk_hal[c]); g_pk_hal[c] = 0; }
    o += snprintf(pk + o, sizeof pk - o, " usb");
    for (int c = 0; c < NCH; c++) { o += snprintf(pk + o, sizeof pk - o, " %.3f", g_pk_usb[c]); g_pk_usb[c] = 0; }
    os_log(g_log, "%{public}s: %{public}s", tag, pk);
    os_log(g_log, "%{public}s: rate %.3f Hz, max clock err %.0f us, max delivery %.1f ms, resyncs %ld, play resyncs %ld, jumps in %ld out %ld, "
           "miss in %ld out %ld, err cap %ld play %ld xfer %ld, hb %ld/%ld",
           tag, S.rate, S.max_err_us, S.max_delay_ms, S.resyncs, S.play_resyncs, S.in_jumps, S.out_jumps,
           S.in_miss, S.out_miss, S.cap_err, S.play_err, S.xfer_err, S.hb_replies, S.hb_sent);
}

static int usb_open_all(void) {
    if (!g_q) {
        dispatch_queue_attr_t qa = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        g_q = dispatch_queue_create("sl3.usb", qa);
    }
    io_service_t dsvc = usb_find("IOUSBHostDevice", -1);
    if (!dsvc) { os_log_error(g_log, "SL3 not found"); return -1; }
    io_service_t isvc = usb_find("IOUSBHostInterface", IF_CAP);
    if (isvc) IOObjectRelease(isvc);
    else {
        NSError *e = nil;
        IOUSBHostDevice *dev = [[IOUSBHostDevice alloc] initWithIOService:dsvc options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
        if (!dev || ![dev configureWithValue:1 matchInterfaces:YES error:&e]) {
            os_log_error(g_log, "set configuration failed: %{public}@", e.localizedDescription);
            IOObjectRelease(dsvc);
            return -1;
        }
        [dev destroy];
        for (int i = 0; i < 30 && !(isvc = usb_find("IOUSBHostInterface", IF_CAP)); i++) usleep(100000);
        if (isvc) IOObjectRelease(isvc);
    }
    IOObjectRelease(dsvc);

    NSError *e = nil;
    g_cap = usb_open(IF_CAP);
    g_play = usb_open(IF_PLAY);
    if (!g_cap || !g_play || ![g_cap selectAlternateSetting:1 error:&e] || ![g_play selectAlternateSetting:1 error:&e] ||
        !(g_cpipe = [g_cap copyPipeWithAddress:EP_CAP error:&e]) || !(g_ppipe = [g_play copyPipeWithAddress:EP_PLAY error:&e])) {
        os_log_error(g_log, "stream setup failed: %{public}@", e ? e.localizedDescription : @"interface not found");
        usb_close(1);
        return -1;
    }
    for (int i = 0; i < CAP_NXF; i++) if (!(g_cbuf[i] = [g_cap ioDataWithCapacity:CAP_PKTS * PKT_MAX error:&e])) { usb_close(1); return -1; }
    for (int i = 0; i < PLAY_NXF; i++) if (!(g_pbuf[i] = [g_play ioDataWithCapacity:PLAY_PKTS * PKT_MAX error:&e])) { usb_close(1); return -1; }

    memset(&S, 0, sizeof S);
    memset(&g_rate, 0, sizeof g_rate);
    sring_clear(&g_in); sring_clear(&g_out);
    g_stop = 0; g_inflight = 0; g_hb_inflight = 0; g_hb_busy = 0;
    g_fifo_w = g_fifo_r = 0; g_acc = 0;
    /* after a restart, continue the timeline from where the old clock says we are */
    double a_s0, a_h0, tpf0; uint64_t seed0; int valid0;
    clk_read(&a_s0, &a_h0, &tpf0, &seed0, &valid0);
    g_cap_s = valid0 ? (uint64_t)llround(a_s0 + ((double)mach_absolute_time() - a_h0) / tpf0) : 0;
    g_reanchor = 1; g_cap_done = 0;

    /* capture first; once the clock model has an anchor, start playback */
    dispatch_sync(g_q, ^{
        g_cframe = [g_cap frameNumberWithTime:NULL] + 3;
        for (int i = 0; i < CAP_NXF && !g_stop; i++) { g_inflight++; cap_submit(i); }
    });
    usleep(50000);
    __block int started;
    dispatch_sync(g_q, ^{ started = g_cap_done > 0 && !g_reanchor; });
    if (!started || g_stop) { os_log_error(g_log, "capture did not start"); usb_close(1); return -1; }
    dispatch_sync(g_q, ^{
        g_fifo_r = g_fifo_w;
        g_pframe = [g_play frameNumberWithTime:NULL] + 2;
        g_play_resync = 1;
        for (int i = 0; i < PLAY_NXF && !g_stop; i++) { g_inflight++; play_submit(i); }
    });

    /* interface 3: switch the decks to USB audio and keep the heartbeat going */
    if ((g_hid = usb_open(IF_HID)) && (g_hout = [g_hid copyPipeWithAddress:EP_HID_OUT error:&e]) &&
        (g_hin = [g_hid copyPipeWithAddress:EP_HID_IN error:&e]) &&
        (g_req_out = [g_hid ioDataWithCapacity:HID_REPORT error:&e]) && (g_req_in = [g_hid ioDataWithCapacity:HID_REPORT error:&e]) &&
        (g_hb_out = [g_hid ioDataWithCapacity:HID_REPORT error:&e]) && (g_hb_in = [g_hid ioDataWithCapacity:HID_REPORT error:&e])) {
        if (set_usb_switches(0x01)) os_log_error(g_log, "switch write incomplete");
        dispatch_sync(g_q, ^{ hb_read(); });
        g_hb_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_q);
        dispatch_source_set_timer(g_hb_timer, dispatch_time(DISPATCH_TIME_NOW, 0), HEARTBEAT_MS * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(g_hb_timer, ^{ hb_tick(); });
        dispatch_resume(g_hb_timer);
    } else {
        os_log_error(g_log, "interface 3 unavailable; decks stay in thru");
        [g_hid destroy]; g_hid = nil; g_hout = g_hin = nil;
    }
    g_in_next = g_out_next = 0;
    g_stat_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_q);
    dispatch_source_set_timer(g_stat_timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_stat_timer, ^{
        log_stats("stats");
        S.max_err_us = 0; S.max_delay_ms = 0;
        if (g_stop && !g_restarting) { g_restarting = 1; dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ usb_restart(); }); }
    });
    dispatch_resume(g_stat_timer);
    os_log(g_log, "SL3 streaming");
    return 0;
}

/* present: the box is still there, so reset alt settings and hand the decks back to thru. */
static void usb_close(int present) {
    g_stop = 1;
    if (g_hb_timer) { dispatch_source_cancel(g_hb_timer); g_hb_timer = nil; }
    if (g_stat_timer) { dispatch_source_cancel(g_stat_timer); g_stat_timer = nil; }
    [g_cpipe abortWithError:nil];
    [g_ppipe abortWithError:nil];
    [g_hin abortWithError:nil];
    [g_hout abortWithError:nil];
    for (int i = 0; i < 200 && (g_inflight > 0 || g_hb_inflight > 0); i++) usleep(10000);
    if (g_q) dispatch_sync(g_q, ^{});
    if (g_hid) {
        if (present && usb_present()) set_usb_switches(0x00);
        [g_hid destroy];
    }
    if (present) { [g_play selectAlternateSetting:0 error:nil]; [g_cap selectAlternateSetting:0 error:nil]; }
    [g_cap destroy]; [g_play destroy];
    if (g_q) dispatch_sync(g_q, ^{});
    log_stats("stopped");
    g_cap = g_play = g_hid = nil;
    g_cpipe = g_ppipe = g_hout = g_hin = nil;
    g_req_out = g_req_in = g_hb_out = g_hb_in = nil;
    for (int i = 0; i < CAP_NXF; i++) g_cbuf[i] = nil;
    for (int i = 0; i < PLAY_NXF; i++) g_pbuf[i] = nil;
}

/* ---- AudioServerPlugIn driver interface ---- */
static HRESULT QI(void *d, REFIID iid, LPVOID *out);
static ULONG AddRef(void *d) { (void)d; return ++g_refs; }
static ULONG Release(void *d) { (void)d; return g_refs > 0 ? --g_refs : 0; }

static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    (void)d;
    g_host = host;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    g_tick_ns = (double)tb.numer / tb.denom;
    os_log(g_log, "Initialize, SL3 %{public}s", usb_present() ? "present" : "not present");
    return noErr;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *o) { (void)d; (void)desc; (void)c; (void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) { (void)d; (void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { (void)d; (void)o; (void)c; return noErr; }
static OSStatus RemoveClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { (void)d; (void)o; (void)c; return noErr; }
static OSStatus PerformCfg(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { (void)d; (void)o; (void)a; (void)i; return noErr; }
static OSStatus AbortCfg(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { (void)d; (void)o; (void)a; (void)i; return noErr; }

static AudioStreamBasicDescription stream_format(void) {
    return (AudioStreamBasicDescription){
        .mSampleRate = RATE, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * NCH, .mFramesPerPacket = 1, .mBytesPerFrame = 4 * NCH,
        .mChannelsPerFrame = NCH, .mBitsPerChannel = 32 };
}

/* Property table: returns the value size, or 0 if the object has no such property.
 * With data != NULL, also writes the value (data must hold the returned size). */
static UInt32 prop(AudioObjectID o, const AudioObjectPropertyAddress *a, const void *qual, void *data) {
    #define RET(type, val) do { if (data) *(type *)data = (val); return sizeof(type); } while (0)
    AudioObjectPropertyScope sc = a->mScope;
    switch (o) {
    case kObjPlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RET(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RET(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RET(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RET(CFStringRef, CFSTR("sl3-bridge"));
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: RET(AudioObjectID, kObjDevice);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            CFStringRef uid = qual ? *(const CFStringRef *)qual : NULL;
            RET(AudioObjectID, uid && CFEqual(uid, DEVICE_UID) ? kObjDevice : kAudioObjectUnknown);
        }
        case kAudioPlugInPropertyResourceBundle: RET(CFStringRef, CFSTR(""));
        }
        return 0;
    case kObjDevice:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RET(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RET(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RET(AudioObjectID, kObjPlugIn);
        case kAudioObjectPropertyName: RET(CFStringRef, CFSTR("Rane SL3"));
        case kAudioObjectPropertyManufacturer: RET(CFStringRef, CFSTR("Rane"));
        case kAudioDevicePropertyDeviceUID: RET(CFStringRef, DEVICE_UID);
        case kAudioDevicePropertyModelUID: RET(CFStringRef, MODEL_UID);
        case kAudioDevicePropertyTransportType: RET(UInt32, kAudioDeviceTransportTypeUSB);
        case kAudioDevicePropertyRelatedDevices: RET(AudioObjectID, kObjDevice);
        case kAudioDevicePropertyClockDomain: RET(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RET(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: RET(UInt32, g_io_clients > 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RET(UInt32, 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RET(UInt32, 0);
        case kAudioDevicePropertyLatency: RET(UInt32, sc == kAudioObjectPropertyScopeInput ? LAT_IN : LAT_OUT);
        case kAudioDevicePropertySafetyOffset: RET(UInt32, sc == kAudioObjectPropertyScopeInput ? IN_SAFETY : OUT_SAFETY);
        case kAudioDevicePropertyNominalSampleRate: RET(Float64, RATE);
        case kAudioDevicePropertyAvailableNominalSampleRates: RET(AudioValueRange, ((AudioValueRange){RATE, RATE}));
        case kAudioDevicePropertyIsHidden: RET(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RET(UInt32, ZTS_PERIOD);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (data) { ((UInt32 *)data)[0] = 1; ((UInt32 *)data)[1] = 2; }
            return 2 * sizeof(UInt32);
        }
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams: {
            int nin = sc != kAudioObjectPropertyScopeOutput, nout = sc != kAudioObjectPropertyScopeInput;
            if (data) { AudioObjectID *p = data; if (nin) *p++ = kObjStreamIn; if (nout) *p = kObjStreamOut; }
            return (UInt32)((nin + nout) * sizeof(AudioObjectID));
        }
        }
        return 0;
    case kObjStreamIn: case kObjStreamOut:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RET(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RET(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RET(AudioObjectID, kObjDevice);
        case kAudioStreamPropertyIsActive: RET(UInt32, 1);
        case kAudioStreamPropertyDirection: RET(UInt32, o == kObjStreamIn);
        case kAudioStreamPropertyTerminalType: RET(UInt32, kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: RET(UInt32, 1);
        case kAudioStreamPropertyLatency: RET(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: RET(AudioStreamBasicDescription, stream_format());
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            RET(AudioStreamRangedDescription, ((AudioStreamRangedDescription){stream_format(), {RATE, RATE}}));
        }
        return 0;
    }
    return 0;
    #undef RET
}

/* Properties that exist with an empty value. */
static int prop_empty(AudioObjectID o, const AudioObjectPropertyAddress *a) {
    return (o == kObjDevice && a->mSelector == kAudioObjectPropertyControlList) ||
           (o == kObjPlugIn && a->mSelector == kAudioPlugInPropertyBoxList) ||
           ((o == kObjStreamIn || o == kObjStreamOut) && a->mSelector == kAudioObjectPropertyOwnedObjects);
}

/* kAudioObjectPropertyOwnedObjects, filtered by the qualifier's class IDs:
 * an object matches if its class or base class is listed. Returns the count. */
static UInt32 owned(AudioObjectID o, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, AudioObjectID *ids) {
    AudioObjectID all[4];
    UInt32 n = prop(o, a, NULL, all) / sizeof(AudioObjectID), k = 0;
    for (UInt32 i = 0; i < n; i++) {
        AudioClassID cls = all[i] == kObjDevice ? kAudioDeviceClassID : kAudioStreamClassID;
        int ok = !q || qs < sizeof(AudioClassID);
        for (UInt32 j = 0; !ok && j < qs / sizeof(AudioClassID); j++) {
            AudioClassID c = ((const AudioClassID *)q)[j];
            ok = c == cls || c == kAudioObjectClassID;
        }
        if (ok) ids[k++] = all[i];
    }
    return k;
}
static int is_owned(AudioObjectID o, const AudioObjectPropertyAddress *a) {
    return a->mSelector == kAudioObjectPropertyOwnedObjects && (o == kObjPlugIn || o == kObjDevice);
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)d; (void)pid;
    if (a->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) return o == kObjPlugIn;
    return prop_empty(o, a) || prop(o, a, NULL, NULL) > 0;
}
static OSStatus IsSettable(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *s) {
    if (!HasProperty(d, o, pid, a)) return kAudioHardwareUnknownPropertyError;
    *s = false;
    return noErr;
}
static OSStatus GetSize(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *sz) {
    if (!HasProperty(d, o, pid, a)) return kAudioHardwareUnknownPropertyError;
    AudioObjectID ids[4];
    *sz = prop_empty(o, a) ? 0 : is_owned(o, a) ? owned(o, a, qs, q, ids) * (UInt32)sizeof(AudioObjectID) : prop(o, a, q, NULL);
    return noErr;
}
static OSStatus GetData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 in, UInt32 *out, void *data) {
    if (!HasProperty(d, o, pid, a)) return kAudioHardwareUnknownPropertyError;
    if (prop_empty(o, a)) { *out = 0; return noErr; }
    if (is_owned(o, a)) {
        AudioObjectID ids[4];
        UInt32 n = owned(o, a, qs, q, ids);
        if (n > in / sizeof(AudioObjectID)) n = in / sizeof(AudioObjectID);
        memcpy(data, ids, n * sizeof(AudioObjectID));
        *out = n * (UInt32)sizeof(AudioObjectID);
        return noErr;
    }
    UInt32 need = prop(o, a, q, NULL);
    /* list properties may be asked for fewer items than they have */
    int list = a->mSelector == kAudioObjectPropertyOwnedObjects || a->mSelector == kAudioDevicePropertyStreams ||
               a->mSelector == kAudioPlugInPropertyDeviceList;
    if (in < need) {
        if (!list) return kAudioHardwareBadPropertySizeError;
        uint8_t tmp[64];
        prop(o, a, q, tmp);
        *out = in / sizeof(AudioObjectID) * sizeof(AudioObjectID);
        memcpy(data, tmp, *out);
        return noErr;
    }
    *out = prop(o, a, q, data);
    return noErr;
}
static OSStatus SetData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 sz, const void *data) {
    (void)qs; (void)q; (void)sz; (void)data;
    if (!HasProperty(d, o, pid, a)) return kAudioHardwareUnknownPropertyError;
    if (o == kObjDevice && a->mSelector == kAudioDevicePropertyNominalSampleRate && sz >= sizeof(Float64) && *(const Float64 *)data == RATE) return noErr;
    return kAudioHardwareUnsupportedOperationError;
}

/* kAudioDevicePropertyDeviceIsRunning is tracked by the HAL, which calls
 * StartIO/StopIO: the plug-in must not report it changed from inside them
 * (doing so left coreaudiod spinning in proxy reconciliation). */
static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) {
    (void)d; (void)c;
    if (o != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&g_lock);
    OSStatus r = noErr;
    if (g_io_clients == 0) {
        if (usb_open_all()) r = kAudioHardwareNotRunningError;
        else g_io_clients = 1;
    } else g_io_clients++;
    pthread_mutex_unlock(&g_lock);
    return r;
}
static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) {
    (void)d; (void)c;
    if (o != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&g_lock);
    int last = g_io_clients == 1;
    if (g_io_clients > 0) g_io_clients--;
    if (last) usb_close(1);
    pthread_mutex_unlock(&g_lock);
    return noErr;
}

static OSStatus ZeroTS(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, Float64 *st, UInt64 *ht, UInt64 *seed) {
    (void)d; (void)c;
    if (o != kObjDevice) return kAudioHardwareBadObjectError;
    double a_s, a_h, tpf; uint64_t sd; int v;
    clk_read(&a_s, &a_h, &tpf, &sd, &v);
    if (!v) { *st = 0; *ht = mach_absolute_time(); *seed = 1; return noErr; }
    double now_s = a_s + ((double)mach_absolute_time() - a_h) / tpf;
    double k = floor(now_s / ZTS_PERIOD) * ZTS_PERIOD;
    *st = k;
    *ht = (UInt64)llround(a_h + (k - a_s) * tpf);
    *seed = sd;
    return noErr;
}

static OSStatus WillDo(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, Boolean *w, Boolean *ip) {
    (void)d; (void)o; (void)c;
    *w = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    *ip = true;
    return noErr;
}
static OSStatus BeginOp(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { (void)d; (void)o; (void)c; (void)op; (void)n; (void)i; return noErr; }
static OSStatus DoOp(AudioServerPlugInDriverRef d, AudioObjectID o, AudioObjectID s, UInt32 c, UInt32 op, UInt32 n,
                     const AudioServerPlugInIOCycleInfo *ci, void *main, void *sec) {
    (void)d; (void)o; (void)s; (void)c; (void)sec;
    float *buf = main;
    if (op == kAudioServerPlugInIOOperationReadInput) {
        uint64_t t = (uint64_t)llround(ci->mInputTime.mSampleTime);
        if (g_in_next && t != g_in_next) S.in_jumps++;
        g_in_next = t + n;
        long miss = 0;
        for (UInt32 f = 0; f < n; f++) miss += !sring_get(&g_in, t + f, buf + f * NCH);
        if (miss) S.in_miss += miss;
    } else if (op == kAudioServerPlugInIOOperationWriteMix) {
        uint64_t t = (uint64_t)llround(ci->mOutputTime.mSampleTime);
        if (g_out_next && t != g_out_next) S.out_jumps++;
        g_out_next = t + n;
        for (UInt32 f = 0; f < n; f++) {
            sring_put(&g_out, t + f, buf + f * NCH);
            for (int c = 0; c < NCH; c++) { float a = fabsf(buf[f * NCH + c]); if (a > g_pk_hal[c]) g_pk_hal[c] = a; }
        }
    }
    return noErr;
}
static OSStatus EndOp(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { (void)d; (void)o; (void)c; (void)op; (void)n; (void)i; return noErr; }

static AudioServerPlugInDriverInterface g_iface = {
    NULL, QI, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddClient, RemoveClient,
    PerformCfg, AbortCfg, HasProperty, IsSettable, GetSize, GetData, SetData,
    StartIO, StopIO, ZeroTS, WillDo, BeginOp, DoOp, EndOp
};
static AudioServerPlugInDriverInterface *g_ifacep = &g_iface;

static HRESULT QI(void *d, REFIID iid, LPVOID *out) {
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, iid);
    Boolean ok = CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(req);
    if (!ok) { *out = NULL; return E_NOINTERFACE; }
    AddRef(d);
    *out = &g_ifacep;
    return S_OK;
}

__attribute__((visibility("default")))
void *SL3Device_Create(CFAllocatorRef alloc, CFUUIDRef type) {
    (void)alloc;
    g_log = os_log_create("sl3.device", "driver");
    if (!CFEqual(type, kAudioServerPlugInTypeUUID)) return NULL;
    return &g_ifacep;
}
