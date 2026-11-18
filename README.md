# DeviceNap

DeviceNap is a macOS menu bar app that can turn Bluetooth off before sleep, restore it on wake, and reconnect a selected device on wake or login.

[简体中文](README.zh-CN.md) · [Contributing](CONTRIBUTING.md) · [MIT License](LICENSE)

## What it does

- Optionally turn off Bluetooth before sleep and restore it on wake.
- Reconnect the selected device after wake, with retries and a manual reconnect command.
- Optionally launch at login and reconnect the last selected device.
- Store the selection locally. DeviceNap uses macOS frameworks and has no runtime dependencies.

## Build and run

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). Run these commands from the repository root.

```sh
./build.sh
open build/DeviceNap.app
```

The build is ad hoc signed for local use. For a permanent installation, move the app to Applications before enabling launch at login.

Run `./package.sh` to build a universal DMG for Apple silicon and Intel Macs. Open the DMG and drag DeviceNap to Applications. This build uses an ad hoc signature and has not been notarized by Apple.

## Set up

1. Click the moon icon in the menu bar.
2. Optionally open **Device to reconnect on wake or login** and select a paired device. Address suffixes distinguish devices with the same name. Connected devices appear first.
3. Enable **Launch at login** if you want DeviceNap to start automatically after you sign in.
4. If macOS prompts for Bluetooth access, allow DeviceNap in **System Settings → Privacy & Security → Bluetooth**.

If you use another sleep utility that manages Bluetooth, quit it before testing DeviceNap.

To prevent Bluetooth devices from waking your Mac, you can enable **Turn off Bluetooth on sleep**. This opt-in mode disconnects all Bluetooth devices temporarily and restores the controller after wake if it was on before sleep. Wake your Mac with its built-in keyboard, power button, or a wired device. This mode uses an undocumented macOS interface and can be affected by system updates.

## Single-device sleep disconnect (temporarily unavailable)

In our test, the previous IOBluetooth disconnect call returned success for the Logitech MX Master 3S, but repeated checks showed that the mouse remained connected. System Settings could disconnect that same BLE HID link while leaving Bluetooth on. A sleep test with the previous implementation also recorded a Bluetooth HID wake-up. The menu item is disabled while we explore a macOS-compatible way to disconnect the system-owned BLE HID link and confirm that it stays disconnected through sleep.

## Troubleshooting

If the device does not reconnect, wake it and choose **Connect now**. Choose **View Log…** from the menu bar to view, refresh, or copy the last 30 minutes of events. The log includes the sleep and wake notifications and the time from the first screen or system wake notification to a confirmed Bluetooth connection. For diagnostics from Terminal, run:

```sh
build/DeviceNap.app/Contents/MacOS/DeviceNap --check
log show --last 30m --predicate 'subsystem == "local.devicenap"' --info
```

The device list contains Bluetooth addresses. Redact them and any personal device names before posting logs publicly.

To uninstall, disable **Launch at login**, quit DeviceNap, then move the app to the Trash.
