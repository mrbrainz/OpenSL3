/*
 * sl3probe - probe for the Rane SL3 (USB 1cc5:0001) on a modern Mac.
 *
 * Notes:
 *   - The box stalls every UAC2 clock request (GET_RANGE / GET_CUR / SET_CUR)
 *     and streams at 44.1 kHz regardless, so the clock is left alone unless
 *     you pass --set-rate N. (The real rate command is vendor command 0x31 on
 *     interface 3; see docs/PROTOCOL.md.)
 *   - The WAV header carries the rate measured from USB packet timing.
 *   - The first few packets after the stream starts contain stale buffer data,
 *     so they are discarded.
 *
 * What it does:
 *   1. Opens the device and prints its identity strings.
 *   2. Reads the HID report descriptor from interface 3 (read-only control request).
 *   3. Queries the UAC2 clock source (ID 5); the SL3 is known to stall this.
 *   4. Optionally tries to set the sample rate (--set-rate N).
 *   5. Optionally listens passively on the interrupt IN endpoint (--hid-listen N).
 *   6. Enables the capture stream (interface 2, alt 1) and records 6 channels
 *      of 24-bit audio to a WAV file, with packet statistics and per-channel peaks.
 *
 * What it does NOT do: it never writes to interface 3 (no interrupt OUT, no HID
 * output/feature reports), and it doesn't enable playback.
 *
 * Build:   make
 * Run:     build/sl3probe --info-only
 *          build/sl3probe --seconds 5 --out capture.wav
 *          build/sl3probe --info-only --hid-listen 15
 */
#include <libusb.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define VID 0x1cc5
#define PID 0x0001

#define IF_AC   0
#define IF_PLAY 1
#define IF_CAP  2
#define IF_HID  3

#define EP_CAP     0x82
#define EP_HID_IN  0x81

#define CLOCK_ID   5
#define NCH        6
#define SUBSLOT    3
#define FRAME_BYTES (NCH * SUBSLOT)
#define PKT_MAX    126
#define PKTS_PER_XFER 8
#define NUM_XFERS  16

#define UAC2_CUR   0x01
#define UAC2_RANGE 0x02
#define CS_SAM_FREQ 0x01

/* High-speed USB: one iso packet per 125 us microframe (bInterval = 1). */
#define MICROFRAME_S 125e-6
/* Packets at stream start carry stale data (about the first 11 frames). */
#define SKIP_PACKETS 3

static volatile sig_atomic_t g_stop = 0;
static void on_sigint(int s) { (void)s; g_stop = 1; }

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void hexdump(const uint8_t *b, int n) {
    for (int i = 0; i < n; i += 16) {
        printf("  %04x: ", i);
        for (int j = i; j < i + 16 && j < n; j++) printf("%02x ", b[j]);
        printf("\n");
    }
}

