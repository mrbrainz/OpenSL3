// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Play a sine tone on all output channels of a Core Audio device, to check
 * the SL3 driver's output path without an app in between.
 *
 * usage: sl3tone [--device NAME] [--seconds N] [--freq HZ] [--db DBFS]
 */
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static double g_phase, g_step, g_amp;

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
    (void)dev; (void)now; (void)in; (void)in_t; (void)out_t; (void)ctx;
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        AudioBuffer *ab = &out->mBuffers[b];
        UInt32 ch = ab->mNumberChannels, frames = ab->mDataByteSize / (sizeof(float) * ch);
        float *p = ab->mData;
        double ph = g_phase;
        for (UInt32 f = 0; f < frames; f++, ph += g_step)
            for (UInt32 c = 0; c < ch; c++) p[f * ch + c] = (float)(g_amp * sin(ph));
        if (b == out->mNumberBuffers - 1) g_phase = fmod(ph, 2 * M_PI);
    }
    return noErr;
}

int main(int argc, char **argv) {
    const char *name = "Rane SL3";
    double secs = 5, freq = 440, db = -20;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--device") && i + 1 < argc) name = argv[++i];
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) secs = atof(argv[++i]);
        else if (!strcmp(argv[i], "--freq") && i + 1 < argc) freq = atof(argv[++i]);
        else if (!strcmp(argv[i], "--db") && i + 1 < argc) db = atof(argv[++i]);
        else { fprintf(stderr, "usage: %s [--device NAME] [--seconds N] [--freq HZ] [--db DBFS]\n", argv[0]); return 2; }
    }
    AudioDeviceID dev = find_device(name);
    if (!dev) { printf("no device matching \"%s\"\n", name); return 1; }
    Float64 rate = 44100; UInt32 rs = sizeof rate;
    AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(dev, &ra, 0, NULL, &rs, &rate);
    g_step = 2 * M_PI * freq / rate;
    g_amp = pow(10, db / 20);
    printf("playing %.0f Hz at %.0f dBFS on \"%s\" for %.0f s\n", freq, db, name, secs);
    AudioDeviceIOProcID pid;
    if (AudioDeviceCreateIOProcID(dev, io_proc, NULL, &pid) || AudioDeviceStart(dev, pid)) { printf("could not start\n"); return 1; }
    usleep((useconds_t)(secs * 1e6));
    AudioDeviceStop(dev, pid);
    AudioDeviceDestroyIOProcID(dev, pid);
    return 0;
}
