import Foundation
import IOKit

/// One finger on a trackpad, in the trackpad's own 0–1 coordinates (x left to right,
/// y bottom to top).
struct Touch {
    var id: Int32
    var x: Float
    var y: Float
    var touching: Bool
}

/// Reads raw finger positions from every trackpad through MultitouchSupport, the private
/// framework behind the trackpad. It's loaded at runtime, so a missing symbol on some
/// future macOS means "no trackpad found" rather than a crash.
final class Multitouch {
    typealias Frame = (_ device: UnsafeMutableRawPointer, _ touches: [Touch], _ time: Double) -> Void

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    /// The C callback can't capture anything, so frames go through this.
    nonisolated(unsafe) private static var onFrame: Frame?

    private var createList: CreateList?
    private var register: Register?
    private var unregister: Register?
    private var start: Start?
    private var stop: Stop?
    private var devices: [UnsafeMutableRawPointer] = []
    private var list: CFArray?

    private(set) var deviceCount = 0

    init(onFrame: @escaping Frame) {
        Multitouch.onFrame = onFrame
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else { return }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(lib, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        createList = sym("MTDeviceCreateList", CreateList.self)
        register = sym("MTRegisterContactFrameCallback", Register.self)
        unregister = sym("MTUnregisterContactFrameCallback", Register.self)
        start = sym("MTDeviceStart", Start.self)
        stop = sym("MTDeviceStop", Stop.self)
    }

    private static let callback: Callback = { device, data, count, time, _ in
        guard let device, let onFrame = Multitouch.onFrame else { return 0 }
        var touches: [Touch] = []
        if let data, count > 0 {
            // MTTouch is 96 bytes: identifier at 16, state at 20, normalized position at 32.
            for i in 0..<Int(count) {
                let base = data.advanced(by: i * 96)
                let id = base.load(fromByteOffset: 16, as: Int32.self)
                let state = base.load(fromByteOffset: 20, as: Int32.self)
                let x = base.load(fromByteOffset: 32, as: Float.self)
                let y = base.load(fromByteOffset: 36, as: Float.self)
                // 4 = touch began, 5 = touching. Hover, lift and linger don't count.
                touches.append(Touch(id: id, x: x, y: y, touching: state == 4 || state == 5))
            }
        }
        onFrame(device, touches, time)
        return 0
    }

    /// Starts listening to every trackpad connected now. Call again after wake or when a
    /// trackpad is plugged in.
    func restart() {
        stopAll()
        guard let createList, let register, let start,
              let array = createList()?.takeRetainedValue() else { deviceCount = 0; return }
        list = array
        for i in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, Multitouch.callback)
            _ = start(device, 0)
            devices.append(device)
        }
        deviceCount = devices.count
    }

    func stopAll() {
        for device in devices {
            unregister?(device, Multitouch.callback)
            _ = stop?(device)
        }
        devices.removeAll()
        list = nil
    }
}

/// Calls back when a trackpad is connected or disconnected (a Magic Trackpad pairing, a
/// lid opening), so TocaPad listens to it without waiting for the menu or a wake.
final class TrackpadWatcher {
    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            // Drain the iterator, which also re-arms the notification.
            while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
            guard let refcon else { return }
            Unmanaged<TrackpadWatcher>.fromOpaque(refcon).takeUnretainedValue().changed()
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, type, IOServiceMatching("AppleMultitouchDevice"), callback, me, &iterator) == KERN_SUCCESS {
                // The devices already there count as the first batch; drain without calling back.
                while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
                iterators.append(iterator)
            }
        }
    }

    /// Devices come and go in bursts, so wait for them to settle.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        IONotificationPortDestroy(port)
    }
}
