// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Record a few seconds from a Core Audio device's input and report, per
 * channel, the RMS level and the correlation with every other channel.
 * Used to check the SL3 driver's input path for channel bleed: play
 * timecode on one deck only and look at the other channels.
 *
 * usage: sl3rec [--device NAME] [--seconds N]
 */
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAXCH 16
#define MAXF (44100 * 30)
static float *g_buf;
static UInt32 g_ch, g_n, g_max;

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
    (void)dev; (void)now; (void)in_t; (void)out; (void)out_t; (void)ctx;
    if (!in->mNumberBuffers) return noErr;
    const AudioBuffer *b = &in->mBuffers[0];
    UInt32 ch = b->mNumberChannels, frames = b->mDataByteSize / (sizeof(float) * ch);
    const float *p = b->mData;
    for (UInt32 f = 0; f < frames && g_n < g_max; f++, g_n++)
        for (UInt32 c = 0; c < g_ch; c++) g_buf[g_n * g_ch + c] = c < ch ? p[f * ch + c] : 0;
    return noErr;
}

int main(int argc, char **argv) {
    const char *name = "Rane SL3";
    double secs = 5;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--device") && i + 1 < argc) name = argv[++i];
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) secs = atof(argv[++i]);
        else { fprintf(stderr, "usage: %s [--device NAME] [--seconds N]\n", argv[0]); return 2; }
    }
    AudioDeviceID dev = find_device(name);
    if (!dev) { printf("no device matching \"%s\"\n", name); return 1; }
    AudioObjectPropertyAddress fa = {kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    AudioStreamBasicDescription fmt; UInt32 fsz = sizeof fmt;
    if (AudioObjectGetPropertyData(dev, &fa, 0, NULL, &fsz, &fmt)) { printf("no input stream\n"); return 1; }
    g_ch = fmt.mChannelsPerFrame > MAXCH ? MAXCH : fmt.mChannelsPerFrame;
    g_max = (UInt32)(secs * fmt.mSampleRate);
    if (g_max > MAXF) g_max = MAXF;
    g_buf = calloc((size_t)g_max * g_ch, sizeof(float));
    printf("recording %.1f s from \"%s\": %u ch, %.0f Hz\n", secs, name, (unsigned)g_ch, fmt.mSampleRate);
    AudioDeviceIOProcID pid;
    if (AudioDeviceCreateIOProcID(dev, io_proc, NULL, &pid) || AudioDeviceStart(dev, pid)) { printf("could not start\n"); return 1; }
    while (g_n < g_max) usleep(100000);
    AudioDeviceStop(dev, pid);
    AudioDeviceDestroyIOProcID(dev, pid);

    /* skip the first 0.5 s (startup) */
    UInt32 s0 = (UInt32)(0.5 * fmt.mSampleRate), n = g_n - s0;
    double rms[MAXCH], mean[MAXCH];
    for (UInt32 c = 0; c < g_ch; c++) {
        double m = 0, q = 0;
        for (UInt32 f = s0; f < g_n; f++) m += g_buf[f * g_ch + c];
        m /= n;
        for (UInt32 f = s0; f < g_n; f++) { double v = g_buf[f * g_ch + c] - m; q += v * v; }
        mean[c] = m; rms[c] = sqrt(q / n);
    }
    printf("ch   rms dBFS\n");
    for (UInt32 c = 0; c < g_ch; c++) printf("%2u  %8.1f\n", (unsigned)c + 1, rms[c] > 1e-9 ? 20 * log10(rms[c]) : -180.0);
    printf("correlation\n    ");
    for (UInt32 c = 0; c < g_ch; c++) printf("%7u", (unsigned)c + 1);
    printf("\n");
    for (UInt32 a = 0; a < g_ch; a++) {
        printf("%2u  ", (unsigned)a + 1);
        for (UInt32 b = 0; b < g_ch; b++) {
            double x = 0;
            for (UInt32 f = s0; f < g_n; f++) x += (g_buf[f * g_ch + a] - mean[a]) * (g_buf[f * g_ch + b] - mean[b]);
            double d = rms[a] * rms[b] * n;
            printf("%7.3f", d > 0 ? x / d : 0);
        }
        printf("\n");
    }
    return 0;
}
