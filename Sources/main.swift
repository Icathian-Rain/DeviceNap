import AppKit
import CoreBluetooth
import Darwin
import IOBluetooth
import IOKit.pwr_mgt
import OSLog
import ServiceManagement

func localized(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return String(format: format, locale: .current, arguments: arguments)
}

struct Device: Codable {
    let address: String
    let name: String
    let connected: Bool

    var label: String { "\(name) · \(address.suffix(8).uppercased())" }
}

// Run Bluetooth operations in a short-lived process so a stalled system call
// cannot freeze the menu or hold the sleep acknowledgement indefinitely.
func bluetoothHelper(_ arguments: [String]) -> Int32 {
    let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    if arguments == ["list"] {
        let entries = devices.compactMap { device -> Device? in
            guard let address = device.addressString else { return nil }
            return Device(address: address, name: device.name ?? localized("蓝牙设备"), connected: device.isConnected())
        }
        guard let json = try? JSONEncoder().encode(entries) else { return 1 }
        FileHandle.standardOutput.write(json)
        return 0
    }

    guard arguments.count == 2,
          let device = devices.first(where: { $0.addressString == arguments[1] }) else { return 1 }
    switch arguments[0] {
    case "disconnect":
        return !device.isConnected() || device.closeConnection() == kIOReturnSuccess ? 0 : 1
    case "connect":
        return device.isConnected() || device.openConnection() == kIOReturnSuccess ? 0 : 1
    default:
        return 1
    }
}

enum Bluetooth {
    static func run(_ arguments: [String], timeout: Double) -> Data? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        let directory = FileManager.default.temporaryDirectory
        let path = directory.appendingPathComponent("DeviceNap-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: path.path, contents: nil),
              let output = try? FileHandle(forUpdating: path) else { return nil }
        defer { try? output.close() }
        try? FileManager.default.removeItem(at: path)
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = ["--bluetooth"] + arguments
        process.standardOutput = output
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        do {
            try output.seek(toOffset: 0)
            return try output.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    static func devices(timeout: Double = 4) -> [Device]? {
        guard let data = run(["list"], timeout: timeout) else { return nil }
        return try? JSONDecoder().decode([Device].self, from: data)
    }
}

final class DeviceNap: NSObject, NSApplicationDelegate, NSMenuDelegate, CBCentralManagerDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private lazy var logWindow = LogWindow()
    private let work = DispatchQueue(label: "local.devicenap.bluetooth", qos: .userInitiated)
    private let logger = Logger(subsystem: "local.devicenap", category: "connection")
    private let preferences = UserDefaults.standard
    private var devices: [Device] = []
    private var listing = false
    private var listFailed = false
    private var permissionManager: CBCentralManager?
    private var authorization: CBManagerAuthorization?
    private var hasBluetoothAccess: Bool { CBCentralManager.authorization == .allowedAlways }
    private var sleeping = false
    private var generation = 0
    private var powerPort: io_connect_t = 0
    private var notifications: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var source: CFRunLoopSource?
    private var status = localized("请选择一台已配对设备")

    private var selection: String? { preferences.string(forKey: "deviceAddress") }
    private var selectionName: String { preferences.string(forKey: "deviceName") ?? localized("所选设备") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "DeviceNap")
        item.button?.toolTip = "DeviceNap"
        menu.delegate = self
        rebuildMenu()
        item.menu = menu
        registerForPower()
        requestBluetoothAccess()
    }

