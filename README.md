# DeviceNap

DeviceNap is a macOS menu bar app that disconnects one selected Bluetooth device before sleep and tries to reconnect it when you wake or sign in to your Mac.

[简体中文](README.zh-CN.md) · [Contributing](CONTRIBUTING.md) · [MIT License](LICENSE)

## What it does

- Pick one paired Bluetooth device from the menu bar. Other paired devices stay available.
- Reconnect the selected device after wake, with retries and a manual reconnect command.
- Optionally launch at login and reconnect the last selected device.
- Store the selection locally. DeviceNap uses macOS frameworks and has no runtime dependencies.

DeviceNap was built to reduce accidental wake-ups from a Bluetooth mouse. The Bluetooth controller stays on, and macOS or the device may reconnect during sleep. Whether this prevents a particular device from waking your Mac depends on the hardware and macOS.

## Build and run

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). Run these commands from the repository root.

```sh
./build.sh
open build/DeviceNap.app
```

The build is ad hoc signed for local use. For a permanent installation, move the app to Applications before enabling launch at login.

## Set up

1. Click the moon icon in the menu bar.
2. Open **Device to disconnect on sleep** and select an already paired device. Address suffixes distinguish devices with the same name. Connected devices appear first.
3. Enable **Launch at login** if you want DeviceNap to start automatically after you sign in.
4. If macOS prompts for Bluetooth access, allow DeviceNap in **System Settings → Privacy & Security → Bluetooth**.

If you use another sleep utility that manages Bluetooth, quit it before testing DeviceNap.

## Troubleshooting

If the device does not reconnect, wake it and choose **Connect now**. Choose **View Log…** from the menu bar to view, refresh, or copy the last 30 minutes of events. The log includes the sleep and wake notifications and the time from the wake notification to a confirmed Bluetooth connection. For diagnostics from Terminal, run:

```sh
build/DeviceNap.app/Contents/MacOS/DeviceNap --check
log show --last 30m --predicate 'subsystem == "local.devicenap"' --info
```

The device list contains Bluetooth addresses. Redact them and any personal device names before posting logs publicly.

To uninstall, disable **Launch at login**, quit DeviceNap, then move the app to the Trash.
