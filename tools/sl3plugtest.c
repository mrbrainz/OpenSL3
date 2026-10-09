/* sl3plugtest: exercise build/SL3Device.driver outside Core Audio.
 * Loads the bundle, calls its factory, provides a logging host interface,
 * checks every known property (GetPropertyDataSize vs GetPropertyData) on
 * every object and scope, and cycles StartIO/StopIO. Plays nothing; needs
 * exclusive access to the SL3 (stop any bridge first).
 * Usage: sl3plugtest [bundle] [cycles]
 *        sl3plugtest bundle hotplug SECONDS   (IO running; unplug/replug the box)
 *        sl3plugtest bundle rate HZ SECONDS   (switch rate, then run IO) */
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

static int g_notes, g_running_notes;
static AudioServerPlugInDriverRef g_drv;

static const char *fcc(UInt32 v, char *b) {
    for (int i = 0; i < 4; i++) { char c = (char)(v >> (24 - 8 * i)); b[i] = c >= 32 && c < 127 ? c : '.'; }
    b[4] = 0; return b;
}
static OSStatus H_PropertiesChanged(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a) {
    (void)h; char b[5];
    for (UInt32 i = 0; i < n; i++) {
        printf("  host: PropertiesChanged obj %u '%s'\n", o, fcc(a[i].mSelector, b));
        g_notes++;
        if (a[i].mSelector == kAudioDevicePropertyDeviceIsRunning) g_running_notes++;
    }
    return 0;
}
static OSStatus H_CopyFromStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef *d) { (void)h; (void)k; *d = NULL; return 0; }
static OSStatus H_WriteToStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) {
    (void)h; char b[64]; double v = 0;
    CFStringGetCString(k, b, sizeof b, kCFStringEncodingUTF8);
    if (CFGetTypeID(d) == CFNumberGetTypeID()) CFNumberGetValue(d, kCFNumberDoubleType, &v);
    printf("  host: WriteToStorage \"%s\" = %g\n", b, v);
    return 0;
}
static OSStatus H_DeleteFromStorage(AudioServerPlugInHostRef h, CFStringRef k) { (void)h; (void)k; return 0; }
static OSStatus H_RequestCfg(AudioServerPlugInHostRef h, AudioObjectID o, UInt64 a, void *i) {
    (void)h; printf("  host: RequestDeviceConfigurationChange obj %u action %llu\n", o, a); g_notes++;
    /* Core Audio would stop IO first and call this later, on its own thread */
    OSStatus e = (*g_drv)->PerformDeviceConfigurationChange(g_drv, o, a, i);
    printf("  PerformDeviceConfigurationChange %d\n", (int)e);
    return 0;
}
static AudioServerPlugInHostInterface g_host = {
    H_PropertiesChanged, H_CopyFromStorage, H_WriteToStorage, H_DeleteFromStorage, H_RequestCfg
};

static const AudioObjectPropertySelector SEL[] = {
    kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner, kAudioObjectPropertyName,
    kAudioObjectPropertyModelName, kAudioObjectPropertyManufacturer, kAudioObjectPropertyElementName,
    kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyIdentify, kAudioObjectPropertySerialNumber,
    kAudioObjectPropertyFirmwareVersion, kAudioObjectPropertyControlList,
    kAudioPlugInPropertyBundleID, kAudioPlugInPropertyDeviceList, kAudioPlugInPropertyTranslateUIDToDevice,
    kAudioPlugInPropertyBoxList, kAudioPlugInPropertyTranslateUIDToBox, kAudioPlugInPropertyClockDeviceList,
    kAudioPlugInPropertyResourceBundle,
    kAudioDevicePropertyConfigurationApplication, kAudioDevicePropertyDeviceUID, kAudioDevicePropertyModelUID,
    kAudioDevicePropertyTransportType, kAudioDevicePropertyRelatedDevices, kAudioDevicePropertyClockDomain,
    kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunning, kAudioDevicePropertyDeviceCanBeDefaultDevice,
    kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioDevicePropertyLatency, kAudioDevicePropertyStreams,
    kAudioDevicePropertySafetyOffset, kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyAvailableNominalSampleRates,
    kAudioDevicePropertyIcon, kAudioDevicePropertyIsHidden, kAudioDevicePropertyPreferredChannelsForStereo,
    kAudioDevicePropertyPreferredChannelLayout, kAudioDevicePropertyZeroTimeStampPeriod, kAudioDevicePropertyClockAlgorithm,
    kAudioDevicePropertyClockIsStable,
    kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection, kAudioStreamPropertyTerminalType,
    kAudioStreamPropertyStartingChannel, kAudioStreamPropertyLatency, kAudioStreamPropertyVirtualFormat,
    kAudioStreamPropertyAvailableVirtualFormats, kAudioStreamPropertyPhysicalFormat, kAudioStreamPropertyAvailablePhysicalFormats,
};
static const AudioObjectPropertyScope SC[] = { kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput };

