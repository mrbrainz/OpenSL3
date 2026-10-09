/* sl3usbtiming: compare isochronous capture completion timing, IOUSBHost vs libusb.
 *
 * Streams capture from EP 0x82 (interface 2 alt 1) with 1 ms transfers
 * (8 microframes x 126 bytes) and about 64 ms queued, then reports the gaps
 * between completions and the packet rate. Read-only: no interface 3, no playback.
 *
 * Usage: sl3usbtiming [iousbhost|libusb] [seconds] [transfers in flight]
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <libusb.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>

#define VID     0x1cc5
#define PID     0x0001
#define IF_CAP  2
#define EP_CAP  0x82
#define PKT_MAX 126
#define PKTS    8          /* microframes per transfer = 1 ms */

static int g_nxf = 64;
static double g_secs = 30;
static volatile int g_stop;

/* ---- statistics (only touched from the completion thread) ---- */
#define NBINS 12
static const double bin_ms[NBINS] = {0.5, 1, 1.5, 2, 3, 4, 6, 8, 10, 15, 20, 1e9};
static uint64_t hist[NBINS], n_done, n_pkts, n_bad, n_bytes;
static double tick_ms, last_ms, max_gap, t0_ms;

static double now_ms(void) { return mach_absolute_time() * tick_ms; }

static void record(int good_pkts, int bad_pkts, int bytes) {
    double t = now_ms();
    if (last_ms > 0) {
        double g = t - last_ms;
        if (g > max_gap) max_gap = g;
        int b = 0; while (g > bin_ms[b]) b++;
        hist[b]++;
    } else t0_ms = t;
    last_ms = t;
    n_done++; n_pkts += good_pkts; n_bad += bad_pkts; n_bytes += bytes;
}

static void report(const char *mode) {
    double el = (last_ms - t0_ms) / 1000;
    printf("\n%s: %llu completions in %.1f s, %.0f packets/s (expect 8000), %llu bad packets, %.0f bytes/s\n",
           mode, n_done, el, n_pkts / el, n_bad, n_bytes / el);
    printf("max gap between completions: %.2f ms\n", max_gap);
    double lo = 0;
    for (int b = 0; b < NBINS; b++) {
        if (b < NBINS - 1) printf("  %5.1f-%5.1f ms: %8llu", lo, bin_ms[b], hist[b]);
        else printf("  >%9.1f ms: %8llu", lo, hist[b]);
        printf("  %7.3f%%\n", n_done > 1 ? 100.0 * hist[b] / (n_done - 1) : 0);
        lo = bin_ms[b];
    }
}

static void make_realtime(void) {
    static __thread int done;
    if (done) return;
    done = 1;
    double ms = 1 / tick_ms;
    thread_time_constraint_policy_data_t p = { (uint32_t)(1 * ms), (uint32_t)(0.3 * ms), (uint32_t)(1 * ms), 1 };
    if (thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                          (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT) != KERN_SUCCESS)
        printf("warning: could not make thread real-time\n");
}

/* ---- libusb mode ---- */
static libusb_context *g_ctx;
static int g_inflight;

static void LIBUSB_CALL lu_cb(struct libusb_transfer *t) {
    if (t->status == LIBUSB_TRANSFER_COMPLETED) {
        int good = 0, bad = 0, bytes = 0;
        for (int i = 0; i < t->num_iso_packets; i++) {
            if (t->iso_packet_desc[i].status == LIBUSB_TRANSFER_COMPLETED) { good++; bytes += t->iso_packet_desc[i].actual_length; }
            else bad++;
        }
        record(good, bad, bytes);
    }
    if (g_stop || t->status == LIBUSB_TRANSFER_CANCELLED || libusb_submit_transfer(t) != 0) g_inflight--;
}