static uint32_t le32(const uint8_t *p) {
    return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* ---------- identity ---------- */

static void print_strings(libusb_device_handle *h) {
    struct libusb_device_descriptor dd;
    libusb_device *dev = libusb_get_device(h);
    if (libusb_get_device_descriptor(dev, &dd) != 0) return;
    unsigned char s[256];
    if (dd.iManufacturer && libusb_get_string_descriptor_ascii(h, dd.iManufacturer, s, sizeof s) > 0)
        printf("  Manufacturer: %s\n", s);
    if (dd.iProduct && libusb_get_string_descriptor_ascii(h, dd.iProduct, s, sizeof s) > 0)
        printf("  Product:      %s\n", s);
    if (dd.iSerialNumber && libusb_get_string_descriptor_ascii(h, dd.iSerialNumber, s, sizeof s) > 0)
        printf("  Serial:       %s\n", s);
}

/* ---------- HID report descriptor (read-only) ---------- */

static void read_hid_report_descriptor(libusb_device_handle *h) {
    uint8_t buf[256];
    /* standard GET_DESCRIPTOR(HID report, 0x22) addressed to interface 3 */
    int r = libusb_control_transfer(h, 0x81, 0x06, 0x2200, IF_HID, buf, sizeof buf, 1000);
    if (r < 0) {
        printf("  GET_DESCRIPTOR(report) failed: %s\n", libusb_error_name(r));
        return;
    }
    printf("  HID report descriptor, %d bytes:\n", r);
    hexdump(buf, r);
}

/* ---------- UAC2 clock ---------- */

static void query_rates(libusb_device_handle *h) {
    uint8_t buf[2 + 12 * 32];
    int r = libusb_control_transfer(h, 0xA1, UAC2_RANGE, CS_SAM_FREQ << 8,
                                    (CLOCK_ID << 8) | IF_AC, buf, sizeof buf, 1000);
    if (r < 2) {
        printf("  GET_RANGE failed: %s\n", r < 0 ? libusb_error_name(r) : "short reply");
        return;
    }
    int n = buf[0] | (buf[1] << 8);
    int avail = (r - 2) / 12;
    if (n > avail) n = avail;
    printf("  %d sample-rate range(s):\n", n);
    for (int i = 0; i < n; i++) {
        const uint8_t *p = buf + 2 + 12 * i;
        printf("    min %u  max %u  step %u\n", le32(p), le32(p + 4), le32(p + 8));
    }
}

static uint32_t get_rate(libusb_device_handle *h) {
    uint8_t d[4];
    int r = libusb_control_transfer(h, 0xA1, UAC2_CUR, CS_SAM_FREQ << 8,
                                    (CLOCK_ID << 8) | IF_AC, d, 4, 1000);
    if (r != 4) {
        printf("  GET_CUR failed: %s\n", r < 0 ? libusb_error_name(r) : "short reply");
        return 0;
    }
    return le32(d);
}

static int set_rate(libusb_device_handle *h, uint32_t rate) {
    uint8_t d[4] = { rate & 0xff, (rate >> 8) & 0xff, (rate >> 16) & 0xff, (rate >> 24) & 0xff };
    int r = libusb_control_transfer(h, 0x21, UAC2_CUR, CS_SAM_FREQ << 8,
                                    (CLOCK_ID << 8) | IF_AC, d, 4, 1000);
    if (r != 4) {
        printf("  SET_CUR failed: %s\n", r < 0 ? libusb_error_name(r) : "short write");
        return -1;
    }
    return 0;
}

/* ---------- passive HID listen ---------- */

static void hid_listen(libusb_device_handle *h, int seconds) {
    int r = libusb_claim_interface(h, IF_HID);
    if (r != 0) {
        printf("  claim interface 3 failed: %s\n", libusb_error_name(r));
        return;
    }
    printf("  Listening for %d s on EP 0x81 (read-only). Move faders / press buttons now.\n", seconds);
    double t0 = now_s();
    int shown = 0;
    while (!g_stop && now_s() - t0 < seconds && shown < 300) {
        uint8_t buf[64];
        int n = 0;
        r = libusb_interrupt_transfer(h, EP_HID_IN, buf, sizeof buf, &n, 250);
        if (r == LIBUSB_ERROR_TIMEOUT) continue;
        if (r != 0) {
            printf("  interrupt read error: %s\n", libusb_error_name(r));
            break;
        }
        printf("  [%6.2fs] %d bytes:", now_s() - t0, n);
        for (int i = 0; i < n; i++) printf(" %02x", buf[i]);
        printf("\n");
        shown++;
    }
    if (shown == 0) printf("  (no reports received)\n");
    libusb_release_interface(h, IF_HID);
}

/* ---------- capture ---------- */

typedef struct {
    FILE *f;
    uint64_t bytes, packets, zero, bad, misaligned, xfer_errs;
    uint64_t frames_seen;   /* every frame received, including skipped packets */
    int skip_left;
    uint64_t hist[PKT_MAX + 1];
    int32_t peak[NCH];
    int inflight;
    int stop;
} cap_t;

static void LIBUSB_CALL cap_cb(struct libusb_transfer *t) {
    cap_t *c = (cap_t *)t->user_data;

    if (t->status == LIBUSB_TRANSFER_CANCELLED || t->status == LIBUSB_TRANSFER_NO_DEVICE) {
        if (t->status == LIBUSB_TRANSFER_NO_DEVICE) c->stop = 1;
        c->inflight--;
        return;
    }
    if (t->status != LIBUSB_TRANSFER_COMPLETED) c->xfer_errs++;

    for (int i = 0; i < t->num_iso_packets; i++) {
        struct libusb_iso_packet_descriptor *pd = &t->iso_packet_desc[i];
        c->packets++;
        if (pd->status != LIBUSB_TRANSFER_COMPLETED) { c->bad++; continue; }
        unsigned len = pd->actual_length;
        if (len == 0) { c->zero++; continue; }
        if (len > PKT_MAX) len = PKT_MAX;
        const uint8_t *p = libusb_get_iso_packet_buffer_simple(t, i);
        if (!p) continue;
        unsigned frames = len / FRAME_BYTES;
        c->frames_seen += frames;
        if (c->skip_left > 0) { c->skip_left--; continue; }
        c->hist[len]++;
        if (len % FRAME_BYTES) c->misaligned++;
        for (unsigned f = 0; f < frames; f++) {
            for (int ch = 0; ch < NCH; ch++) {
                const uint8_t *s = p + f * FRAME_BYTES + ch * SUBSLOT;
                int32_t v = (int32_t)(((uint32_t)(s[0] | (s[1] << 8) | (s[2] << 16))) << 8) >> 8;
                if (v < 0) v = -v;
                if (v > c->peak[ch]) c->peak[ch] = v;
            }
        }
        if (c->f) fwrite(p, 1, frames * FRAME_BYTES, c->f);
        c->bytes += frames * FRAME_BYTES;
    }

    if (c->stop || g_stop) { c->inflight--; return; }
    if (libusb_submit_transfer(t) != 0) { c->stop = 1; c->inflight--; }
}

static void put32(FILE *f, uint32_t v) {
    uint8_t b[4] = { v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff };
    fwrite(b, 1, 4, f);
}
static void put16(FILE *f, uint16_t v) {
    uint8_t b[2] = { v & 0xff, v >> 8 };
    fwrite(b, 1, 2, f);
}

/* 68-byte WAVE_FORMAT_EXTENSIBLE header; sizes patched at the end. */
static void wav_header(FILE *f, uint32_t rate, uint32_t data_bytes) {
    static const uint8_t pcm_guid[16] = {
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 };
    fwrite("RIFF", 1, 4, f); put32(f, 60 + data_bytes);
    fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f); put32(f, 40);
    put16(f, 0xFFFE); put16(f, NCH); put32(f, rate);
    put32(f, rate * FRAME_BYTES); put16(f, FRAME_BYTES); put16(f, 24);
    put16(f, 22); put16(f, 24); put32(f, 0);
    fwrite(pcm_guid, 1, 16, f);
    fwrite("data", 1, 4, f); put32(f, data_bytes);
}

