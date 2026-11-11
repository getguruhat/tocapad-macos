import Foundation
import CoreAudio
import AudioToolbox
import CoreGraphics
import AppKit

/// The default output device's volume and mute, through Core Audio.
enum Volume {
    private static var device: AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// False for outputs such as HDMI and some USB devices, whose volume is set on the device itself.
    static var isAdjustable: Bool {
        guard let device else { return false }
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &a) && AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
    }

    static var level: Float {
        get {
            guard let device else { return 0 }
            var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr ? value : 0
        }
        set {
            guard let device else { return }
            var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            var value = Float32(min(max(newValue, 0), 1))
            AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            // Sliding up from silence unmutes, as the volume keys do.
            if value > 0, isMuted { isMuted = false }
        }
    }

    static var isMuted: Bool {
        get {
            guard let device else { return false }
            var a = address(kAudioDevicePropertyMute)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr && value != 0
        }
        set {
            guard let device else { return }
            var a = address(kAudioDevicePropertyMute)
            var value: UInt32 = newValue ? 1 : 0
            AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }
}

/// Display brightness through DisplayServices, the private framework the brightness keys use.
/// It works for the built-in display and Apple displays; most third-party monitors don't take it.
enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias Can = @convention(c) (CGDirectDisplayID) -> Bool

    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let get: Get? = lib.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let set: Set? = lib.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }
    private static let can: Can? = lib.flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }.map { unsafeBitCast($0, to: Can.self) }

    private static func displays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids
    }

    private static func adjustable(_ id: CGDirectDisplayID) -> Bool {
        if let can { return can(id) }
        var value: Float = 0
        return get?(id, &value) == 0
    }

    /// The display under the pointer if it can be dimmed, otherwise the built-in one.
    static var target: CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           adjustable(id) {
            return id
        }
        return displays().first { CGDisplayIsBuiltin($0) != 0 && adjustable($0) } ?? displays().first(where: adjustable)
    }

    static var isAdjustable: Bool { target != nil }

    static var level: Float {
        get {
            guard let id = target, let get else { return 0 }
            var value: Float = 0
            return get(id, &value) == 0 ? value : 0
        }
        set {
            guard let id = target, let set else { return }
            _ = set(id, min(max(newValue, 0), 1))
        }
    }
}
