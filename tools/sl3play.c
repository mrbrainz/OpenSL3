// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * sl3play: playback test for the Rane SL3.
 *
 * Runs the capture stream (IF 2, EP 0x82) and the playback stream
 * (IF 1, EP 0x06) in one event loop. EP 0x82 is the implicit feedback
 * source, so each playback packet carries as many frames as the next
 * capture packet that arrived. Sends a quiet sine on output channels 1 and 2,
 * silence on 3..6. Never touches interface 3 and never changes the clock.
 *
 * Build: make
 * Run:   build/sl3play [--seconds S] [--freq HZ] [--level DBFS]
 */
#include <libusb.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#define VID 0x1cc5
#define PID 0x0001
#define IF_AC   0
#define IF_PLAY 1
#define IF_CAP  2
#define EP_PLAY 0x06
#define EP_CAP  0x82
#define NCH 6
#define FRAME_BYTES 18
#define PKT_MAX 126
#define PKTS 8
#define NXF 8
#define RATE 44100.0

static volatile sig_atomic_t g_stop;
static void on_sigint(int s) { (void)s; g_stop = 1; }
static double now_s(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }

/* FIFO of frame counts seen on the capture endpoint */
#define FIFO_N 4096
static int fifo[FIFO_N];
static unsigned fifo_w, fifo_r;

static struct {
    double phase, inc, amp;
    double acc;              /* fallback accumulator, frames per microframe */
    long cap_pkts, cap_err, play_pkts, play_err, play_frames, fallback, xfer_err;
    int inflight, stop;
} S;

static void LIBUSB_CALL cap_cb(struct libusb_transfer *t) {
    if (t->status == LIBUSB_TRANSFER_COMPLETED) {
        for (int i = 0; i < t->num_iso_packets; i++) {
            struct libusb_iso_packet_descriptor *pd = &t->iso_packet_desc[i];
            S.cap_pkts++;
            if (pd->status != LIBUSB_TRANSFER_COMPLETED) { S.cap_err++; continue; }
            if (fifo_w - fifo_r < FIFO_N) fifo[fifo_w++ % FIFO_N] = pd->actual_length / FRAME_BYTES;
        }
    } else if (t->status != LIBUSB_TRANSFER_CANCELLED) S.xfer_err++;
    if (S.stop || t->status == LIBUSB_TRANSFER_CANCELLED || t->status == LIBUSB_TRANSFER_NO_DEVICE) { S.inflight--; return; }
    if (libusb_submit_transfer(t) != 0) { S.inflight--; S.stop = 1; }
}

static void put24(uint8_t *p, int32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; }

static void fill_play(struct libusb_transfer *t) {
    uint8_t *p = t->buffer;
    int total = 0;
    for (int i = 0; i < t->num_iso_packets; i++) {
        int n;
        if (fifo_r != fifo_w) n = fifo[fifo_r++ % FIFO_N];
        else { S.fallback++; S.acc += RATE * 125e-6; n = (int)S.acc; S.acc -= n; }
        if (n < 0 || n > PKT_MAX / FRAME_BYTES) n = 5;
        for (int f = 0; f < n; f++) {
            int32_t v = (int32_t)lrint(S.amp * sin(S.phase) * 8388607.0);
            S.phase += S.inc; if (S.phase > 2 * M_PI) S.phase -= 2 * M_PI;
            uint8_t *fr = p + total + f * FRAME_BYTES;
            memset(fr, 0, FRAME_BYTES);
            put24(fr, v); put24(fr + 3, v);
        }
        t->iso_packet_desc[i].length = n * FRAME_BYTES;
        total += n * FRAME_BYTES;
        S.play_frames += n;
    }
    t->length = total;
}

static void LIBUSB_CALL play_cb(struct libusb_transfer *t) {
    if (t->status == LIBUSB_TRANSFER_COMPLETED) {
        for (int i = 0; i < t->num_iso_packets; i++) {
            S.play_pkts++;
            if (t->iso_packet_desc[i].status != LIBUSB_TRANSFER_COMPLETED) S.play_err++;
        }
    } else if (t->status != LIBUSB_TRANSFER_CANCELLED) S.xfer_err++;
    if (S.stop || t->status == LIBUSB_TRANSFER_CANCELLED || t->status == LIBUSB_TRANSFER_NO_DEVICE) { S.inflight--; return; }
    fill_play(t);
    if (libusb_submit_transfer(t) != 0) { S.inflight--; S.stop = 1; }
}

