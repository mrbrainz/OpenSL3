# The bridge (`sl3bridge`)

`sl3bridge` was this project's first way to use the SL3 on Apple Silicon, before the Core Audio driver existed. It is a command-line program that talks to the box from user space with [libusb](https://libusb.info) (or Apple's IOUSBHost framework) and passes its audio to and from a BlackHole loopback device. **The driver described in the [README](../README.md) replaces it**: it needs no loopback device, no resampling and no program left running, and has lower latency. The bridge is kept for reference and for setups where a Core Audio plug-in can't be installed.

Use either the driver or the bridge, not both: only one of them can own the SL3 at a time.

## How it works

```
 turntables / CDJs                                         mixer
        │                                                    ▲
        ▼                                                    │
   ┌─────────┐   USB (libusb)   ┌───────────┐   CoreAudio   ┌──────────────┐
   │   SL3   │ ◄──────────────► │ sl3bridge │ ◄───────────► │ BlackHole 16 │ ◄──► Mixxx
   └─────────┘                  └───────────┘               └──────────────┘
```

`sl3bridge`:

- streams the SL3's six inputs and six outputs (3 stereo decks, 24-bit, 44.1 kHz);
- maps **SL3 inputs 1–6 → BlackHole channels 1–6** and **BlackHole channels 7–12 → SL3 outputs 1–6**;
- corrects for drift between the SL3's clock and the Mac's with a small adaptive resampler;
- switches the decks from analog thru to USB audio, and back to thru when it exits;
- waits for the box and reconnects if it is unplugged or loses power.

How the SL3 protocol works is documented in [PROTOCOL.md](PROTOCOL.md).

## Requirements

- An Apple Silicon Mac. Intel Macs should also work, but haven't been tested.
- [Homebrew](https://brew.sh) with `libusb` and `pkg-config`
- [BlackHole](https://github.com/ExistentialAudio/BlackHole) 16ch
- [Mixxx](https://mixxx.org) or other DJ software that supports timecode control

```sh
brew install libusb pkg-config blackhole-16ch
```

## Build

```sh
make
```

The bridge and the diagnostic tools are written to `build/`. The bridge sets the box to 44.1 kHz at start, since the box keeps its sample rate across power cycles.

## Run

Plug in the SL3, then:

```sh
build/sl3bridge
```

Leave it running while you play. Every second it prints a status line with buffer fill, heartbeat replies and per-channel peak levels. Press Ctrl-C to stop; the decks go back to analog thru.

`build/sl3bridge-iousbhost` is an experimental build of the same bridge that talks to the SL3 through Apple's IOUSBHost framework rather than libusb, and needs no libusb. It takes the same options, except that `--cap-pkts` and `--play-pkts` must be multiples of 8.

| Option | Default | Meaning |
|--------|---------|---------|
| `--device NAME` | `BlackHole 16ch` | Loopback device to use (matched by substring) |
| `--buffer FRAMES` | `256` | CoreAudio I/O buffer size |
| `--target FRAMES` | 3 × buffer | Input ring buffer target (SL3 → Mac) |
| `--out-target FRAMES` | 2 × buffer | Output ring buffer target (Mac → SL3) |
| `--cap-pkts N`, `--cap-xfers N` | 8, 64 | Capture USB transfers: microframes each, number queued |
| `--play-pkts N`, `--play-xfers N` | 8, 12 | Playback USB transfers. The queue depth adds to output latency |

At the defaults the bridge adds about 24 ms on input and 29 ms on output, and prints its estimate at startup. Lower settings can drop audio. Watch the `under` counters and check that both packet rates stay at 8,000 per second.

## Mixxx setup with the bridge

**Preferences → Sound Hardware** (sound API CoreAudio, sample rate 44,100 Hz). Use **BlackHole 16ch** for everything:

| Output | Channels | | Input | Channels |
|--------|----------|-|-------|----------|
| Deck 1 | 7–8 | | Vinyl Control 1 | 1–2 |
| Deck 2 | 9–10 | | Vinyl Control 2 | 3–4 |
| Deck 3 | 11–12 | | Vinyl Control 3 | 5–6 |

Never send any Mixxx output to channels 1–6: BlackHole mixes every client's output together, so it would leak into the timecode.

Set Mixxx's **audio buffer** (Preferences → Sound Hardware) as low as plays without dropouts, for example about 5 ms. It adds to the latency on top of the bridge's own buffering.

**Preferences → Vinyl Control:** set the vinyl type for each deck (for example *Serato CV02 Vinyl*, or *Serato CD* for the control CD). Turn on vinyl control on each deck, in ABS mode for needle dropping. Deck 3 needs a skin that shows four decks.

## Failure behaviour

| Event | What you hear |
|-------|---------------|
| Bridge stopped (Ctrl-C, terminal closed, `kill`) | Analog thru |
| SL3 unplugged, or the Mac loses power | Analog thru (the box falls back by itself) |
| SL3 plugged back in while the bridge runs | USB audio resumes automatically |
| Bridge crashes or is force-killed (`kill -9`) | Silence until the bridge is restarted |
