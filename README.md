# SL3 Bridge

A Core Audio driver for the **Rane SL3** DVS interface on Apple Silicon Macs, with no kernel extension and no Serato software.

Rane's SL3 driver is an Intel-only kext, and the last Scratch Live releases are Intel-only too, so the SL3 doesn't work on Apple Silicon Macs. This project's driver makes the SL3 show up as a normal audio device again, so open-source DJ software such as [Mixxx] can use it for timecode control.

**Status:** working. All three decks play in Mixxx with Serato control vinyl and CDs, at 44.1 or 48 kHz.

## What the driver is

`SL3Device.driver` is a Core Audio plug-in (an AudioServerPlugIn, the same kind of driver as BlackHole or Loopback). macOS loads it into its own audio service, where it talks to the SL3 over USB through Apple's IOUSBHost framework, all in user space. It publishes one device, **Rane SL3**:

- 6 inputs and 6 outputs, three stereo pairs, one per deck;
- 44,100 or 48,000 Hz, running on the SL3's own clock (no resampling);
- about 18 ms of input and 22 ms of output latency, plus your app's buffer;
- the decks switch from analog thru to USB audio while an app uses the device, and back to thru when the last app stops;
- if the SL3 is unplugged while an app plays, the decks fall back to thru and audio resumes by itself when it is plugged back in.

```
 turntables / CDJs                              mixer
        │                                         ▲
        ▼                                         │
   ┌─────────┐   USB    ┌──────────────────┐   Core Audio
   │   SL3   │ ◄──────► │ SL3Device.driver │ ◄──────────► Mixxx
   └─────────┘          └──────────────────┘
```

How the SL3's USB protocol works is documented in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Requirements

- An Apple Silicon Mac. Intel Macs should also work, but haven't been tested.
- To build: the Xcode command line tools (`xcode-select --install`).
- [Mixxx] or other DJ software that supports timecode control.

## Install

Quit your audio apps, then build and install:

```sh
make device-plugin
sudo cp -R build/SL3Device.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod
```

`killall coreaudiod` restarts the macOS audio service so it loads the driver; sound on the Mac stops for a moment. Plug in the SL3 and **Rane SL3** appears in Audio MIDI Setup and in your apps.

If you install from a release download instead, unzip it first and remove the download quarantine before copying (`xattr -dr com.apple.quarantine SL3Device.driver`).

To uninstall:

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/SL3Device.driver && sudo killall coreaudiod
```

## Mixxx setup

**Preferences → Sound Hardware:** sound API CoreAudio, sample rate 44,100 or 48,000 Hz, and **Rane SL3** for every input and output:

| Output | Channels | | Input | Channels |
|--------|----------|-|-------|----------|
| Deck 1 | 1–2 | | Vinyl Control 1 | 1–2 |
| Deck 2 | 3–4 | | Vinyl Control 2 | 3–4 |
| Deck 3 | 5–6 | | Vinyl Control 3 | 5–6 |

Set the **audio buffer** as low as plays without dropouts, for example about 5 ms.

Don't add another sound card (headphones, a control CD player) to the same Mixxx setup without drift correction: two clocks cause distortion and pitch jumps.

**Preferences → Vinyl Control:** set the vinyl type for each deck (for example *Serato CV02 Vinyl*, or *Serato CD* for the control CD). Turn on vinyl control on each deck, in ABS mode for needle dropping. Deck 3 needs a skin that shows four decks.

## Sample rate

Choose 44,100 or 48,000 Hz in Audio MIDI Setup or in your app. The driver remembers the choice and sets it on the box every time audio starts. (The SL3 keeps its rate across power cycles, so a box last used at another rate is corrected automatically.)

## Troubleshooting

- **Rane SL3 doesn't appear:** check the SL3 is plugged in, then restart the audio service with `sudo killall coreaudiod`. An unplugged SL3 is hidden until it is back.
- **An app lost the device after an unplug:** apps that were not playing when it was unplugged, such as Mixxx when idle, only see it again after a restart of the app.
- **Silence on the decks:** only one program can own the SL3; stop `sl3bridge` or any of the tools below.
- **Logs:** `log stream --predicate 'subsystem == "sl3.device"'` shows the driver's messages, including clock and USB statistics every 2 seconds while it runs.
- **Anything going wrong with the audio service:** uninstall with the command above.

## Tools

Diagnostic tools, built with `make` (needs [Homebrew] with `brew install libusb pkg-config`). None of them is needed to play.

| Tool | Purpose |
|------|---------|
| `sl3plugtest` | Load `SL3Device.driver` outside Core Audio, check its properties and cycle IO; `hotplug SECONDS` and `rate HZ SECONDS` modes. Built by `make device-plugin` |
| `sl3rec` | Record from a Core Audio device for a few seconds and report levels, channel correlation and callback timing |
| `sl3tone` | Play a quiet sine on all outputs of a Core Audio device |
| `sl3loop` | Measure round-trip latency through a loopback cable |
| `sl3ctl` | Read and write the box's control bytes, set the sample rate (`set-rate`), and send the heartbeat by hand |
| `sl3probe` | Print the device descriptors and record the SL3's inputs to a WAV file. Never writes to the control channel |
| `sl3play` | Play a quiet test tone on output channels 1–2 |
| `sl3usbtiming` | Measure capture completion timing with IOUSBHost or libusb; read-only |

Tools that talk to the SL3 directly need it to themselves: quit apps using Rane SL3 first. **The SL3 keeps its control bytes across power cycles**, so only use `sl3ctl set-control` when you know what a byte does.

## The bridge

Before the driver, this project used `sl3bridge`, a command-line program that passes the SL3's audio through a BlackHole loopback device. The driver replaces it; it is documented in [docs/BRIDGE.md](docs/BRIDGE.md).

## Project layout

```
plugin/SL3Device.m    the Core Audio driver
plugin/SL3Probe.m     minimal plug-in that only checks USB access
src/                  the bridge (sl3bridge)
tools/                diagnostic tools
docs/PROTOCOL.md      SL3 USB protocol notes
docs/BRIDGE.md        the bridge
docs/usb-descriptors.txt
```

## Contributing

Issues and pull requests are welcome. These would help most:

- Testing with other SL3 units, firmware versions, Intel Macs and DJ software.
- Lower latency.
- Decoding the remaining control bytes and notifications (see the open questions in [docs/PROTOCOL.md](docs/PROTOCOL.md)).

Please keep each pull request focused on one change, and describe how you tested it on real hardware.

## License

[GPL-3.0-or-later](LICENSE).

## Disclaimer

This is an independent project. It is not affiliated with or endorsed by Rane or Serato. "Rane", "SL3", "Serato" and "Scratch Live" are trademarks of their respective owners. The project contains no code or files from Rane or Serato.

[Mixxx]: https://mixxx.org
[Homebrew]: https://brew.sh
