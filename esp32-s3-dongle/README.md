# JoyCon2forMac ESP32-S3 Dongle (WIP)

Goal: make Joy-Con 2 work as a **plug-and-play USB controller** on macOS.

The ESP32-S3 acts as:
- BLE Central: connects to Joy-Con 2 (same BLE UUIDs + init commands used by the macOS app)
- USB HID Device (TinyUSB): exposes a **gamepad** over USB-C to the Mac

This avoids macOS Accessibility/Input Monitoring permissions entirely.

## Status

This folder is a scaffold for an ESP-IDF firmware project. It is not complete yet.

## Requirements

- ESP32-S3 board with native USB (USB-OTG / device mode)
- ESP-IDF (v5.x recommended)

## Intended Flow

1. Plug ESP32-S3 into your Mac via USB-C.
2. ESP32-S3 appears as a "JoyCon2forMac Gamepad" in macOS.
3. Put Joy-Con 2 in pairing mode (sync button until LEDs flash).
4. ESP connects, subscribes to notifications, sends init commands, and translates packets into USB HID reports.

## BLE Details (from macOS implementation)

- Manufacturer ID filter: `0x0553`
- Write characteristic UUID: `649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005`
- Notify characteristic UUID: `AB7DE9BE-89FE-49AD-828F-118F09DF7FD2`
- Init commands (write-without-response, 500ms apart):
  - `0c 91 01 02 00 04 00 00 ff 00 00 00`
  - `0c 91 01 04 00 04 00 00 ff 00 00 00`

