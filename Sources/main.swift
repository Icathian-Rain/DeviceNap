import AppKit

func localized(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return String(format: format, locale: .current, arguments: arguments)
}

if CommandLine.arguments.dropFirst().first == "--bluetooth" {
    exit(bluetoothHelper(Array(CommandLine.arguments.dropFirst(2))))
}

if CommandLine.arguments.dropFirst().first == "--check" {
    guard let devices = Bluetooth.devices() else {
        fputs(localized("无法读取已配对的蓝牙设备。") + "\n", stderr)
        exit(1)
    }
    for device in devices {
        print("\(device.name)  \(device.address)  \(device.connected ? localized("已连接") : localized("未连接"))")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = DeviceNap()
app.delegate = delegate
app.run()