/* Snap a measured rate to a standard one when it is within 2%. */
static uint32_t snap_rate(double r) {
    static const uint32_t std_rates[] = { 32000, 44100, 48000, 88200, 96000, 176400, 192000 };
    for (unsigned i = 0; i < sizeof std_rates / sizeof std_rates[0]; i++)
        if (fabs(r - std_rates[i]) < 0.02 * std_rates[i]) return std_rates[i];
    return (uint32_t)(r + 0.5);
}

static int capture(libusb_context *ctx, libusb_device_handle *h,
                   double seconds, const char *outpath) {
    int r;
    if ((r = libusb_claim_interface(h, IF_AC)) != 0)
        printf("  note: claim interface 0 failed: %s (continuing)\n", libusb_error_name(r));
    if ((r = libusb_claim_interface(h, IF_CAP)) != 0) {
        printf("  claim interface 2 failed: %s\n", libusb_error_name(r));
        return -1;
    }
    if ((r = libusb_set_interface_alt_setting(h, IF_CAP, 1)) != 0) {
        printf("  set interface 2 alt 1 failed: %s\n", libusb_error_name(r));
        libusb_release_interface(h, IF_CAP);
        return -1;
    }

    cap_t c;
    memset(&c, 0, sizeof c);
    c.skip_left = SKIP_PACKETS;
    c.f = fopen(outpath, "wb");
    if (!c.f) { perror("  fopen"); return -1; }
    wav_header(c.f, 44100, 0);   /* placeholder; rewritten with the measured rate */

    struct libusb_transfer *xf[NUM_XFERS];
    uint8_t *bufs[NUM_XFERS];
    for (int i = 0; i < NUM_XFERS; i++) {
        bufs[i] = calloc(1, PKTS_PER_XFER * PKT_MAX);
        xf[i] = libusb_alloc_transfer(PKTS_PER_XFER);
        libusb_fill_iso_transfer(xf[i], h, EP_CAP, bufs[i], PKTS_PER_XFER * PKT_MAX,
                                 PKTS_PER_XFER, cap_cb, &c, 1000);
        libusb_set_iso_packet_lengths(xf[i], PKT_MAX);
        if ((r = libusb_submit_transfer(xf[i])) == 0) c.inflight++;
        else printf("  submit %d failed: %s\n", i, libusb_error_name(r));
    }
    if (c.inflight == 0) {
        printf("  no transfers could be submitted\n");
        fclose(c.f);
        return -1;
    }

    printf("  Capturing %.1f s ...\n", seconds);
    struct timeval tv = { 0, 100000 };
    double t0 = now_s();
    while (!g_stop && !c.stop && now_s() - t0 < seconds && c.inflight > 0)
        libusb_handle_events_timeout(ctx, &tv);
    double elapsed = now_s() - t0;

    c.stop = 1;
    for (int i = 0; i < NUM_XFERS; i++) libusb_cancel_transfer(xf[i]); /* NOT_FOUND is fine */
    double t1 = now_s();
    while (c.inflight > 0 && now_s() - t1 < 3.0) libusb_handle_events_timeout(ctx, &tv);

    /* Sample rate from USB timing: frames received / (packets * 125 us). */
    double measured = c.packets ? c.frames_seen / (c.packets * MICROFRAME_S) : 0.0;
    uint32_t wav_rate = snap_rate(measured);

    /* finalise WAV */
    fseek(c.f, 0, SEEK_SET);
    wav_header(c.f, wav_rate, (uint32_t)c.bytes);
    fclose(c.f);

    printf("\n  --- capture results ---\n");
    printf("  packets: %llu  (zero-length %llu, errored %llu, transfer errors %llu, misaligned %llu)\n",
           (unsigned long long)c.packets, (unsigned long long)c.zero, (unsigned long long)c.bad,
           (unsigned long long)c.xfer_errs, (unsigned long long)c.misaligned);
    printf("  audio bytes kept: %llu (first %d packets discarded as stale)\n",
           (unsigned long long)c.bytes, SKIP_PACKETS);
    printf("  sample rate from USB packet timing: %.0f Hz (WAV header says %u Hz); wall-clock %.2f s\n",
           measured, wav_rate, elapsed);
    printf("  packet length histogram (bytes: count):");
    for (int i = 1; i <= PKT_MAX; i++)
        if (c.hist[i]) printf("  %d:%llu", i, (unsigned long long)c.hist[i]);
    printf("\n  per-channel peak (dBFS):");
    for (int ch = 0; ch < NCH; ch++) {
        if (c.peak[ch] == 0) printf("  ch%d:-inf", ch + 1);
        else printf("  ch%d:%.1f", ch + 1, 20.0 * log10(c.peak[ch] / 8388608.0));
    }
    printf("\n  wrote %s\n", outpath);

    for (int i = 0; i < NUM_XFERS; i++) { libusb_free_transfer(xf[i]); free(bufs[i]); }
    libusb_set_interface_alt_setting(h, IF_CAP, 0);
    libusb_release_interface(h, IF_CAP);
    libusb_release_interface(h, IF_AC);
    return 0;
}

