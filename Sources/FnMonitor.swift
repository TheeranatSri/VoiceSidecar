import Foundation
import IOKit.hid
import CoreGraphics

/// Receives ONLY AppleVendorTopCase/KeyboardFn (0xFF/0x03), not other keystrokes.
/// Does not suppress, remap, or synthesize keyboard events.
final class FnMonitor {
    var onChange: ((Bool) -> Void)?
    private var manager: IOHIDManager?
    private var keyDown = false
    private(set) var keyboardCount = 0

    var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    @discardableResult
    func start() -> Bool {
        guard inputMonitoringGranted else { return false }
        if manager != nil { return true }
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let devices: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x06],
            [kIOHIDDeviceUsagePageKey: 0xFF, kIOHIDDeviceUsageKey: 0x03]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(newManager, devices as CFArray)
        let fnOnly: [[String: Any]] = [
            [kIOHIDElementUsagePageKey: 0xFF, kIOHIDElementUsageKey: 0x03]
        ]
        IOHIDManagerSetInputValueMatchingMultiple(newManager, fnOnly as CFArray)
        IOHIDManagerRegisterInputValueCallback(newManager, fnInputCallback,
            Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(newManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(newManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return false
        }
        manager = newManager
        keyboardCount = 0
        if let connected = IOHIDManagerCopyDevices(newManager) as? Set<IOHIDDevice> {
            for device in connected {
                let matching: [String: Any] = [
                    kIOHIDElementUsagePageKey: 0xFF, kIOHIDElementUsageKey: 0x03
                ]
                let elements = IOHIDDeviceCopyMatchingElements(device, matching as CFDictionary,
                                                                IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]
                if !(elements ?? []).isEmpty { keyboardCount += 1 }
            }
        }
        return true
    }

    fileprivate func received(pressed: Bool) {
        guard keyDown != pressed else { return }
        keyDown = pressed
        onChange?(pressed)
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = nil
        keyDown = false
    }

    deinit { stop() }
}

private func fnInputCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                             sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context else { return }
    let element = IOHIDValueGetElement(value)
    guard IOHIDElementGetUsagePage(element) == 0xFF,
          IOHIDElementGetUsage(element) == 0x03 else { return }
    let monitor = Unmanaged<FnMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.received(pressed: IOHIDValueGetIntegerValue(value) != 0)
}
