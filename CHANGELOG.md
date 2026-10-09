# Changelog

## [Unreleased]

- `SL3Device.driver`: fixed coreaudiod spinning at high CPU (and Core Audio apps hanging) after a few device start/stop cycles.
- New `sl3plugtest` tool (built by `make device-plugin`): loads the driver outside Core Audio, checks every property and cycles IO start/stop.
- `make device-plugin`: experimental Core Audio driver (`SL3Device.driver`) that makes the SL3 a 6-in/6-out device running on its own clock, with no bridge, BlackHole or resampling. About 18 ms in and 22 ms out plus the app buffer; restarts the USB streams if they stop.
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
