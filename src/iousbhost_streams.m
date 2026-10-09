// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * SL3 session through Apple's IOUSBHost framework: audio streams (interfaces
 * 1 and 2) and the control channel (interface 3). Included by sl3bridge.c
 * when built with -DSL3_IOUSBHOST, in place of the libusb code.
 *
 * All completions and the heartbeat timer run on one serial dispatch queue,
 * which replaces the libusb event thread. Transfers are scheduled on explicit frame
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
static rate_est_t g_ioh_sl3_rate;   /* only touched on g_ioh_q */
static double g_ioh_sl3_frames, g_ioh_tick_ms;

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
        if (pipe == g_ioh_cpipe) rate_reset(&g_ioh_sl3_rate, &g_rate_sl3);   /* capture frames were skipped */
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
            for (int k = 0; k < CAP_PKTS; k++) {
                cap_packet(p + done[k].offset, done[k].completeCount, done[k].status == kIOReturnSuccess);
                g_ioh_sl3_frames += done[k].completeCount / FRAME_BYTES;
            }
            /* controller timestamp of the last microframe: the SL3's clock against host time */
            if (done[CAP_PKTS - 1].timeStamp)
                rate_add(&g_ioh_sl3_rate, done[CAP_PKTS - 1].timeStamp * g_ioh_tick_ms, g_ioh_sl3_frames, &g_rate_sl3);
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
    if (!g_ioh_tick_ms) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); g_ioh_tick_ms = (double)tb.numer / tb.denom / 1e6; }
    dispatch_sync(g_ioh_q, ^{
        g_ioh_sl3_frames = 0;
        rate_reset(&g_ioh_sl3_rate, &g_rate_sl3);
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

/* ---- interface 3: control requests and heartbeat (see the libusb version) ---- */
static int g_hid_ok, g_hb_busy;
static uint32_t g_hb_seq;
static IOUSBHostInterface *g_ioh_hid;
static IOUSBHostPipe *g_ioh_hout, *g_ioh_hin;
static NSMutableData *g_ioh_req_out, *g_ioh_req_in, *g_ioh_hb_out, *g_ioh_hb_in;
static dispatch_source_t g_ioh_hb_timer;
static _Atomic int g_ioh_hb_inflight;

static int ioh_open_hid(void) {
    NSError *e = nil;
    if (!(g_ioh_hid = ioh_open(IF_HID)) ||
        !(g_ioh_hout = [g_ioh_hid copyPipeWithAddress:EP_HID_OUT error:&e]) ||
        !(g_ioh_hin = [g_ioh_hid copyPipeWithAddress:EP_HID_IN error:&e]) ||
        !(g_ioh_req_out = [g_ioh_hid ioDataWithCapacity:HID_REPORT error:&e]) ||
        !(g_ioh_req_in = [g_ioh_hid ioDataWithCapacity:HID_REPORT error:&e]) ||
        !(g_ioh_hb_out = [g_ioh_hid ioDataWithCapacity:HID_REPORT error:&e]) ||
        !(g_ioh_hb_in = [g_ioh_hid ioDataWithCapacity:HID_REPORT error:&e])) {
        printf("  warning: interface 3 unavailable (%s); box will stay in thru\n", e ? e.localizedDescription.UTF8String : "not found");
        [g_ioh_hid destroy];
        g_ioh_hid = nil; g_ioh_hout = g_ioh_hin = nil;
        return 0;
    }
    return 1;
}

/* Synchronous request; only used while the heartbeat is not running. Interrupt
 * pipes take no completion timeout, so reads are queued and aborted if late. */
static int hid_request(uint8_t cmd, const uint8_t *payload, int len, uint8_t *reply) {
    uint8_t *out = g_ioh_req_out.mutableBytes;
    uint32_t seq = g_hid_seq++;
    memset(out, 0, HID_REPORT);
    out[0] = cmd;
    memcpy(out + 1, &seq, 4);
    if (len) memcpy(out + 5, payload, len);
    NSUInteger n = 0;
    if (![g_ioh_hout sendIORequestWithData:g_ioh_req_out bytesTransferred:&n completionTimeout:0 error:nil]) return -1;
    double t0 = ms_now();
    while (ms_now() - t0 < 500) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block IOReturn st = kIOReturnError;
        __block NSUInteger got = 0;
        if (![g_ioh_hin enqueueIORequestWithData:g_ioh_req_in completionTimeout:0 error:nil
                               completionHandler:^(IOReturn s2, NSUInteger n2) { st = s2; got = n2; dispatch_semaphore_signal(done); }])
            return -1;
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC))) {
            [g_ioh_hin abortWithError:nil];
            dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        }
        if (st != kIOReturnSuccess || got < 5) continue;
        memcpy(reply, g_ioh_req_in.bytes, HID_REPORT);
        uint32_t s; memcpy(&s, reply + 1, 4);
        if (reply[0] == cmd && s == seq) return 0;
    }
    return -1;
}

