# JoyCon2forMac (App + ESP32-S3 Dongle)

This repo contains two ways to use **Nintendo Switch 2 Joy-Con 2** on macOS:

1. `mac-app/`: a native macOS menu-bar app that connects to Joy-Con 2 over BLE and maps input to mouse/keyboard, with an optional (experimental) virtual gamepad mode.
2. `esp32-s3-dongle/`: an ESP32-S3 firmware project (WIP) that connects to Joy-Con 2 over BLE and exposes a **USB HID gamepad** to the Mac over USB-C for plug-and-play.

If you want something working today, use `mac-app/`. If you want true plug-and-play without macOS Accessibility permissions, help finish `esp32-s3-dongle/`.

## Quick Start (macOS App)

See [mac-app/README.md](mac-app/README.md).

## ESP32-S3 Dongle (WIP)

See [esp32-s3-dongle/README.md](esp32-s3-dongle/README.md).

## Credits

The macOS implementation is based on and heavily inspired by:
- https://github.com/seitanmen/Joycon2forMac

