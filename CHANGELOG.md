# Changelog

## [Unreleased]

- `sl3rec` reports the dominant frequency of each channel (for example a 1 kHz timecode carrier), to check that input runs at the right rate.
- README: recommend 44.1 kHz in Mixxx (its vinyl control can start at 44.1 kHz while the device runs at 48 kHz); troubleshooting for a stuck AirPlay helper.
- README: install from the release download by moving the driver into place; remove the old driver first when upgrading.

## [1.0.1] - 2026-10-09

- Project renamed to OpenSL3 (previously sl3-bridge).
- Builds target macOS 12 and later. The 1.0.0 release download was built for macOS 27 only.

## [1.0.0] - 2026-10-09

The Core Audio driver (`SL3Device.driver`) is now the way to use the SL3; the bridge is kept and documented in `docs/BRIDGE.md`.

- README rewritten around the driver; bridge documentation moved to `docs/BRIDGE.md`.
- `sl3bridge` sets the box to 44.1 kHz at start, so a box left at 48 kHz (by the Core Audio driver or Rane's driver) no longer runs off speed.
- `SL3Device.driver`: 44.1 and 48 kHz, chosen in Audio MIDI Setup or the app and remembered. The driver now sets the box's rate at every start, so a box left at another rate (for example by Rane's driver) no longer runs off speed.
- `sl3ctl set-rate 44100|48000` sets the box's sample rate (vendor command `0x31`). The rate survives power cycles.
- `SL3Device.driver`: hot-plug. Apps using the SL3 keep the device through an unplug (the decks fall back to thru) and resume when it is plugged in again; when nothing uses it, an unplugged SL3 disappears from Core Audio until it is back.
- `SL3Device.driver`: fixed coreaudiod spinning at high CPU (and Core Audio apps hanging) after a few device start/stop cycles.
- New `sl3plugtest` tool (built by `make device-plugin`): loads the driver outside Core Audio, checks every property and cycles IO start/stop.
- `make device-plugin`: Core Audio driver (`SL3Device.driver`) that makes the SL3 a 6-in/6-out device running on its own clock, with no bridge, BlackHole or resampling. About 18 ms in and 22 ms out plus the app buffer; restarts the USB streams if they stop.
- New test tools: `sl3rec` (input levels, channel correlation, callback timing), `sl3tone` (sine on all outputs), `sl3loop` (round-trip latency through a loopback cable).
- `make probe-plugin`: experimental Core Audio plug-in (`SL3Probe.driver`) that only checks whether a HAL plug-in can open the SL3 through IOUSBHost. It publishes no device.
- Lower default latency: about 24 ms in and 29 ms out, down from 33 and 45.
- New options to tune the ring buffers and USB transfer sizes (`--out-target`, `--cap-pkts`, `--cap-xfers`, `--play-pkts`, `--play-xfers`).
- Status output shows the estimated latency and USB packet rates.
- New `sl3usbtiming` tool compares isochronous capture timing between IOUSBHost and libusb.
- Experimental `sl3bridge-iousbhost` build: same bridge on Apple's IOUSBHost framework instead of libusb (audio streams and control channel), with no libusb dependency. It measures the SL3 and loopback clocks from hardware timestamps and sets the resampling ratios from them, which keeps the output ratio steadier.

## [0.1.0] - 2026-10-09

First release.

- `sl3bridge`: passes all six SL3 inputs and outputs to and from BlackHole 16ch, with clock-drift correction.
- Switches the SL3's decks out of analog thru while running, and back to thru on exit.
- Reconnects automatically if the SL3 is unplugged or loses power.
- Diagnostic tools: `sl3probe`, `sl3play` and `sl3ctl`.
- Protocol notes in `docs/PROTOCOL.md`.