static int run_libusb(void) {
    if (libusb_init(&g_ctx)) return 1;
    libusb_device_handle *h = libusb_open_device_with_vid_pid(g_ctx, VID, PID);
    if (!h) { fprintf(stderr, "SL3 not found\n"); return 1; }
    int cfg = 0, r;
    libusb_get_configuration(h, &cfg);
    if (cfg != 1) libusb_set_configuration(h, 1);
    if ((r = libusb_claim_interface(h, IF_CAP)) || (r = libusb_set_interface_alt_setting(h, IF_CAP, 1))) {
        fprintf(stderr, "claim/alt failed: %s\n", libusb_error_name(r)); return 1;
    }
    struct libusb_transfer *x[256];
    for (int i = 0; i < g_nxf; i++) {
        x[i] = libusb_alloc_transfer(PKTS);
        libusb_fill_iso_transfer(x[i], h, EP_CAP, malloc(PKTS * PKT_MAX), PKTS * PKT_MAX, PKTS, lu_cb, NULL, 1000);
        libusb_set_iso_packet_lengths(x[i], PKT_MAX);
        if (libusb_submit_transfer(x[i]) == 0) g_inflight++;
    }
    make_realtime();
    struct timeval tv = {0, 20000};
    double end = now_ms() + g_secs * 1000;
    while (g_inflight > 0) {
        libusb_handle_events_timeout(g_ctx, &tv);
        if (now_ms() > end) g_stop = 1;
    }
    report("libusb");
    libusb_set_interface_alt_setting(h, IF_CAP, 0);
    libusb_release_interface(h, IF_CAP);
    libusb_close(h);
    return 0;
}

/* ---- IOUSBHost mode ---- */
static io_service_t find_interface(void) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostInterface");
    NSDictionary *props = @{ @"idVendor": @VID, @"idProduct": @PID, @"bInterfaceNumber": @IF_CAP };
    CFDictionarySetValue(m, CFSTR(kIOPropertyMatchKey), (__bridge CFDictionaryRef)props);
    return IOServiceGetMatchingService(kIOMainPortDefault, m);
}

