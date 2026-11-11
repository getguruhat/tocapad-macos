import AppKit
import Combine
import ServiceManagement

/// What the user can change, saved in UserDefaults. (@State needs a macro plugin the
/// command-line toolchain lacks, so the views bind to this.)
final class Settings: ObservableObject {
    private let d: UserDefaults

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    @Published var quickMute: Bool { didSet { d.set(quickMute, forKey: "quickMute") } }
    @Published var cursorFreeze: Bool { didSet { d.set(cursorFreeze, forKey: "cursorFreeze") } }
    @Published var bottomQuarter: Bool { didSet { d.set(bottomQuarter, forKey: "bottomQuarter") } }
    @Published var swapSides: Bool { didSet { d.set(swapSides, forKey: "swapSides") } }
    @Published var sensitivity: Double { didSet { d.set(sensitivity, forKey: "sensitivity") } }
    @Published var edgeWidth: Double { didSet { d.set(edgeWidth, forKey: "edgeWidth") } }
    @Published var openAtLogin: Bool {
        didSet {
            guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do { openAtLogin ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("TocaPad: open at login failed: \(error)") }
        }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        d.register(defaults: ["enabled": true, "haptics": true, "quickMute": false, "cursorFreeze": true,
                              "bottomQuarter": false, "swapSides": false, "sensitivity": 1.3, "edgeWidth": 0.12])
        enabled = d.bool(forKey: "enabled")
        haptics = d.bool(forKey: "haptics")
        quickMute = d.bool(forKey: "quickMute")
        cursorFreeze = d.bool(forKey: "cursorFreeze")
        bottomQuarter = d.bool(forKey: "bottomQuarter")
        swapSides = d.bool(forKey: "swapSides")
        sensitivity = d.double(forKey: "sensitivity")
        edgeWidth = d.double(forKey: "edgeWidth")
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// The live values the menu shows.
final class Status: ObservableObject {
    @Published var volume: Float = 0
    @Published var muted = false
    @Published var volumeAdjustable = true
    @Published var brightness: Float = 0
    @Published var brightnessAdjustable = true
    @Published var trackpads = 0

    func refresh() {
        volume = Volume.level
        muted = Volume.isMuted
        volumeAdjustable = Volume.isAdjustable
        brightness = Brightness.level
        brightnessAdjustable = Brightness.isAdjustable
    }
}

enum Control { case volume, brightness }

/// Turns one finger sliding along a trackpad edge into volume or brightness changes, and a
/// double tap in the top-right corner into mute.
final class EdgeEngine {
    private let settings: Settings
    private let status: Status
    private let hud: HUD

    /// One finger being followed on one trackpad.
    private struct Track {
        var id: Int32
        var startX: Float, startY: Float
        var lastY: Float
        var startTime: Double
        var moved: Float = 0
        var control: Control?
        var active = false
        var value: Float = 0
        var step = 0
        var cursor: CGPoint
    }

    private var tracks: [UnsafeMutableRawPointer: Track] = [:]
    /// Trackpads that had two or more fingers down; ignored until every finger lifts.
    private var blocked: Set<UnsafeMutableRawPointer> = []
    private var lastTap: (time: Double, x: Float, y: Float)?
    private var frozen = false

    /// Steps a slide snaps a haptic tick to, like the 16 steps of the volume keys.
    private let steps: Float = 16

    init(settings: Settings, status: Status, hud: HUD) {
        self.settings = settings
        self.status = status
        self.hud = hud
    }

    func handle(device: UnsafeMutableRawPointer, touches: [Touch], time: Double) {
        let down = touches.filter(\.touching)
        guard settings.enabled else { end(device); return }

        if down.isEmpty {
            if let t = tracks[device], !blocked.contains(device) {
                checkTap(t, time: time)
            }
            end(device)
            blocked.remove(device)
            return
        }
        if down.count > 1 || blocked.contains(device) {
            end(device)
            blocked.insert(device)
            return
        }

        let f = down[0]
        guard var t = tracks[device], t.id == f.id else {
            end(device)
            tracks[device] = Track(id: f.id, startX: f.x, startY: f.y, lastY: f.y, startTime: time,
                                   control: control(atX: f.x, y: f.y),
                                   cursor: CGEvent(source: nil)?.location ?? .zero)
            return
        }

        let dx = f.x - t.startX, dy = f.y - t.startY
        t.moved = max(t.moved, (dx * dx + dy * dy).squareRoot())

        if let control = t.control, !t.active {
            if abs(dy) > 0.025 && abs(dy) > abs(dx) * 1.3 {
                t.active = true
                t.value = control == .volume ? (Volume.isMuted ? 0 : Volume.level) : Brightness.level
                t.step = Int((t.value * steps).rounded())
                t.lastY = f.y
                if settings.cursorFreeze { freeze(at: t.cursor) }
                show(control, t.value)
            } else if abs(dx) > 0.06 {
                t.control = nil  // A sideways move from the edge is just the pointer.
            }
        }

        if t.active, let control = t.control {
            let fine = NSEvent.modifierFlags.contains([.shift, .option])
            let gain = Float(settings.sensitivity) * (fine ? 0.25 : 1)
            t.value = min(max(t.value + (f.y - t.lastY) * gain, 0), 1)
            apply(control, t.value)
            let step = Int((t.value * steps).rounded())
            if step != t.step {
                t.step = step
                if settings.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
            }
            show(control, t.value)
            if frozen { CGWarpMouseCursorPosition(t.cursor) }
        }
        t.lastY = f.y
        tracks[device] = t
    }

    /// Which control an edge touch starts, if any.
    private func control(atX x: Float, y: Float) -> Control? {
        if settings.bottomQuarter && y > 0.25 { return nil }
        let w = Float(settings.edgeWidth)
        let right: Control = settings.swapSides ? .brightness : .volume
        let left: Control = settings.swapSides ? .volume : .brightness
        if x > 1 - w { return right }
        if x < w { return left }
        return nil
    }

    private func apply(_ control: Control, _ value: Float) {
        switch control {
        case .volume:
            Volume.level = value
            status.volume = value
            status.muted = Volume.isMuted
        case .brightness:
            Brightness.level = value
            status.brightness = value
        }
    }

    private func show(_ control: Control, _ value: Float) {
        switch control {
        case .volume:
            hud.show(kind: .volume, value: value, muted: false, unavailable: !Volume.isAdjustable)
        case .brightness:
            hud.show(kind: .brightness, value: value, muted: false, unavailable: !Brightness.isAdjustable)
        }
    }

    /// A quick tap that barely moved, in the very top-right corner. A second one within 0.4s
    /// at the same spot toggles mute. Off by default: with tap to click on, a double-click
    /// on something in that corner of the trackpad is the same gesture.
    private func checkTap(_ t: Track, time: Double) {
        guard settings.quickMute, !t.active, time - t.startTime < 0.25, t.moved < 0.015,
              t.startX > 0.9, t.startY > 0.85 else { lastTap = nil; return }
        if let first = lastTap, time - first.time < 0.4,
           abs(t.startX - first.x) < 0.04, abs(t.startY - first.y) < 0.04 {
            lastTap = nil
            let muted = !Volume.isMuted
            Volume.isMuted = muted
            status.muted = muted
            if settings.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
            hud.show(kind: .volume, value: Volume.level, muted: muted, unavailable: !Volume.isAdjustable)
        } else {
            lastTap = (time, t.startX, t.startY)
        }
    }

    /// Forgets every finger, for when the trackpads are listened to again.
    func reset() {
        tracks.removeAll()
        blocked.removeAll()
        lastTap = nil
        if frozen { unfreeze() }
    }

    private func end(_ device: UnsafeMutableRawPointer) {
        tracks[device] = nil
        if frozen && !tracks.values.contains(where: \.active) { unfreeze() }
    }

    /// Holds the pointer still while a finger slides along the edge.
    private func freeze(at point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(0)
        frozen = true
    }

    private func unfreeze() {
        CGAssociateMouseAndMouseCursorPosition(1)
        frozen = false
    }
}
