// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Audio streams (interfaces 1 and 2) through Apple's IOUSBHost framework.
 * Included by sl3bridge.c when built with -DSL3_IOUSBHOST; interface 3 still
 * goes through libusb.
 *
 * All stream completions run on one serial dispatch queue, which replaces the
 * libusb event thread for audio. Transfers are scheduled on explicit frame
 * numbers (1 ms each), so packets per transfer must be a multiple of 8.
 */
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>

static dispatch_queue_t g_ioh_q;
static IOUSBHostInterface *g_ioh_cap, *g_ioh_play;
static IOUSBHostPipe *g_ioh_cpipe, *g_ioh_ppipe;
static NSMutableData *g_ioh_cbuf[MAX_NXF], *g_ioh_pbuf[MAX_NXF];
static IOUSBHostIsochronousTransaction g_ioh_ctl[MAX_NXF][64], g_ioh_ptl[MAX_NXF][64];
static uint64_t g_ioh_cframe, g_ioh_pframe;
static _Atomic int g_ioh_inflight;

static io_service_t ioh_find(const char *cls, int ifnum) {
    CFMutableDictionaryRef m = IOServiceMatching(cls);
    NSMutableDictionary *p = [@{@"idVendor": @VID, @"idProduct": @PID} mutableCopy];
    if (ifnum >= 0) p[@"bInterfaceNumber"] = @(ifnum);
    CFDictionarySetValue(m, CFSTR(kIOPropertyMatchKey), (__bridge CFDictionaryRef)p);
    return IOServiceGetMatchingService(kIOMainPortDefault, m);
}

static IOUSBHostInterface *ioh_open(int ifnum) {
    io_service_t s = ioh_find("IOUSBHostInterface", ifnum);
    if (!s) return nil;
    NSError *e = nil;
    IOUSBHostInterface *i = [[IOUSBHostInterface alloc] initWithIOService:s options:IOUSBHostObjectInitOptionsNone
                                                                    queue:g_ioh_q error:&e interestHandler:nil];
    IOObjectRelease(s);
    if (!i) printf("  open interface %d failed: %s\n", ifnum, e.localizedDescription.UTF8String);
    return i;
}

/* Dispatch hands blocks to pool threads; make each one real-time on first use. */
static void ioh_realtime(void) {
    static __thread int done;
    if (!done) { done = 1; make_realtime(); }
}

/* Device gone or pipe aborted: stop resubmitting and let the main loop reconnect. */
static int ioh_fatal(IOReturn st) {
    return st == kIOReturnAborted || st == kIOReturnNoDevice || st == kIOReturnNotAttached || st == kIOReturnOffline;
}

static void ioh_cap_submit(int i);
static void ioh_play_submit(int i);

/* Enqueue with the given frame number; if it is already in the past, resync once. */
static BOOL ioh_enqueue(IOUSBHostPipe *pipe, IOUSBHostInterface *intf, NSMutableData *d, IOUSBHostIsochronousTransaction *tl,
                        int n, uint64_t *frame, IOUSBHostIsochronousTransactionCompletionHandler h) {
    for (int attempt = 0; attempt < 2; attempt++) {
        NSError *e = nil;
        if ([pipe enqueueIORequestWithData:d transactionList:tl transactionListCount:n firstFrameNumber:*frame
                                   options:IOUSBHostIsochronousTransferOptionsNone error:&e completionHandler:h]) {
            *frame += n / 8;
            return YES;
        }
        U.xfer_err++;
        *frame = [intf frameNumberWithTime:NULL] + 2;
    }
    return NO;
}

static void ioh_cap_submit(int i) {
    IOUSBHostIsochronousTransaction *tl = g_ioh_ctl[i];
    for (int k = 0; k < CAP_PKTS; k++)
        tl[k] = (IOUSBHostIsochronousTransaction){ .requestCount = PKT_MAX, .offset = k * PKT_MAX };
    NSMutableData *d = g_ioh_cbuf[i];
    BOOL ok = ioh_enqueue(g_ioh_cpipe, g_ioh_cap, d, tl, CAP_PKTS, &g_ioh_cframe, ^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
        ioh_realtime();
        static double last; note_gap(&last, &g_gap_usb);
        if (st == kIOReturnSuccess) {
            const uint8_t *p = d.bytes;
            for (int k = 0; k < CAP_PKTS; k++)
                cap_packet(p + done[k].offset, done[k].completeCount, done[k].status == kIOReturnSuccess);
        } else if (!ioh_fatal(st)) U.xfer_err++;
        if (U.stop || ioh_fatal(st)) { U.stop = 1; g_ioh_inflight--; return; }
        ioh_cap_submit(i);
    });
    if (!ok) { g_ioh_inflight--; U.stop = 1; }
}

static void ioh_play_submit(int i) {
    IOUSBHostIsochronousTransaction *tl = g_ioh_ptl[i];
    int lens[64], off = 0;
    fill_play_buf(g_ioh_pbuf[i].mutableBytes, PLAY_PKTS, lens);
    for (int k = 0; k < PLAY_PKTS; k++) {
        tl[k] = (IOUSBHostIsochronousTransaction){ .requestCount = (uint32_t)lens[k], .offset = (uint32_t)off };
        off += lens[k];
    }
    BOOL ok = ioh_enqueue(g_ioh_ppipe, g_ioh_play, g_ioh_pbuf[i], tl, PLAY_PKTS, &g_ioh_pframe, ^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
        ioh_realtime();
        if (st == kIOReturnSuccess) {
            for (int k = 0; k < PLAY_PKTS; k++) {
                U.play_pkts++;
                if (done[k].status != kIOReturnSuccess) U.play_err++;
            }
        } else if (!ioh_fatal(st)) U.xfer_err++;
        if (U.stop || ioh_fatal(st)) { U.stop = 1; g_ioh_inflight--; return; }
        ioh_play_submit(i);
    });
    if (!ok) { g_ioh_inflight--; U.stop = 1; }
}