static int walk(AudioServerPlugInDriverRef d, AudioObjectID o, int depth) {
    int bad = 0; char b[5];
    for (size_t s = 0; s < sizeof SEL / sizeof *SEL; s++)
        for (size_t c = 0; c < 3; c++) {
            AudioObjectPropertyAddress a = { SEL[s], SC[c], kAudioObjectPropertyElementMain };
            if (!(*d)->HasProperty(d, o, getpid(), &a)) continue;
            Boolean set; OSStatus e1 = (*d)->IsPropertySettable(d, o, getpid(), &a, &set);
            if (SEL[s] == kAudioPlugInPropertyTranslateUIDToDevice) continue;   /* needs a qualifier */
            UInt32 sz = 0, out = 0; uint8_t buf[1024];
            OSStatus e2 = (*d)->GetPropertyDataSize(d, o, getpid(), &a, 0, NULL, &sz);
            OSStatus e3 = e2 ? e2 : (*d)->GetPropertyData(d, o, getpid(), &a, 0, NULL, sizeof buf, &out, buf);
            int ok = !e1 && !e2 && !e3 && sz == out;
            if (!ok) bad++;
            if (!ok || depth == 0) printf("%*sobj %u '%s' scope '%s': size %u data %u%s\n", depth * 2, "", o, fcc(SEL[s], b),
                                          fcc(SC[c], (char[5]){0}), sz, out, ok ? "" : "  <-- MISMATCH/ERROR");
            /* recurse into owned objects (global scope only) */
            if (!e3 && SEL[s] == kAudioObjectPropertyOwnedObjects && c == 0)
                for (UInt32 i = 0; i < out / sizeof(AudioObjectID); i++) {
                    AudioObjectID ch = ((AudioObjectID *)buf)[i];
                    printf("%*s-> owned obj %u\n", depth * 2, "", ch);
                    if (ch != o && depth < 3) bad += walk(d, ch, depth + 1);
                }
        }
    return bad;
}