    private func requestBluetoothAccess() {
        // The menu bar app owns the authorization request. Its short-lived
        // Bluetooth helper should only run after the user grants access.
        if CBCentralManager.authorization == .notDetermined, permissionManager == nil {
            permissionManager = CBCentralManager(delegate: self, queue: nil,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        updateAuthorization()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateAuthorization()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateAuthorization()
    }

    private func updateAuthorization() {
        let current = CBCentralManager.authorization
        guard authorization != current else { return }
        authorization = current
        logger.info("Bluetooth authorization: \(current.rawValue)")
        if current == .allowedAlways {
            if let selection { reconnect(selection, attempt: 1, generation: generation) }
            refreshDevices()
        } else {
            generation += 1
            devices = []
        }
        rebuildMenu()
    }

    func registerForPower() {
        powerPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notifications, { context, _, message, argument in
            guard let context else { return }
            let app = Unmanaged<DeviceNap>.fromOpaque(context).takeUnretainedValue()
            app.powerEvent(message, token: Int(bitPattern: argument))
        }, &notifier)
        if powerPort != 0, let notifications,
           let runLoopSource = IONotificationPortGetRunLoopSource(notifications) {
            source = runLoopSource.takeUnretainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func powerEvent(_ message: UInt32, token: Int) {
        switch message {
        case 0xe0000270: // kIOMessageCanSystemSleep
            IOAllowPowerChange(powerPort, token)
        case 0xe0000280: // kIOMessageSystemWillSleep
            sleeping = true
            generation += 1
            let port = powerPort
            let sleepGeneration = generation
            guard hasBluetoothAccess, let address = selection else {
                IOAllowPowerChange(port, token)
                return
            }
            let name = selectionName
            // Acknowledge even if preceding Bluetooth work is still in flight.
            var acknowledged = false
            func acknowledge() {
                guard !acknowledged else { return }
                acknowledged = true
                IOAllowPowerChange(port, token)
            }
            let deadline = DispatchTime.now() + 5
            DispatchQueue.main.asyncAfter(deadline: deadline) { acknowledge() }
            work.async {
                let now = DispatchTime.now().uptimeNanoseconds
                let end = deadline.uptimeNanoseconds
                let remaining = now < end ? Double(end - now) / 1_000_000_000 : 0
                let requested = remaining > 0.2 &&
                    Bluetooth.run(["disconnect", address], timeout: min(remaining, 3)) != nil
                DispatchQueue.main.async {
                    acknowledge()
                    guard self.sleeping, self.generation == sleepGeneration else { return }
                    self.publish(requested ? localized("已请求断开 %@", name) : localized("睡眠前断开 %@ 失败", name))
                }
            }
        case 0xe0000300: // kIOMessageSystemHasPoweredOn
            sleeping = false
            generation += 1
            if let address = selection { reconnect(address, attempt: 1, generation: generation) }
        default:
            break
        }
    }

    private func reconnect(_ address: String, attempt: Int, generation: Int) {
        guard self.generation == generation, !sleeping, hasBluetoothAccess else { return }
        let name = selectionName
        publish(localized("正在连接 %@", name))
        work.async {
            _ = Bluetooth.run(["connect", address], timeout: 8)
            let confirmed = Bluetooth.devices()?.contains { $0.address == address && $0.connected } == true
            DispatchQueue.main.async {
                guard self.generation == generation, !self.sleeping else { return }
                if confirmed {
                    self.publish(localized("%@ 已连接", name))
                    self.refreshDevices()
                } else if attempt < 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.reconnect(address, attempt: attempt + 1, generation: generation)
                    }
                } else {
                    self.publish(localized("未能连接 %@ · 可手动重试", name))
                }
            }
        }
    }

    private func publish(_ message: String) {
        status = message
        logger.info("\(message, privacy: .public)")
        rebuildMenu()
    }

    private func refreshDevices() {
        guard !listing, !sleeping, hasBluetoothAccess else { return }
        listing = true
        rebuildMenu()
        work.async {
            let result = Bluetooth.devices()
            DispatchQueue.main.async {
                self.listing = false
                guard self.hasBluetoothAccess else { return }
                self.listFailed = result == nil
                if let result {
                    self.devices = result.sorted { left, right in
                        if left.connected != right.connected { return left.connected }
                        return left.label.localizedStandardCompare(right.label) == .orderedAscending
                    }
                }
                self.rebuildMenu()
            }
        }
    }

    private func add(_ title: String, action: Selector? = nil,
                     to destination: NSMenu, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        destination.addItem(entry)
        return entry
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateAuthorization()
        refreshDevices()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        _ = add(source == nil ? localized("无法订阅系统睡眠通知") : status, to: menu)
        menu.addItem(.separator())
        switch CBCentralManager.authorization {
        case .allowedAlways:
            addDeviceControls()
        case .notDetermined:
            _ = add(localized("请求蓝牙权限…"), action: #selector(requestAccess), to: menu)
        case .denied:
            _ = add(localized("蓝牙权限已拒绝"), to: menu)
            _ = add(localized("打开蓝牙隐私设置…"), action: #selector(openBluetoothPrivacy), to: menu)
        case .restricted:
            _ = add(localized("系统限制了蓝牙权限"), to: menu)
        @unknown default:
            _ = add(localized("无法读取蓝牙权限"), to: menu)
        }
        menu.addItem(.separator())
        let service = SMAppService.mainApp
        let login = add(localized("登录时启动"), action: #selector(toggleLogin), to: menu)
        login.state = service.status == .enabled ? .on : .off
        if service.status == .requiresApproval {
            _ = add(localized("前往系统设置批准登录项"), action: #selector(openLoginSettings), to: menu)
        }
        _ = add(localized("查看日志…"), action: #selector(showLog), to: menu)
        _ = add(localized("退出 DeviceNap"), action: #selector(quit), to: menu, key: "q")
    }

    private func addDeviceControls() {
        let picker = add(localized("睡眠时断开的设备"), to: menu)
        let choices = NSMenu()
        picker.submenu = choices
        let none = add(localized("无"), action: #selector(choose(_:)), to: choices)
        none.state = selection == nil ? .on : .off
        for device in devices {
            let title = device.connected ? localized("%@（已连接）", device.label) : device.label
            let option = add(title, action: #selector(choose(_:)), to: choices)
            option.representedObject = device
            option.state = device.address == selection ? .on : .off
        }
        if listing {
            _ = add(localized("正在读取设备…"), to: choices)
        } else if listFailed {
            _ = add(localized("读取失败 · 请检查系统蓝牙权限"), to: choices)
        } else if devices.isEmpty {
            _ = add(localized("没有已配对设备 · 请在系统设置中配对"), to: choices)
        }
        if selection != nil { _ = add(localized("立即连接 %@", selectionName), action: #selector(connectNow), to: menu) }
        _ = add(localized("刷新设备"), action: #selector(refresh), to: menu)
    }

    @objc private func requestAccess() {
        if CBCentralManager.authorization == .notDetermined {
            permissionManager = nil
            requestBluetoothAccess()
        }
    }

    @objc private func openBluetoothPrivacy() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        let device = sender.representedObject as? Device
        generation += 1
        preferences.set(device?.address, forKey: "deviceAddress")
        preferences.set(device?.name, forKey: "deviceName")
        publish(device.map { localized("正在监控 %@", $0.name) } ?? localized("请选择一台已配对设备"))
    }

    @objc private func connectNow() {
        guard let selection else { return }
        generation += 1
        reconnect(selection, attempt: 1, generation: generation)
    }

    @objc private func refresh() { refreshDevices() }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func showLog() { logWindow.open() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: openLoginSettings()
            default: try service.register()
            }
            rebuildMenu()
        } catch {
            publish(localized("无法更改登录项：%@", error.localizedDescription))
        }
    }
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