int main(int argc, char **argv) {
    double seconds = 5, freq = 440, level = -40;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--freq") && i + 1 < argc) freq = atof(argv[++i]);
        else if (!strcmp(argv[i], "--level") && i + 1 < argc) level = atof(argv[++i]);
        else { fprintf(stderr, "usage: %s [--seconds S] [--freq HZ] [--level DBFS]\n", argv[0]); return 2; }
    }
    if (level > -20) { fprintf(stderr, "refusing level above -20 dBFS\n"); return 2; }
    S.amp = pow(10, level / 20); S.inc = 2 * M_PI * freq / RATE;
    signal(SIGINT, on_sigint);

    libusb_context *ctx; libusb_init(&ctx);
    libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, VID, PID);
    if (!h) { printf("SL3 not found\n"); return 1; }
    int cfg = 0; libusb_get_configuration(h, &cfg);
    if (cfg != 1) libusb_set_configuration(h, 1);
    libusb_claim_interface(h, IF_AC);
    int r;
    if ((r = libusb_claim_interface(h, IF_CAP)) || (r = libusb_set_interface_alt_setting(h, IF_CAP, 1)) ||
        (r = libusb_claim_interface(h, IF_PLAY)) || (r = libusb_set_interface_alt_setting(h, IF_PLAY, 1))) {
        printf("interface setup failed: %s\n", libusb_error_name(r)); return 1;
    }
    printf("Playing %.0f Hz at %.0f dBFS on out 1/2 for %.1f s\n", freq, level, seconds);

    struct libusb_transfer *cx[NXF], *px[NXF];
    for (int i = 0; i < NXF; i++) {
        cx[i] = libusb_alloc_transfer(PKTS);
        libusb_fill_iso_transfer(cx[i], h, EP_CAP, malloc(PKTS * PKT_MAX), PKTS * PKT_MAX, PKTS, cap_cb, NULL, 1000);
        libusb_set_iso_packet_lengths(cx[i], PKT_MAX);
        if (libusb_submit_transfer(cx[i]) == 0) S.inflight++;
    }
    /* let a little feedback accumulate before starting playback */
    struct timeval tv = {0, 10000};
    double t0 = now_s();
    while (now_s() - t0 < 0.05) libusb_handle_events_timeout(ctx, &tv);
    fifo_r = fifo_w; /* drop stale counts, keep latency low */
    for (int i = 0; i < NXF; i++) {
        px[i] = libusb_alloc_transfer(PKTS);
        libusb_fill_iso_transfer(px[i], h, EP_PLAY, malloc(PKTS * PKT_MAX), 0, PKTS, play_cb, NULL, 1000);
        fill_play(px[i]);
        if ((r = libusb_submit_transfer(px[i])) == 0) S.inflight++;
        else printf("play submit failed: %s\n", libusb_error_name(r));
    }
    t0 = now_s();
    while (!g_stop && !S.stop && now_s() - t0 < seconds) libusb_handle_events_timeout(ctx, &tv);
    S.stop = 1;
    for (int i = 0; i < NXF; i++) { libusb_cancel_transfer(cx[i]); libusb_cancel_transfer(px[i]); }
    double t1 = now_s();
    while (S.inflight > 0 && now_s() - t1 < 3) libusb_handle_events_timeout(ctx, &tv);
    double el = t1 - t0;

    printf("capture packets %ld (errors %ld)\n", S.cap_pkts, S.cap_err);
    printf("playback packets %ld (errors %ld), frames %ld = %.0f Hz, fallback packets %ld, transfer errors %ld\n",
           S.play_pkts, S.play_err, S.play_frames, S.play_frames / el, S.fallback, S.xfer_err);

    libusb_set_interface_alt_setting(h, IF_PLAY, 0);
    libusb_set_interface_alt_setting(h, IF_CAP, 0);
    libusb_release_interface(h, IF_PLAY);
    libusb_release_interface(h, IF_CAP);
    libusb_release_interface(h, IF_AC);
    libusb_close(h); libusb_exit(ctx);
    return 0;
}