static void ioh_hb_read(void) {
    g_ioh_hb_inflight++;
    BOOL ok = [g_ioh_hin enqueueIORequestWithData:g_ioh_hb_in completionTimeout:0 error:nil
                                completionHandler:^(IOReturn st, NSUInteger n) {
        const uint8_t *b = g_ioh_hb_in.bytes;
        if (st == kIOReturnSuccess && n >= 5) {
            uint32_t s; memcpy(&s, b + 1, 4);
            if (b[0] == 0x37 && s == g_hb_seq) g_hb_replies++;
        }
        g_ioh_hb_inflight--;
        if (!U.stop && !ioh_fatal(st)) ioh_hb_read();
    }];
    if (!ok) g_ioh_hb_inflight--;
}

static void ioh_hb_tick(void) {
    if (U.stop || g_hb_busy) return;
    uint8_t *b = g_ioh_hb_out.mutableBytes;
    g_hb_seq = g_hid_seq++;
    memset(b, 0, HID_REPORT);
    b[0] = 0x37;
    memcpy(b + 1, &g_hb_seq, 4);
    arc4random_buf(b + 5, 8);
    g_hb_busy = 1;
    g_ioh_hb_inflight++;
    BOOL ok = [g_ioh_hout enqueueIORequestWithData:g_ioh_hb_out completionTimeout:0 error:nil
                                 completionHandler:^(IOReturn st, NSUInteger n) {
        (void)n;
        if (st == kIOReturnSuccess) g_hb_sent++;
        g_hb_busy = 0;
        g_ioh_hb_inflight--;
    }];
    if (!ok) { g_hb_busy = 0; g_ioh_hb_inflight--; }
}

static void heartbeat_start(void) {
    dispatch_sync(g_ioh_q, ^{ ioh_hb_read(); });
    g_ioh_hb_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_ioh_q);
    dispatch_source_set_timer(g_ioh_hb_timer, dispatch_time(DISPATCH_TIME_NOW, 0), HEARTBEAT_MS * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_ioh_hb_timer, ^{ ioh_hb_tick(); });
    dispatch_resume(g_ioh_hb_timer);
}

static void heartbeat_stop(void) {
    if (g_ioh_hb_timer) { dispatch_source_cancel(g_ioh_hb_timer); g_ioh_hb_timer = nil; }
    [g_ioh_hin abortWithError:nil];
    [g_ioh_hout abortWithError:nil];
    for (int i = 0; i < 100 && g_ioh_hb_inflight > 0; i++) usleep(10000);
    dispatch_sync(g_ioh_q, ^{});
}

/* ---- SL3 session: open, stream, and tear down (repeatable for reconnects) ---- */
static int sl3_connect(void) {
    if (ioh_open_streams()) return -1;

    /* fresh USB-side state; the CoreAudio side keeps running throughout */
    memset(&U, 0, sizeof U);
    fifo_w = fifo_r = 0;
    rd_out.primed = 0;
    g_hb_busy = 0; g_hb_sent = g_hb_replies = 0;
    g_ioh_hb_inflight = 0;

    if (ioh_start_streams()) printf("  could not start audio streams\n");   /* U.stop is set; main loop reconnects */
    g_hid_ok = ioh_open_hid();
    if (g_hid_ok) {
        set_usb_switches(0x01);
        heartbeat_start();
    }
    fflush(stdout);
    return 0;
}

/* present: the box is still there, so hand the decks back to thru. */
static void sl3_disconnect(int present) {
    U.stop = 1;
    ioh_stop_streams(present);
    if (g_hid_ok) {
        heartbeat_stop();
        if (present) {
            printf("  returning decks to thru\n");
            set_usb_switches(0x00);
        }
        printf("  heartbeat: sent %ld, replies %ld\n", g_hb_sent, g_hb_replies);
        [g_ioh_hid destroy];
    }
    g_ioh_hid = nil; g_ioh_hout = g_ioh_hin = nil;
    g_ioh_req_out = g_ioh_req_in = g_ioh_hb_out = g_ioh_hb_in = nil;
    g_hid_ok = 0;
    fflush(stdout);
}
