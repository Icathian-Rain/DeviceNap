import AppKit
import CoreBluetooth
import IOKit.pwr_mgt
import ServiceManagement

final class DeviceNap: NSObject, NSApplicationDelegate, NSMenuDelegate, CBCentralManagerDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private lazy var logWindow = LogWindow()
    private let work = DispatchQueue(label: "local.devicenap.bluetooth", qos: .userInitiated)
    private let preferences = UserDefaults.standard
    private let restorePowerKey = "restoreBluetoothPower"
    private var devices: [Device] = []
    private var listing = false
    private var listFailed = false
    private var permissionManager: CBCentralManager?
    private var authorization: CBManagerAuthorization?
    private var hasBluetoothAccess: Bool { CBCentralManager.authorization == .allowedAlways }
    private var sleeping = false
    private var wakeTime: DispatchTime?
    private var waitingForSystemWake = false
    private var generation = 0
    private var powerPort: io_connect_t = 0
    private var notifications: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var source: CFRunLoopSource?
    private var status = localized("请选择一台已配对设备")

    private var selection: String? { preferences.string(forKey: "deviceAddress") }
    private var selectionName: String { preferences.string(forKey: "deviceName") ?? localized("所选设备") }

    // MARK: - App lifecycle and Bluetooth authorization

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "DeviceNap")
        item.button?.toolTip = "DeviceNap"
        menu.delegate = self
        rebuildMenu()
        item.menu = menu
        registerForPower()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification, object: nil
        )
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
        LogKind.connection.write("Bluetooth authorization: \(current.rawValue)")
        if current == .allowedAlways {
            restorePowerAndReconnect(generation: generation)
            refreshDevices()
        } else {
            generation += 1
            devices = []
        }
        rebuildMenu()
    }

    // MARK: - Sleep and wake

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
            wakeTime = nil
            waitingForSystemWake = false
            LogKind.sleep.write(localized("收到系统睡眠通知"), persistent: true)
            generation += 1
            let port = powerPort
            let sleepGeneration = generation
            guard hasBluetoothAccess, preferences.bool(forKey: "powerOffOnSleep") else {
                IOAllowPowerChange(port, token)
                return
            }
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
                let result = self.powerOffForSleep(remaining: remaining)

                DispatchQueue.main.async {
                    acknowledge()
                    guard let result, self.sleeping, self.generation == sleepGeneration else { return }
                    self.publish(result.0, kind: result.1, persistent: true)
                }
            }
        case 0xe0000300: // kIOMessageSystemHasPoweredOn
            LogKind.wake.write(localized("收到系统唤醒通知"), persistent: true)
            if sleeping {
                resumeAfterSleep()
            } else if waitingForSystemWake {
                waitingForSystemWake = false
                if (wakeTime != nil || preferences.bool(forKey: restorePowerKey)), hasBluetoothAccess {
                    // Replace any scheduled screen-wake retry with a fresh round.
                    LogKind.wake.write(localized("系统唤醒后补试连接"), persistent: true)
                    generation += 1
                    restorePowerAndReconnect(generation: generation)
                }
            }
        default:
            break
        }
    }

    @objc private func screensDidWake(_ notification: Notification) {
        DispatchQueue.main.async {
            guard self.sleeping else { return }
            self.waitingForSystemWake = true
            LogKind.wake.write(localized("收到屏幕唤醒通知"), persistent: true)
            self.resumeAfterSleep()
        }
    }

    private func resumeAfterSleep() {
        guard sleeping else { return }
        wakeTime = .now()
        sleeping = false
        generation += 1
        restorePowerAndReconnect(generation: generation)
    }

    private func powerOffForSleep(remaining: Double) -> (String, LogKind)? {
        let failed = (localized("睡眠前未能确认整机蓝牙关闭"), LogKind.problem)
        guard remaining > 1 else { return failed }
        let state = Bluetooth.run(["power"], timeout: 0.8)
        if state == Data("0\n".utf8) { return nil }
        guard state == Data("1\n".utf8) else { return failed }

        // Store the previous state before changing the controller so a relaunched
        // app can recover even if the helper or app stops during sleep.
        preferences.set(true, forKey: restorePowerKey)
        guard Bluetooth.run(["power", "0"], timeout: remaining - 0.9) != nil else { return failed }
        return (localized("睡眠前已关闭整机蓝牙"), .sleep)
    }

    private func restorePowerAndReconnect(generation: Int, attempt: Int = 1) {
        guard self.generation == generation, !sleeping, hasBluetoothAccess else { return }
        work.async {
            let needsRestore = self.preferences.bool(forKey: self.restorePowerKey)
            let restored = !needsRestore || Bluetooth.run(["power", "1"], timeout: 4) != nil
            if needsRestore, restored {
                self.preferences.removeObject(forKey: self.restorePowerKey)
                LogKind.wake.write(localized("已恢复整机蓝牙"), persistent: true)
            }
            DispatchQueue.main.async {
                guard self.generation == generation, !self.sleeping else { return }
                if restored {
                    if let selection = self.selection {
                        self.reconnect(selection, attempt: 1, generation: generation)
                    } else if needsRestore {
                        self.publish(localized("已恢复整机蓝牙"), kind: .wake)
                        self.refreshDevices()
                    }
                } else if attempt < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.restorePowerAndReconnect(generation: generation, attempt: attempt + 1)
                    }
                } else {
                    self.publish(localized("未能恢复整机蓝牙 · 可在菜单重试"), kind: .problem, persistent: true)
                }
            }
        }
    }

    // MARK: - Reconnection and device list

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
                    if let wakeTime = self.wakeTime {
                        let seconds = Double(DispatchTime.now().uptimeNanoseconds - wakeTime.uptimeNanoseconds) / 1_000_000_000
                        let message = localized("%@ 已连接 · 距首次收到唤醒通知 %.2f 秒", name, seconds)
                        self.publish(message, kind: .connected, persistent: true)
                        self.wakeTime = nil
                    } else {
                        self.publish(localized("%@ 已连接", name), kind: .connected)
                    }
                    self.refreshDevices()
                } else if attempt < 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.reconnect(address, attempt: attempt + 1, generation: generation)
                    }
                } else if self.waitingForSystemWake, self.wakeTime != nil {
                    self.publish(localized("%@ 尚未连接 · 等待系统唤醒通知", name))
                } else {
                    self.publish(localized("未能连接 %@ · 可手动重试", name), kind: .problem)
                }
            }
        }
    }

    private func publish(_ message: String, kind: LogKind = .connection, persistent: Bool = false) {
        status = message
        kind.write(message, persistent: persistent)
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

    // MARK: - Menu bar

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
            addSleepControls()
            menu.addItem(.separator())
            addReconnectControls()
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

    private func addReconnectControls() {
        let picker = add(localized("唤醒或登录后重连的设备"), to: menu)
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

    private func addSleepControls() {
        let powerOff = add(localized("睡眠时关闭整机蓝牙"), action: #selector(togglePowerOffOnSleep), to: menu)
        powerOff.state = preferences.bool(forKey: "powerOffOnSleep") ? .on : .off
        let unavailable = add(localized("睡眠时只断开单个设备 · 暂不可用"), to: menu)
        unavailable.toolTip = localized("当前接口无法可靠断开蓝牙鼠标，详见 README。")
        if preferences.bool(forKey: restorePowerKey) {
            _ = add(localized("立即恢复整机蓝牙"), action: #selector(connectNow), to: menu)
        }
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
        if device?.address != selection { wakeTime = nil }
        generation += 1
        preferences.set(device?.address, forKey: "deviceAddress")
        preferences.set(device?.name, forKey: "deviceName")
        publish(device.map { localized("正在监控 %@", $0.name) } ?? localized("请选择一台已配对设备"))
    }

    @objc private func togglePowerOffOnSleep() {
        preferences.set(!preferences.bool(forKey: "powerOffOnSleep"), forKey: "powerOffOnSleep")
        rebuildMenu()
    }

    @objc private func connectNow() {
        generation += 1
        restorePowerAndReconnect(generation: generation)
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
            publish(localized("无法更改登录项：%@", error.localizedDescription), kind: .problem)
        }
    }
}
