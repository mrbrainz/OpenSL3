# Rane SL3 USB protocol notes

What is known about how the Rane SL3 (USB `1cc5:0001`) talks to a host. It was worked out by probing the hardware with libusb and by reading Rane's macOS driver (`Sl3Driver.kext`) and support library (`Sl3Api.framework`). Anything marked *unknown* has not been confirmed.

## Device

- Manufacturer "Rane Corporation", product "SL 3", serial string "SL3.01.00".
- High speed (480 Mb/s), bus powered, 400 mA.
- Device class 255/255/255 (vendor-specific), one configuration, four interfaces.
- macOS leaves it unconfigured, so the host must select configuration 1 itself.

Full descriptor dump: [usb-descriptors.txt](usb-descriptors.txt).

## Interfaces

| IF | Role | Endpoints |
|----|------|-----------|
| 0 | Audio control (class 255, sub 1, proto 0x20) | none |
| 1 | Playback streaming. Alt 0 empty, alt 1 active | `0x06` OUT, isochronous, asynchronous, 126 B max, interval 1 |
| 2 | Capture streaming. Alt 0 empty, alt 1 active | `0x82` IN, isochronous, implicit feedback, 126 B max |
| 3 | Vendor control channel (HID-style) | `0x81` IN and `0x01` OUT, interrupt, 64 B, interval 1 |

The class-specific descriptors are shaped like USB Audio Class 2.0, but the class bytes are 255, so macOS's own audio driver ignores the device. Quirk: the capture streaming interface links to terminal 3 (the line input) rather than terminal 4 (the USB streaming output).

## Audio streams

- PCM, 6 channels (three stereo pairs), 24-bit samples in 3-byte little-endian subslots, so 18 bytes per frame. Channels run 1–6 in order: decks 1, 2 and 3.
- The box runs at **44.1 kHz** by default. Packets carry 5 or 6 frames per 125 µs microframe (90 or 108 bytes).
- **Capture** needs no handshake: select IF 2 alt 1 and read EP `0x82`. The first two or three packets carry stale data and should be discarded.
- **Playback**: select IF 1 alt 1 and write to EP `0x06`. There is no separate feedback endpoint. Size each playback packet to match the frame count of the capture packets (implicit feedback), with both streams running in the same event loop.
- The standard UAC2 clock requests (GET_RANGE, GET_CUR and SET_CUR on clock source 5) all stall. The rate is set with vendor command `0x31` instead (see below).

## Control channel (interface 3)

Every command is a 64-byte report on interrupt OUT `0x01`, with no report ID:

| Bytes | Meaning |
|-------|---------|
| 0 | command |
| 1–4 | sequence number, little-endian |
| 5… | payload, up to 59 bytes; the rest is zero |

Replies arrive on interrupt IN `0x81` with the same command byte and sequence number.

### Commands

| Cmd | Name | Payload | Reply |
|-----|------|---------|-------|
| `0x31` | Set sample rate | rate as 16-bit big-endian: `AC 44` = 44,100, `BB 80` = 48,000 | |
| `0x32` | Get audio controls | none | 22 control bytes from reply offset 5 |
| `0x33` | Set audio controls | `[start] [count] [values…]`, start + count ≤ 22 | |
| `0x37` | Heartbeat / challenge | 8 bytes | 8 bytes |
| `0x03` | *unknown* (device info) | none | 64 bytes; a value of `0xC0` marks a "C0" device |
| `0x17` | *unknown* (probably firmware version) | none | 5 bytes |

The box also sends `0x34` and `0x38` reports without being asked. They are probably the phono/line switch, overload and USB port status notifications; their format is unknown.

Rane's driver only accepts 44,100 and 48,000 Hz, and set 48,000 by default. Sending `0x31` with `BB 80` switches the box to 48 kHz at once: capture goes from 793,900 to 864,100 bytes/s (44,105 to 48,006 frames/s at 18 bytes per frame), packets stay at 8000/s. `AC 44` switches it back. **The rate survives a power cycle**, like the control bytes, so a host must set it rather than assume 44.1 kHz.

### Audio controls

The 22 control bytes read back from a box at factory settings:

```
00 00 00 | 05 60 00 60 00 01 | 05 60 00 60 00 01 | 05 60 00 60 00 01 | 00
          deck 1 (3–8)        deck 2 (9–14)       deck 3 (15–20)      21
```

- **Index 8, 14 and 20** (the last byte of each deck block) is a per-deck **USB audio switch**: `01` lets the deck play USB audio, `00` keeps it in analog thru. See below.
- **Index 21** reads `00` on a fresh box and becomes `01` after the first host write. Writing `00` back has no effect. Probably a status flag.
- The other bytes in each deck block are *unknown*.
- **The control bytes survive power cycles**, so write them deliberately.

## Thru and USB mode

Whenever no host software is controlling it, the box passes each deck's input straight through to that deck's output (analog thru). A deck plays the host's USB audio only while **both** of these hold:

1. its switch byte (index 8, 14 or 20) is `01`, and
2. the host is sending `0x37` heartbeat reports (8 random bytes, about every 100 ms).

The box answers each `0x37` with 8 bytes derived from the challenge. Serato's software uses that answer to check that the hardware is genuine. The box does not need any particular reply from the host. It only needs the traffic.

How the box behaves when the host stops:

| Event | Result |
|-------|--------|
| Host sets the switch bytes to `00` | Decks return to thru |
| Heartbeat stops, switch bytes left at `01` | The box stays in USB mode, so the decks go **silent** |
| Box loses USB power (cable pulled, laptop off) | Thru: the analog path doesn't need the host |

Rane's own driver did not restore thru when its client exited, so a host crash leaves the decks silent with the original software too. `sl3bridge` sets the switch bytes to `00` when it stops.

## Open questions

- What the other bytes in each deck block control (input gain or trim?).
- The format of the `0x34` and `0x38` notifications, and the meaning of `0x03` and `0x17`.
- Whether 48 kHz audio works end to end (the rate switch itself works).
