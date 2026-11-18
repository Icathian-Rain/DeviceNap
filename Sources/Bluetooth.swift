import Darwin
import Foundation
import IOBluetooth

struct Device: Codable {
    let address: String
    let name: String
    let connected: Bool

    var label: String { "\(name) · \(address.suffix(8).uppercased())" }
}

// Run Bluetooth operations in a short-lived process so a stalled system call
// cannot freeze the menu or hold the sleep acknowledgement indefinitely.
func bluetoothHelper(_ arguments: [String]) -> Int32 {
    if arguments.first == "power" { return BluetoothPower.helper(arguments) }
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