/* Open interfaces 1 and 2 at alt 1, configuring the device first if needed. */
static int ioh_open_streams(void) {
    if (!g_ioh_q) {
        dispatch_queue_attr_t qa = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        g_ioh_q = dispatch_queue_create("sl3.usb", qa);
    }
    io_service_t dsvc = ioh_find("IOUSBHostDevice", -1);
    if (!dsvc) return -1;
    io_service_t isvc = ioh_find("IOUSBHostInterface", IF_CAP);
    if (isvc) IOObjectRelease(isvc);
    else {
        NSError *e = nil;
        IOUSBHostDevice *dev = [[IOUSBHostDevice alloc] initWithIOService:dsvc options:IOUSBHostObjectInitOptionsNone
                                                                    queue:g_ioh_q error:&e interestHandler:nil];
        if (!dev || ![dev configureWithValue:1 matchInterfaces:YES error:&e]) {
            printf("  set configuration failed: %s\n", e.localizedDescription.UTF8String);
            IOObjectRelease(dsvc);
            return -1;
        }
        [dev destroy];
        for (int i = 0; i < 30 && !(isvc = ioh_find("IOUSBHostInterface", IF_CAP)); i++) usleep(100000);
        if (isvc) IOObjectRelease(isvc);
    }
    IOObjectRelease(dsvc);
    printf("[SL3] connected (IOUSBHost streams)\n");
    NSError *e = nil;
    g_ioh_cap = ioh_open(IF_CAP);
    g_ioh_play = ioh_open(IF_PLAY);
    if (!g_ioh_cap || !g_ioh_play ||
        ![g_ioh_cap selectAlternateSetting:1 error:&e] || ![g_ioh_play selectAlternateSetting:1 error:&e] ||
        !(g_ioh_cpipe = [g_ioh_cap copyPipeWithAddress:EP_CAP error:&e]) ||
        !(g_ioh_ppipe = [g_ioh_play copyPipeWithAddress:EP_PLAY error:&e])) {
        printf("  interface setup failed: %s\n", e ? e.localizedDescription.UTF8String : "interface not found");
        [g_ioh_cap destroy]; [g_ioh_play destroy];
        g_ioh_cap = g_ioh_play = nil; g_ioh_cpipe = g_ioh_ppipe = nil;
        return -1;
    }
    return 0;
}

/* Queue capture, let ~50 ms of packet sizes arrive, then start playback. */
static int ioh_start_streams(void) {
    NSError *e = nil;
    for (int i = 0; i < CAP_NXF; i++)
        if (!(g_ioh_cbuf[i] = [g_ioh_cap ioDataWithCapacity:CAP_PKTS * PKT_MAX error:&e])) goto fail;
    for (int i = 0; i < PLAY_NXF; i++)
        if (!(g_ioh_pbuf[i] = [g_ioh_play ioDataWithCapacity:PLAY_PKTS * PKT_MAX error:&e])) goto fail;
    g_ioh_inflight = 0;
    dispatch_sync(g_ioh_q, ^{
        g_ioh_cframe = [g_ioh_cap frameNumberWithTime:NULL] + 3;
        for (int i = 0; i < CAP_NXF && !U.stop; i++) { g_ioh_inflight++; ioh_cap_submit(i); }
    });
    usleep(50000);
    dispatch_sync(g_ioh_q, ^{
        fifo_r = fifo_w;
        g_ioh_pframe = [g_ioh_play frameNumberWithTime:NULL] + 2;
        for (int i = 0; i < PLAY_NXF && !U.stop; i++) { g_ioh_inflight++; ioh_play_submit(i); }
    });
    return U.stop ? -1 : 0;
fail:
    printf("  buffer allocation failed: %s\n", e.localizedDescription.UTF8String);
    return -1;
}

/* present: the box is still there, so put the interfaces back to alt 0. */
static void ioh_stop_streams(int present) {
    U.stop = 1;
    [g_ioh_cpipe abortWithError:nil];
    [g_ioh_ppipe abortWithError:nil];
    for (int i = 0; i < 200 && g_ioh_inflight > 0; i++) usleep(10000);
    if (g_ioh_inflight > 0) printf("  warning: %d stream transfers did not complete\n", (int)g_ioh_inflight);
    if (present) {
        [g_ioh_play selectAlternateSetting:0 error:nil];
        [g_ioh_cap selectAlternateSetting:0 error:nil];
    }
    [g_ioh_cap destroy]; [g_ioh_play destroy];
    dispatch_sync(g_ioh_q, ^{});   /* let any completion still running finish */
    g_ioh_cap = g_ioh_play = nil; g_ioh_cpipe = g_ioh_ppipe = nil;
    for (int i = 0; i < MAX_NXF; i++) g_ioh_cbuf[i] = g_ioh_pbuf[i] = nil;
}
