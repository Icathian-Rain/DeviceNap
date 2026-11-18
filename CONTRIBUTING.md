# Contributing to DeviceNap

Bug reports and pull requests are welcome. For a bug report, include the macOS version, Mac model, affected Bluetooth device model, and the steps to reproduce the issue. Redact Bluetooth addresses and personal device names.

## Project layout

- `Sources/main.swift` starts the app or runs the Bluetooth diagnostic command.
- `Sources/DeviceNap.swift` owns the menu bar, authorization, and sleep/wake state.
- `Sources/Bluetooth.swift` lists devices and reconnects through a bounded helper process. `Sources/BluetoothPower.swift` implements the optional controller power changes.
- `Sources/LogWindow.swift` displays app events from the macOS unified log. `Resources` contains English and Simplified Chinese strings.

## Verify a change

```sh
bash -n build.sh
plutil -lint Info.plist Resources/*/*.strings
./build.sh
codesign --verify --strict build/DeviceNap.app
```

The build workflow runs these checks on macOS. For changes to connection handling, also test on a Mac with a paired Bluetooth device:

1. Select a connected device, sleep the Mac, and wake it with the power button or built-in keyboard.
2. Check that the app reports a successful reconnect and that other Bluetooth devices are still available.
3. If the change affects login behavior, enable **Launch at login**, sign out, and sign back in to verify that the saved device is restored.

When submitting a pull request, describe what changed and which checks you ran. Update both README files if the user-facing behavior changes.