static int quiet_walk(AudioServerPlugInDriverRef d) {
    int fd = dup(1); fflush(stdout); freopen("/dev/null", "w", stdout);
    int bad = walk(d, kAudioObjectPlugInObject, 0);
    fflush(stdout); dup2(fd, 1); close(fd);
    return bad;
}
static int hotplug(AudioServerPlugInDriverRef d, int secs) {
    AudioObjectPropertyAddress alive = { kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectPropertyAddress list = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    int bad = 0, seen = 0;
    printf("StartIO %d\n", (int)(*d)->StartIO(d, 2, 1));
    for (int t = 0; t < secs; t++) {
        sleep(1);
        UInt32 v = 9, sz = 0, out; Float64 st; UInt64 ht, seed;
        (*d)->GetPropertyData(d, 2, getpid(), &alive, 0, NULL, 4, &out, &v);
        (*d)->GetPropertyDataSize(d, kAudioObjectPlugInObject, getpid(), &list, 0, NULL, &sz);
        (*d)->GetZeroTimeStamp(d, 2, 1, &st, &ht, &seed);
        printf("%3d s: alive %u, devices %u, zts %.0f seed %llu\n", t + 1, v, sz / 4, st, seed);
        if (g_notes != seen) { seen = g_notes; int b = quiet_walk(d); bad += b; printf("       property walk: %d problems\n", b); }
        fflush(stdout);
    }
    printf("StopIO %d\n", (int)(*d)->StopIO(d, 2, 1));
    for (int t = 0; t < 3; t++) {   /* the device may hide after IO stops */
        sleep(1);
        UInt32 v = 9, sz = 0, out;
        (*d)->GetPropertyData(d, 2, getpid(), &alive, 0, NULL, 4, &out, &v);
        (*d)->GetPropertyDataSize(d, kAudioObjectPlugInObject, getpid(), &list, 0, NULL, &sz);
        printf("after stop %d s: alive %u, devices %u\n", t + 1, v, sz / 4);
    }
    bad += quiet_walk(d);
    printf("== %d property problems, %d host notifications\n", bad, g_notes);
    return bad != 0;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "build/SL3Device.driver";
    int cycles = argc > 2 ? atoi(argv[2]) : 5;
    CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), true);
    CFBundleRef bun = CFBundleCreate(NULL, u);
    if (!bun || !CFBundleLoadExecutable(bun)) { fprintf(stderr, "cannot load %s\n", path); return 1; }
    void *(*factory)(CFAllocatorRef, CFUUIDRef) = CFBundleGetFunctionPointerForName(bun, CFSTR("SL3Device_Create"));
    if (!factory) { fprintf(stderr, "no factory\n"); return 1; }
    AudioServerPlugInDriverRef d = factory(NULL, kAudioServerPlugInTypeUUID);
    AudioServerPlugInHostInterface *hp = &g_host;
    if ((*d)->Initialize(d, hp)) { fprintf(stderr, "Initialize failed\n"); return 1; }
    g_drv = d;
    if (argc > 3 && !strcmp(argv[2], "hotplug")) return hotplug(d, atoi(argv[3]));
    if (argc > 4 && !strcmp(argv[2], "rate")) {
        AudioObjectPropertyAddress sr = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Float64 hz = atof(argv[3]), now = 0; UInt32 out;
        printf("SetPropertyData rate %.0f: %d\n", hz, (int)(*d)->SetPropertyData(d, 2, getpid(), &sr, 0, NULL, sizeof hz, &hz));
        (*d)->GetPropertyData(d, 2, getpid(), &sr, 0, NULL, sizeof now, &out, &now);
        printf("nominal rate now %.0f\n", now);
        int bad = quiet_walk(d);
        printf("StartIO %d\n", (int)(*d)->StartIO(d, 2, 1));
        sleep(atoi(argv[4]));
        printf("StopIO %d\n== %d property problems\n", (int)(*d)->StopIO(d, 2, 1), bad);
        return bad != 0;
    }
    printf("== property walk (idle)\n");
    int bad = walk(d, kAudioObjectPlugInObject, 0);
    AudioObjectPropertyAddress run = { kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    for (int i = 0; i < cycles; i++) {
        printf("== cycle %d: StartIO\n", i + 1);
        OSStatus e = (*d)->StartIO(d, 2, 1);
        UInt32 v = 9, out; (*d)->GetPropertyData(d, 2, getpid(), &run, 0, NULL, 4, &out, &v);
        printf("  StartIO %d, IsRunning %u\n", (int)e, v);
        if (e) { bad++; continue; }
        if (i == 0) { printf("== property walk (running)\n"); bad += walk(d, kAudioObjectPlugInObject, 0); }
        usleep(500000);
        Float64 st; UInt64 ht, seed; (*d)->GetZeroTimeStamp(d, 2, 1, &st, &ht, &seed);
        printf("  zts sample %.0f seed %llu\n", st, seed);
        e = (*d)->StopIO(d, 2, 1);
        (*d)->GetPropertyData(d, 2, getpid(), &run, 0, NULL, 4, &out, &v);
        printf("  StopIO %d, IsRunning %u\n", (int)e, v);
        usleep(300000);
    }
    printf("== %d property problems, %d host notifications (%d IsRunning)\n", bad, g_notes, g_running_notes);
    return bad != 0;
}
