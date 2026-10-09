# Changelog

## [0.1.0] - 2026-10-09

First release.

- `sl3bridge`: passes all six SL3 inputs and outputs to and from BlackHole 16ch, with clock-drift correction.
- Switches the SL3's decks out of analog thru while running, and back to thru on exit.
- Reconnects automatically if the SL3 is unplugged or loses power.
- Diagnostic tools: `sl3probe`, `sl3play` and `sl3ctl`.
- Protocol notes in `docs/PROTOCOL.md`.
