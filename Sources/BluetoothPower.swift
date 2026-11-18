import Darwin
import Foundation

// These controller-level functions are exported by IOBluetooth but are not
// in the public SDK headers. Resolve them at runtime so their absence only
// disables controller power changes.
enum BluetoothPower {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void

    static func helper(_ arguments: [String]) -> Int32 {
        guard let framework = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY),
              let getSymbol = dlsym(framework, "IOBluetoothPreferenceGetControllerPowerState"),
              let setSymbol = dlsym(framework, "IOBluetoothPreferenceSetControllerPowerState") else { return 1 }

        let get = unsafeBitCast(getSymbol, to: Getter.self)
        let set = unsafeBitCast(setSymbol, to: Setter.self)
        if arguments == ["power"] {
            let state = get()
            guard state == 0 || state == 1 else { return 1 }
            print(state)
            return 0
        }

        guard arguments.count == 2, let state = Int32(arguments[1]), state == 0 || state == 1 else { return 1 }
        if get() == state { return 0 }
        set(state)
        for _ in 0..<40 {
            if get() == state { return 0 }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return get() == state ? 0 : 1
    }
}