static int run_iousbhost(void) {
    dispatch_queue_attr_t qa = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    dispatch_queue_t q = dispatch_queue_create("sl3.usb", qa);
    NSError *err = nil;

    io_service_t svc = find_interface();
    if (!svc) {
        /* Not configured yet: open the device and set configuration 1. */
        io_service_t dsvc = IOServiceGetMatchingService(kIOMainPortDefault,
            [IOUSBHostDevice createMatchingDictionaryWithVendorID:@VID productID:@PID bcdDevice:nil deviceClass:nil
                                                   deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:nil]);
        if (!dsvc) { fprintf(stderr, "SL3 not found\n"); return 1; }
        IOUSBHostDevice *dev = [[IOUSBHostDevice alloc] initWithIOService:dsvc options:IOUSBHostObjectInitOptionsNone
                                                                    queue:q error:&err interestHandler:nil];
        if (!dev || ![dev configureWithValue:1 matchInterfaces:YES error:&err]) {
            fprintf(stderr, "configure failed: %s\n", err.localizedDescription.UTF8String); return 1;
        }
        [dev destroy];
        IOObjectRelease(dsvc);
        for (int i = 0; i < 50 && !svc; i++) {
            usleep(100000);
            svc = find_interface();
        }
        if (!svc) { fprintf(stderr, "interface %d did not appear\n", IF_CAP); return 1; }
    }
    IOUSBHostInterface *intf = [[IOUSBHostInterface alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone
                                                                        queue:q error:&err interestHandler:nil];
    if (!intf) {
        intf = [[IOUSBHostInterface alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsDeviceSeize
                                                       queue:q error:&err interestHandler:nil];
        if (!intf) { fprintf(stderr, "open interface failed: %s\n", err.localizedDescription.UTF8String); return 1; }
    }
    IOObjectRelease(svc);
    if (![intf selectAlternateSetting:1 error:&err]) { fprintf(stderr, "alt 1 failed: %s\n", err.localizedDescription.UTF8String); return 1; }
    IOUSBHostPipe *pipe = [intf copyPipeWithAddress:EP_CAP error:&err];
    if (!pipe) { fprintf(stderr, "pipe failed: %s\n", err.localizedDescription.UTF8String); return 1; }

    NSMutableArray<NSMutableData *> *bufs = [NSMutableArray array];
    NSMutableArray<NSMutableData *> *lists = [NSMutableArray array];
    for (int i = 0; i < g_nxf; i++) {
        NSMutableData *b = [intf ioDataWithCapacity:PKTS * PKT_MAX error:&err];
        NSMutableData *l = [intf ioDataWithCapacity:PKTS * sizeof(IOUSBHostIsochronousTransaction) error:&err];
        if (!b || !l) { fprintf(stderr, "alloc failed: %s\n", err.localizedDescription.UTF8String); return 1; }
        [bufs addObject:b]; [lists addObject:l];
    }

    __block uint64_t next_frame = [intf frameNumberWithTime:NULL] + 10;
    __block int inflight = 0;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block void (^submit)(int);
    __block BOOL (^enqueue)(int);
    enqueue = ^BOOL(int i) {
        IOUSBHostIsochronousTransaction *tl = lists[i].mutableBytes;
        for (int k = 0; k < PKTS; k++)
            tl[k] = (IOUSBHostIsochronousTransaction){ .requestCount = PKT_MAX, .offset = k * PKT_MAX };
        NSError *e = nil;
        BOOL ok = [pipe enqueueIORequestWithData:bufs[i] transactionList:tl transactionListCount:PKTS
                                firstFrameNumber:next_frame options:IOUSBHostIsochronousTransferOptionsNone error:&e
                               completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
            make_realtime();
            if (st == kIOReturnSuccess) {
                int good = 0, bad = 0, bytes = 0;
                for (int k = 0; k < PKTS; k++) {
                    if (done[k].status == kIOReturnSuccess) { good++; bytes += done[k].completeCount; } else bad++;
                }
                record(good, bad, bytes);
            }
            submit(i);
        }];
        if (!ok) fprintf(stderr, "enqueue failed: %s\n", e.localizedDescription.UTF8String);
        else next_frame++;   /* 8 microframes = 1 frame */
        return ok;
    };
    submit = ^(int i) {
        if (g_stop || !enqueue(i)) { if (--inflight == 0) dispatch_semaphore_signal(finished); return; }
    };
    dispatch_sync(q, ^{
        for (int i = 0; i < g_nxf; i++) if (enqueue(i)) inflight++;
    });
    if (inflight == 0) return 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(g_secs * NSEC_PER_SEC)), q, ^{ g_stop = 1; });
    dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((g_secs + 5) * NSEC_PER_SEC)));
    dispatch_sync(q, ^{ g_stop = 1; });
    report("IOUSBHost");
    [pipe abortWithError:nil];
    [intf selectAlternateSetting:0 error:nil];
    [intf destroy];
    return 0;
}

static void on_sig(int s) { (void)s; g_stop = 1; }

int main(int argc, char **argv) {
    @autoreleasepool {
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        tick_ms = (double)tb.numer / tb.denom / 1e6;
        const char *mode = argc > 1 ? argv[1] : "iousbhost";
        if (argc > 2) g_secs = atof(argv[2]);
        if (argc > 3) g_nxf = atoi(argv[3]);
        if (g_nxf < 1 || g_nxf > 256) g_nxf = 64;
        signal(SIGINT, on_sig);
        printf("%s: %d x 1 ms transfers in flight, %.0f s\n", mode, g_nxf, g_secs);
        if (!strcmp(mode, "libusb")) return run_libusb();
        if (!strcmp(mode, "iousbhost")) return run_iousbhost();
        fprintf(stderr, "usage: %s [iousbhost|libusb] [seconds] [transfers]\n", argv[0]);
        return 2;
    }
}
