// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Round-trip latency through a loopback cable: plays a short 1 kHz burst on
 * one output channel every 0.5 s at known device sample times, and finds it
 * on one input channel. Input and output share the device's sample
 * timeline, so the delay found is the latency outside that timeline
 * (converters and the analog path), i.e. input + output device latency.
 *
 * usage: sl3loop [--device NAME] [--out CH] [--in CH] [--seconds N] [--db DBFS]
 */
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PERIOD 22050
#define BURST 44
#define MAXD 8192
static int g_out = 5, g_in = 5;
static double g_amp;
static double g_thresh, g_noise;
static long g_found, g_missed;
static double g_sum, g_min = 1e9, g_max = -1e9;
static double g_armed = -1;   /* sample time of last burst, waiting for it */
static long g_calls;

static AudioDeviceID find_device(const char *needle) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 sz = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
    AudioDeviceID ids[64], found = 0;
    if (sz > sizeof ids) sz = sizeof ids;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    for (UInt32 i = 0; i < sz / sizeof(AudioDeviceID) && !found; i++) {
        CFStringRef name = NULL; UInt32 ns = sizeof name;
        AudioObjectPropertyAddress na = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &ns, &name) || !name) continue;
        char buf[256];
        CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
        CFRelease(name);
        if (strstr(buf, needle)) found = ids[i];
    }
    return found;
}

static OSStatus io_proc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in,
                        const AudioTimeStamp *in_t, AudioBufferList *out, const AudioTimeStamp *out_t, void *ctx) {
    (void)dev; (void)now; (void)ctx;
    g_calls++;
    /* output: burst at every multiple of PERIOD */
    if (out->mNumberBuffers) {
        AudioBuffer *b = &out->mBuffers[0];
        UInt32 ch = b->mNumberChannels, n = b->mDataByteSize / (sizeof(float) * ch);
        float *p = b->mData;
        memset(p, 0, b->mDataByteSize);
        for (UInt32 f = 0; f < n; f++) {
            long s = (long)out_t->mSampleTime + f, k = s % PERIOD;
            if (k < BURST && (UInt32)g_out <= ch) p[f * ch + g_out - 1] = (float)(g_amp * sin(2 * M_PI * k / 44.1));
            if (k == 0 && g_calls > 50) {
                if (g_armed >= 0) g_missed++;
                g_armed = (double)s;
            }
        }
    }
    /* input: first sample above threshold after a burst */
    if (in->mNumberBuffers) {
        const AudioBuffer *b = &in->mBuffers[0];
        UInt32 ch = b->mNumberChannels, n = b->mDataByteSize / (sizeof(float) * ch);
        const float *p = b->mData;
        for (UInt32 f = 0; f < n && (UInt32)g_in <= ch; f++) {
            double v = fabs(p[f * ch + g_in - 1]), s = in_t->mSampleTime + f;
            if (g_calls < 50) { if (v > g_noise) g_noise = v; continue; }
            if (g_armed < 0 || s < g_armed) continue;
            if (s - g_armed > MAXD) { g_missed++; g_armed = -1; continue; }
            if (v > g_thresh) {
                double d = s - g_armed;
                g_sum += d; g_found++;
                if (d < g_min) g_min = d;
                if (d > g_max) g_max = d;
                g_armed = -1;
            }
        }
    }
    return noErr;
}

int main(int argc, char **argv) {
    const char *name = "Rane SL3";
    double secs = 10, db = -20;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--device") && i + 1 < argc) name = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) g_out = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--in") && i + 1 < argc) g_in = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) secs = atof(argv[++i]);
        else if (!strcmp(argv[i], "--db") && i + 1 < argc) db = atof(argv[++i]);
        else { fprintf(stderr, "usage: %s [--device NAME] [--out CH] [--in CH] [--seconds N] [--db DBFS]\n", argv[0]); return 2; }
    }
    AudioDeviceID dev = find_device(name);
    if (!dev) { printf("no device matching \"%s\"\n", name); return 1; }
    g_amp = pow(10, db / 20);
    printf("bursts on output %d, listening on input %d, %.0f s\n", g_out, g_in, secs);
    AudioDeviceIOProcID pid;
    if (AudioDeviceCreateIOProcID(dev, io_proc, NULL, &pid)) { printf("could not create IOProc\n"); return 1; }
    g_thresh = 1;   /* set after the noise floor is known */
    if (AudioDeviceStart(dev, pid)) { printf("could not start\n"); return 1; }
    usleep(1000000);
    g_thresh = g_noise * 4 > 0.003 ? g_noise * 4 : 0.003;
    printf("noise floor %.5f, threshold %.5f\n", g_noise, g_thresh);
    usleep((useconds_t)(secs * 1e6));
    AudioDeviceStop(dev, pid);
    AudioDeviceDestroyIOProcID(dev, pid);
    if (!g_found) { printf("no bursts found (%ld missed): check the cable, channels and level\n", g_missed); return 1; }
    double avg = g_sum / g_found;
    printf("found %ld, missed %ld: round trip %.1f frames (%.2f ms), min %.0f max %.0f\n",
           g_found, g_missed, avg, avg / 44.1, g_min, g_max);
    return 0;
}
