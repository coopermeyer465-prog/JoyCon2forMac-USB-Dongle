# JoyCon2forMac ESP32-S3 Dongle (WIP)

Goal: make Joy-Con 2 work as a **plug-and-play USB controller** on macOS, with an experimental Switch-compatible USB mode.

The ESP32-S3 acts as:
- BLE Central: connects to Joy-Con 2 (same BLE UUIDs + init commands used by the macOS app)
- USB HID Device (TinyUSB): exposes a **gamepad + mouse** over USB-C to the Mac, or a Switch-compatible wired controller when booted in Switch mode

This avoids macOS Accessibility/Input Monitoring permissions entirely.

## Status

Computer mode is the stable/default mode. Switch mode is experimental and is selected with a long press on the XIAO BOOT button while the firmware is already running.

## Requirements

- ESP32-S3 board with native USB (USB-OTG / device mode)
- Confirmed target board: **Seeed Studio XIAO ESP32-S3 (Pre-Soldered)** should work (native USB)
- ESP-IDF (v5.x recommended)

## Build + Flash (ESP-IDF)

1. Install ESP-IDF (v5.x). Easiest path is Espressif’s “ESP-IDF Tools Installer” for macOS.
2. From this folder:

```bash
cd esp32-s3-dongle
idf.py set-target esp32s3
idf.py build
```

3. Plug in the XIAO ESP32-S3 over USB-C and flash + monitor:

```bash
idf.py flash monitor
```

If `flash` can’t find the port automatically, specify it:

```bash
idf.py -p /dev/cu.usbmodemXXXX flash monitor
```

## Default Behavior (Current)

- Normal boot exposes a **USB HID gamepad + mouse** to macOS/Windows.
- Pair Joy-Con 2 by holding each Joy-Con sync button until the LEDs chase.
- Right Joy-Con mouse sensor drives USB mouse movement.
- In Joy-Con mouse mode:
  - `R` = left click
  - `ZR` = right click
  - optical mouse movement also feeds the gamepad right stick for games that read camera input

## Switch Mode

Switch mode makes the ESP32-S3 enumerate as a HORI/Pokken-style wired USB controller instead of the normal Mac/PC gamepad+mouse composite device.

1. Boot the dongle normally.
2. Hold the XIAO ESP32-S3 **BOOT** button for about 1.5 seconds.
3. The firmware saves the other USB mode and restarts.
4. To switch back, hold BOOT for about 1.5 seconds again.

In Switch mode there is no USB mouse interface. The right Joy-Con mouse sensor is translated into right-stick movement so games can see camera/look input.

Do not hold BOOT while tapping RESET unless you want firmware flashing mode. On the XIAO ESP32-S3, BOOT-at-reset is the hardware bootloader shortcut.

## Intended Flow

1. Plug ESP32-S3 into your Mac, PC, or Switch via USB-C.
2. Put Joy-Con 2 in pairing mode by holding the sync button until LEDs flash.
3. ESP connects, subscribes to notifications, and translates packets into USB HID reports.

## BLE Details (from macOS implementation)

- Manufacturer ID filter: `0x0553`
- Write characteristic UUID: `649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005`
- Notify characteristic UUID: `AB7DE9BE-89FE-49AD-828F-118F09DF7FD2`
- Init commands (write-without-response, 500ms apart):
  - `0c 91 01 02 00 04 00 00 ff 00 00 00`
  - `0c 91 01 04 00 04 00 00 ff 00 00 00`