/* ---------- main ---------- */

static void usage(const char *a0) {
    printf("usage: %s [--seconds N] [--out file.wav] [--info-only]\n"
           "          [--hid-listen N] [--set-rate HZ]\n", a0);
}

int main(int argc, char **argv) {
    uint32_t set_rate_hz = 0;   /* 0 = leave the clock alone */
    double seconds = 5.0;
    const char *out = "sl3-capture.wav";
    int info_only = 0, hid_secs = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--set-rate") && i + 1 < argc) set_rate_hz = (uint32_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "--hid-listen") && i + 1 < argc) hid_secs = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--info-only")) info_only = 1;
        else { usage(argv[0]); return 2; }
    }
    signal(SIGINT, on_sigint);

    libusb_context *ctx = NULL;
    int r = libusb_init(&ctx);
    if (r != 0) { printf("libusb_init: %s\n", libusb_error_name(r)); return 1; }

    printf("[1] Opening %04x:%04x\n", VID, PID);
    libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, VID, PID);
    if (!h) {
        printf("  could not open the device (not found, or needs sudo / is claimed by something else)\n");
        libusb_exit(ctx);
        return 1;
    }
    print_strings(h);

    printf("[2] Configuration\n");
    int cfg = -1;
    r = libusb_get_configuration(h, &cfg);
    printf("  current configuration: %d (r=%s)\n", cfg, libusb_error_name(r));
    if (r == 0 && cfg != 1) {
        r = libusb_set_configuration(h, 1);
        printf("  set_configuration(1): %s\n", libusb_error_name(r));
    }

    printf("[3] HID report descriptor (interface 3, read-only)\n");
    read_hid_report_descriptor(h);

    printf("[4] UAC2 clock source %d\n", CLOCK_ID);
    query_rates(h);
    printf("  current rate: %u\n", get_rate(h));

    if (set_rate_hz) {
        printf("[5] Trying SET_CUR %u Hz (the SL3 has been seen to stall this)\n", set_rate_hz);
        if (set_rate(h, set_rate_hz) == 0) printf("  rate now reads back as %u\n", get_rate(h));
    } else {
        printf("[5] Clock left untouched (pass --set-rate HZ to try SET_CUR)\n");
    }

    if (hid_secs > 0) {
        printf("[6] Passive HID listen\n");
        hid_listen(h, hid_secs);
    }

    if (!info_only) {
        printf("[7] Capture\n");
        capture(ctx, h, seconds, out);
    }

    libusb_close(h);
    libusb_exit(ctx);
    return 0;
}
