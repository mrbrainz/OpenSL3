/*
 * sl3ctl: talk to the SL3's vendor control channel (interface 3).
 *
 * Report format (from Rane's Sl3Driver kext and Sl3Api.framework):
 *   64 bytes on interrupt OUT EP 0x01, no report ID.
 *   byte 0     command
 *   bytes 1..4 sequence number, little endian
 *   bytes 5..  payload (max 59 bytes), rest zero
 * Replies come back on interrupt IN EP 0x81 and are matched by sequence number.
 *
 * Known commands:
 *   0x31 set sample rate  payload: rate, 16-bit big endian (AC 44 / BB 80)
 *   0x32 get audio controls (22 bytes, returned from reply offset 5)
 *   0x33 set audio controls payload: start, count, values...
 *   0x37 driver timer      8-byte payload, 8-byte reply
 *   unsolicited from box: 0x34, 0x38
 *
 * Implements get-controls (0x32), a single-byte set-control (0x33), and a
 * heartbeat mode that sends 0x37 with 8 random bytes every 100 ms. Decks whose
 * switch byte (control index 8, 14 or 20) is 01 leave analog thru while the
 * heartbeat runs. Never sends 0x31.
 *
 * Build: make
 * Run:   build/sl3ctl get-controls [--listen SECONDS]
 *        build/sl3ctl set-control INDEX VALUE [--listen SECONDS]
 *        build/sl3ctl heartbeat SECONDS
 */
#include <libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#define VID 0x1cc5
#define PID 0x0001
#define IF_HID 3
#define EP_OUT 0x01
#define EP_IN  0x81
#define REPORT 64

static double now_s(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }

static void dump(const char *tag, const uint8_t *b, int n) {
    printf("%s (%d bytes):", tag, n);
    for (int i = 0; i < n; i++) printf("%s%02x", (i % 16) ? " " : "\n   ", b[i]);
    printf("\n");
}

static uint32_t g_seq = 1;

/* Send one command, then print every IN report for `listen` seconds. */
static void request(libusb_device_handle *h, uint8_t cmd, const uint8_t *payload, int len, double listen) {
    uint8_t out[REPORT] = {0}, in[REPORT];
    uint32_t seq = g_seq++;
    out[0] = cmd;
    memcpy(out + 1, &seq, 4); /* little endian host */
    if (len) memcpy(out + 5, payload, len);
    dump("sent", out, 16);
    int n = 0;
    int r = libusb_interrupt_transfer(h, EP_OUT, out, REPORT, &n, 1000);
    if (r) { printf("write failed: %s\n", libusb_error_name(r)); return; }

    double t0 = now_s();
    while (now_s() - t0 < listen) {
        r = libusb_interrupt_transfer(h, EP_IN, in, REPORT, &n, 200);
        if (r == LIBUSB_ERROR_TIMEOUT) continue;
        if (r) { printf("read failed: %s\n", libusb_error_name(r)); break; }
        if (n == 0) continue;
        char tag[64];
        uint32_t s; memcpy(&s, in + 1, 4);
        snprintf(tag, sizeof tag, "t=%.3f cmd 0x%02x seq %u", now_s() - t0, in[0], s);
        dump(tag, in, n);
        if (n >= 27 && in[0] == 0x32 && s == seq) dump("  audio controls [0..21]", in + 5, 22);
    }
}

int main(int argc, char **argv) {
    double listen = 1.0;
    int hb = argc >= 3 && !strcmp(argv[1], "heartbeat");
    int set = argc >= 4 && !strcmp(argv[1], "set-control");
    if (argc < 2 || (!set && !hb && strcmp(argv[1], "get-controls"))) {
        fprintf(stderr, "usage: %s get-controls | set-control INDEX VALUE | heartbeat SECONDS  [--listen SECONDS]\n", argv[0]);
        return 2;
    }
    int idx = 0, val = 0;
    if (set) {
        idx = strtol(argv[2], NULL, 0); val = strtol(argv[3], NULL, 0);
        if (idx < 0 || idx > 21 || val < 0 || val > 255) { fprintf(stderr, "index 0..21, value 0..255\n"); return 2; }
    }
    for (int i = set ? 4 : 2; i < argc; i++)
        if (!strcmp(argv[i], "--listen") && i + 1 < argc) listen = atof(argv[++i]);

    libusb_context *ctx; libusb_init(&ctx);
    libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, VID, PID);
    if (!h) { printf("SL3 not found\n"); return 1; }
    int cfg = 0; libusb_get_configuration(h, &cfg);
    if (cfg != 1) libusb_set_configuration(h, 1);
    int r = libusb_claim_interface(h, IF_HID);
    if (r) { printf("claim interface 3 failed: %s\n", libusb_error_name(r)); return 1; }

    if (hb) {
        double secs = atof(argv[2]), t0 = now_s();
        int sent = 0, replies = 0;
        uint8_t in[REPORT];
        arc4random_stir();
        while (now_s() - t0 < secs) {
            uint8_t out[REPORT] = {0}, ch[8];
            arc4random_buf(ch, 8);
            uint32_t seq = g_seq++;
            out[0] = 0x37; memcpy(out + 1, &seq, 4); memcpy(out + 5, ch, 8);
            int n;
            if (libusb_interrupt_transfer(h, EP_OUT, out, REPORT, &n, 1000) == 0) sent++;
            double t1 = now_s();
            while (now_s() - t1 < 0.1) {
                if (libusb_interrupt_transfer(h, EP_IN, in, REPORT, &n, 50) || n == 0) continue;
                uint32_t s; memcpy(&s, in + 1, 4);
                if (in[0] == 0x37 && s == seq) {
                    if (++replies <= 3) { dump("challenge", ch, 8); dump("  reply  ", in + 5, 8); }
                } else if (in[0] != 0x37) dump("other report", in, 16);
            }
        }
        printf("heartbeat: sent %d, replies %d\n", sent, replies);
    }
    if (set) {
        uint8_t p[3] = {(uint8_t)idx, 1, (uint8_t)val};
        printf("== set control %d = 0x%02x\n", idx, val);
        request(h, 0x33, p, 3, listen);
    }
    printf("== get controls\n");
    request(h, 0x32, NULL, 0, listen);
    libusb_release_interface(h, IF_HID);
    libusb_close(h); libusb_exit(ctx);
    return 0;
}
