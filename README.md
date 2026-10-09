# SL3 Bridge

Use a **Rane SL3** DVS interface on an Apple Silicon Mac, with no kernel extension and no Serato software.

Rane's SL3 driver is an Intel-only kext, and the last Scratch Live releases are Intel-only too, so the SL3 doesn't work on Apple Silicon Macs. This project talks to the box from user space with [libusb] and passes its audio to and from a loopback device, so open-source DJ software such as [Mixxx] can use it for timecode control.

**Status:** working. All three decks play in Mixxx with Serato control CDs. Timecode comes in, track audio goes out, and the box falls back to analog thru when the bridge stops.

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

How the SL3 protocol works is documented in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Requirements

- An Apple Silicon Mac. Intel Macs should also work, but haven't been tested.
- [Homebrew] with `libusb` and `pkg-config`
- [BlackHole] 16ch
- [Mixxx] or other DJ software that supports timecode control

```sh
brew install libusb pkg-config blackhole-16ch
```

## Build

```sh
make
```

The binaries are written to `build/`.

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

## Mixxx setup

**Preferences → Sound Hardware** (sound API CoreAudio, sample rate 44,100 Hz). Use **BlackHole 16ch** for everything:

| Output | Channels | | Input | Channels |
|--------|----------|-|-------|----------|
| Deck 1 | 7–8 | | Vinyl Control 1 | 1–2 |
| Deck 2 | 9–10 | | Vinyl Control 2 | 3–4 |
| Deck 3 | 11–12 | | Vinyl Control 3 | 5–6 |

Never send any Mixxx output to channels 1–6: BlackHole mixes every client's output together, so it would leak into the timecode.

Set Mixxx's **audio buffer** (Preferences → Sound Hardware) as low as plays without dropouts, for example about 5 ms. It adds to the latency on top of the bridge's own buffering.

**Preferences → Vinyl Control:** set the vinyl type for each deck (for example *Serato CV02 Vinyl*, or *Serato CD* for the control CD). Turn on vinyl control on each deck, in ABS mode for needle dropping. Deck 3 needs a skin that shows four decks.

## Core Audio driver (experimental)

`SL3Device.driver` is a Core Audio plug-in that makes the SL3 itself a 6-in/6-out audio device called **Rane SL3**, with no bridge, BlackHole or resampling: it runs on the SL3's own clock. Latency is about 18 ms in and 22 ms out plus the app's buffer. Use either the driver or the bridge, not both.

Build and install (quit audio apps first):

```bash
make device-plugin
sudo cp -R build/SL3Device.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod
```

Remove:

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/SL3Device.driver && sudo killall coreaudiod
```

In Mixxx, select **Rane SL3** for every input and output at 44,100 Hz:

| Output | Channels | | Input | Channels |
|--------|----------|-|-------|----------|
| Deck 1 | 1–2 | | Vinyl Control 1 | 1–2 |
| Deck 2 | 3–4 | | Vinyl Control 2 | 3–4 |
| Deck 3 | 5–6 | | Vinyl Control 3 | 5–6 |

Don't put another card (headphones, a control CD player) in the same Mixxx setup without drift correction: two clocks cause distortion and pitch jumps.

The decks switch to USB audio when an app starts using the device and back to analog thru when the last one stops. If the SL3 is unplugged, it disappears from Core Audio and running apps lose it; it reappears when plugged back in, and apps need to select it or start audio again.

Limitations: 44,100 Hz only; no volume controls. The driver logs to the unified log: `log stream --predicate 'subsystem == "sl3.device"'`. `build/sl3plugtest` loads the driver outside Core Audio to check it (stop any app using the SL3 first).

## Failure behaviour

| Event | What you hear |
|-------|---------------|
| Bridge stopped (Ctrl-C, terminal closed, `kill`) | Analog thru |
| SL3 unplugged, or the Mac loses power | Analog thru (the box falls back by itself) |
| SL3 plugged back in while the bridge runs | USB audio resumes automatically |
| Bridge crashes or is force-killed (`kill -9`) | Silence until the bridge is restarted |

## Tools

Diagnostic tools used to work out the protocol. None of them is needed to play.

| Tool | Purpose |
|------|---------|
| `sl3probe` | Print the device descriptors and record the SL3's inputs to a WAV file. Never writes to the control channel |
| `sl3play` | Play a quiet test tone on output channels 1–2 |
| `sl3ctl` | Read and write the box's control bytes, and send the heartbeat by hand |
| `sl3rec` | Record from a Core Audio device for a few seconds and report levels, channel correlation and callback timing |
| `sl3tone` | Play a quiet sine on all outputs of a Core Audio device |
| `sl3loop` | Measure round-trip latency through a loopback cable |
| `sl3plugtest` | Load `SL3Device.driver` outside Core Audio, check its properties and cycle IO; `hotplug SECONDS` mode for unplug tests |
| `sl3usbtiming` | Measure capture completion timing with IOUSBHost or libusb (`sl3usbtiming MODE [seconds] [transfers]`, MODE is `iousbhost` or `libusb`); read-only |

Stop `sl3bridge` before using `sl3ctl`, because only one process can claim the control interface at a time. **The SL3 keeps its control bytes across power cycles**, so only use `sl3ctl set-control` when you know what a byte does.

## Project layout

```
src/sl3bridge.c       the bridge
plugin/               Core Audio driver (SL3Device) and probe plug-in
tools/                diagnostic tools
docs/PROTOCOL.md      SL3 USB protocol notes
docs/usb-descriptors.txt
```

## Contributing

Issues and pull requests are welcome. These would help most:

- Testing the Core Audio driver, and 48 kHz support for it.
- Lower latency.
- Decoding the remaining control bytes and notifications (see the open questions in [docs/PROTOCOL.md](docs/PROTOCOL.md)).
- Testing with other SL3 units, firmware versions, Intel Macs and DJ software.

Please keep each pull request focused on one change, and describe how you tested it on real hardware.

## License

[GPL-3.0-or-later](LICENSE).

## Disclaimer

This is an independent project. It is not affiliated with or endorsed by Rane or Serato. "Rane", "SL3", "Serato" and "Scratch Live" are trademarks of their respective owners. The project contains no code or files from Rane or Serato.

[libusb]: https://libusb.info
[Mixxx]: https://mixxx.org
[Homebrew]: https://brew.sh
[BlackHole]: https://github.com/ExistentialAudio/BlackHole
