/* SL3 probe AudioServerPlugIn: checks whether a HAL plug-in can open the
 * SL3's interface 2 through IOUSBHost from inside coreaudiod's sandbox.
 * Publishes no devices and does no USB I/O; it opens the interface, logs
 * the result and closes it again. Log: log stream --predicate 'subsystem == "sl3.probe"'
 * SPDX-License-Identifier: GPL-3.0-or-later */
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <os/log.h>

#define VID 0x1cc5
#define PID 0x0001

static os_log_t g_log;
static AudioServerPlugInHostRef g_host;
static ULONG g_refs = 1;

static void probe(void) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostInterface");
    NSDictionary *p = @{@"idVendor": @VID, @"idProduct": @PID, @"bInterfaceNumber": @2};
    CFDictionarySetValue(m, CFSTR(kIOPropertyMatchKey), (__bridge CFDictionaryRef)p);
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!s) { os_log(g_log, "probe: SL3 interface 2 not found (box unplugged, or IORegistry lookup blocked)"); return; }
    os_log(g_log, "probe: found SL3 interface 2 service 0x%x", s);
    NSError *e = nil;
    dispatch_queue_t q = dispatch_queue_create("sl3.probe", DISPATCH_QUEUE_SERIAL);
    IOUSBHostInterface *i = [[IOUSBHostInterface alloc] initWithIOService:s options:IOUSBHostObjectInitOptionsNone
                                                                    queue:q error:&e interestHandler:nil];
    IOObjectRelease(s);
    if (!i) { os_log_error(g_log, "probe: open FAILED: %{public}@ (0x%lx)", e.localizedDescription, (long)e.code); return; }
    os_log(g_log, "probe: open OK, alt setting %u", i.interfaceDescriptor->bAlternateSetting);
    [i destroy];
    os_log(g_log, "probe: closed");
}

/* --- minimal driver interface: one plug-in object, no devices --- */
static HRESULT QI(void *d, REFIID iid, LPVOID *out);
static ULONG AddRef(void *d) { (void)d; return ++g_refs; }
static ULONG Release(void *d) { (void)d; return g_refs > 0 ? --g_refs : 0; }

static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    (void)d; g_host = host;
    os_log(g_log, "probe: Initialize (uid %d)", getuid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ @autoreleasepool { probe(); } });
    return noErr;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *o) { (void)d; (void)desc; (void)c; (void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) { (void)d; (void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { (void)d; (void)o; (void)c; return noErr; }
static OSStatus RemoveClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { (void)d; (void)o; (void)c; return noErr; }
static OSStatus PerformCfg(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { (void)d; (void)o; (void)a; (void)i; return noErr; }
static OSStatus AbortCfg(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { (void)d; (void)o; (void)a; (void)i; return noErr; }

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)d; (void)pid;
    if (o != kAudioObjectPlugInObject) return false;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyBoxList: return true;
    }
    return false;
}
static OSStatus IsSettable(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *s) {
    if (!HasProperty(d, o, pid, a)) return kAudioHardwareUnknownPropertyError;
    *s = false; return noErr;
}
static OSStatus GetSize(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *sz) {
    (void)qs; (void)q;
    if (!HasProperty(d, o, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioObjectPropertyManufacturer: *sz = sizeof(CFStringRef); break;
    case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyBoxList: *sz = 0; break;
    default: *sz = sizeof(AudioObjectID);
    }
    return noErr;
}
static OSStatus GetData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 in, UInt32 *out, void *data) {
    (void)qs; (void)q;
    if (!HasProperty(d, o, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: if (in < 4) return kAudioHardwareBadPropertySizeError; *(AudioClassID *)data = kAudioObjectClassID; *out = 4; break;
    case kAudioObjectPropertyClass: if (in < 4) return kAudioHardwareBadPropertySizeError; *(AudioClassID *)data = kAudioPlugInClassID; *out = 4; break;
    case kAudioObjectPropertyOwner: if (in < 4) return kAudioHardwareBadPropertySizeError; *(AudioObjectID *)data = kAudioObjectUnknown; *out = 4; break;
    case kAudioObjectPropertyManufacturer: if (in < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError; *(CFStringRef *)data = CFSTR("sl3-bridge"); *out = sizeof(CFStringRef); break;
    default: *out = 0;
    }
    return noErr;
}
static OSStatus SetData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 sz, const void *data) { (void)d; (void)o; (void)pid; (void)a; (void)qs; (void)q; (void)sz; (void)data; return kAudioHardwareUnknownPropertyError; }
static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) { (void)d; (void)o; (void)c; return kAudioHardwareBadObjectError; }
static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) { (void)d; (void)o; (void)c; return kAudioHardwareBadObjectError; }
static OSStatus ZeroTS(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, Float64 *st, UInt64 *ht, UInt64 *seed) { (void)d; (void)o; (void)c; (void)st; (void)ht; (void)seed; return kAudioHardwareBadObjectError; }
static OSStatus WillDo(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, Boolean *w, Boolean *ip) { (void)d; (void)o; (void)c; (void)op; *w = false; *ip = true; return noErr; }
static OSStatus BeginOp(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { (void)d; (void)o; (void)c; (void)op; (void)n; (void)i; return noErr; }
static OSStatus DoOp(AudioServerPlugInDriverRef d, AudioObjectID o, AudioObjectID s, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i, void *m, void *x) { (void)d; (void)o; (void)s; (void)c; (void)op; (void)n; (void)i; (void)m; (void)x; return noErr; }
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
    AddRef(d); *out = &g_ifacep; return S_OK;
}

__attribute__((visibility("default")))
void *SL3Probe_Create(CFAllocatorRef alloc, CFUUIDRef type) {
    (void)alloc;
    g_log = os_log_create("sl3.probe", "plugin");
    if (!CFEqual(type, kAudioServerPlugInTypeUUID)) return NULL;
    os_log(g_log, "probe: factory called");
    return &g_ifacep;
}
