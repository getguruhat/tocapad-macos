import AppKit
import Combine
import ServiceManagement

/// What the user can change, saved in UserDefaults. (@State needs a macro plugin the
/// command-line toolchain lacks, so the views bind to this.)
final class Settings: ObservableObject {
    private let d: UserDefaults

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    /// What a double tap in each corner does. Saved as JSON, one key per corner.
    @Published var corners: [Corner: CornerAction] {
        didSet {
            for corner in Corner.allCases {
                d.set(try? JSONEncoder().encode(corners[corner] ?? .none), forKey: "corner." + corner.rawValue)
            }
        }
    }
    @Published var cursorFreeze: Bool { didSet { d.set(cursorFreeze, forKey: "cursorFreeze") } }
    @Published var bottomQuarter: Bool { didSet { d.set(bottomQuarter, forKey: "bottomQuarter") } }
    /// Which trackpad edge each control lives on. Two controls never share an edge: picking a
    /// taken edge moves the other control to the one this control left.
    @Published var volumeSide: EdgeSide {
        didSet {
            d.set(volumeSide.rawValue, forKey: "volumeSide")
            if volumeSide != .off && brightnessSide == volumeSide { brightnessSide = oldValue }
        }
    }
    @Published var brightnessSide: EdgeSide {
        didSet {
            d.set(brightnessSide.rawValue, forKey: "brightnessSide")
            if brightnessSide != .off && volumeSide == brightnessSide { volumeSide = oldValue }
        }
    }
    @Published var sensitivity: Double { didSet { d.set(sensitivity, forKey: "sensitivity") } }
    @Published var edgeWidth: Double { didSet { d.set(edgeWidth, forKey: "edgeWidth") } }
    /// Ignores edge touches that start just after a key press, so a resting palm can't slide.
    @Published var typingGuard: Bool { didSet { d.set(typingGuard, forKey: "typingGuard") } }
    @Published var openAtLogin: Bool {
        didSet {
            guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do { openAtLogin ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("TocaPad: open at login failed: \(error)") }
        }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        d.register(defaults: ["enabled": true, "haptics": true, "cursorFreeze": true,
                              "bottomQuarter": false, "swapSides": false, "sensitivity": 1.3, "edgeWidth": 0.12,
                              "typingGuard": true])
        enabled = d.bool(forKey: "enabled")
        haptics = d.bool(forKey: "haptics")
        var corners: [Corner: CornerAction] = [:]
        for corner in Corner.allCases {
            if let data = d.data(forKey: "corner." + corner.rawValue),
               let action = try? JSONDecoder().decode(CornerAction.self, from: data) {
                corners[corner] = action
            }
        }
        // 0.1.0 had a single Quick mute switch for the top-right corner.
        if corners[.topRight] == nil, d.bool(forKey: "quickMute") {
            corners[.topRight] = CornerAction(kind: .mute)
        }
        self.corners = corners
        cursorFreeze = d.bool(forKey: "cursorFreeze")
        bottomQuarter = d.bool(forKey: "bottomQuarter")
        // 0.1.x had a single Swap sides switch.
        let swapped = d.bool(forKey: "swapSides")
        volumeSide = d.string(forKey: "volumeSide").flatMap(EdgeSide.init) ?? (swapped ? .left : .right)
        brightnessSide = d.string(forKey: "brightnessSide").flatMap(EdgeSide.init) ?? (swapped ? .right : .left)
        sensitivity = d.double(forKey: "sensitivity")
        edgeWidth = d.double(forKey: "edgeWidth")
        typingGuard = d.bool(forKey: "typingGuard")
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

/// A trackpad edge a control can sit on.
enum EdgeSide: String, CaseIterable, Identifiable {
    case off, left, right, top, bottom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .left: "Left edge"
        case .right: "Right edge"
        case .top: "Top edge"
        case .bottom: "Bottom edge"
        }
    }
    /// Top and bottom edges slide sideways; left and right slide up and down.
    var horizontal: Bool { self == .top || self == .bottom }
}

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
        var lastX: Float, lastY: Float
        var startTime: Double
        var moved: Float = 0
        var control: Control?
        var horizontal = false
        var active = false
        var value: Float = 0
        var step = 0
        var cursor: CGPoint
    }

    private var tracks: [UnsafeMutableRawPointer: Track] = [:]
    /// Trackpads that had two or more fingers down; ignored until every finger lifts.
    private var blocked: Set<UnsafeMutableRawPointer> = []
    private var lastTap: (time: Double, x: Float, y: Float, corner: Corner)?
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
            let zone = zone(atX: f.x, y: f.y)
            tracks[device] = Track(id: f.id, startX: f.x, startY: f.y, lastX: f.x, lastY: f.y, startTime: time,
                                   control: zone?.control, horizontal: zone?.side.horizontal ?? false,
                                   cursor: CGEvent(source: nil)?.location ?? .zero)
            return
        }

        let dx = f.x - t.startX, dy = f.y - t.startY
        t.moved = max(t.moved, (dx * dx + dy * dy).squareRoot())

        // Along the edge and across it, in trackpad units.
        let along = t.horizontal ? dx : dy, across = t.horizontal ? dy : dx
        if let control = t.control, !t.active {
            if abs(along) > 0.025 && abs(along) > abs(across) * 1.3 {
                t.active = true
                t.value = control == .volume ? (Volume.isMuted ? 0 : Volume.level) : Brightness.level
                t.step = Int((t.value * steps).rounded())
                t.lastX = f.x
                t.lastY = f.y
                if settings.cursorFreeze { freeze(at: t.cursor) }
                show(control, t.value)
            } else if abs(across) > (t.horizontal ? 0.09 : 0.06) {
                t.control = nil  // Moving away from the edge is just the pointer.
            }
        }

        if t.active, let control = t.control {
            let fine = NSEvent.modifierFlags.contains([.shift, .option])
            let gain = Float(settings.sensitivity) * (fine ? 0.25 : 1)
            let delta = t.horizontal ? f.x - t.lastX : f.y - t.lastY
            t.value = min(max(t.value + delta * gain, 0), 1)
            apply(control, t.value)
            let step = Int((t.value * steps).rounded())
            if step != t.step {
                t.step = step
                if settings.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
            }
            show(control, t.value)
            if frozen { CGWarpMouseCursorPosition(t.cursor) }
        }
        t.lastX = f.x
        t.lastY = f.y
        tracks[device] = t
    }

    /// Which control an edge touch starts, if any, and the edge it is on.
    private func zone(atX x: Float, y: Float) -> (control: Control, side: EdgeSide)? {
        if settings.typingGuard && Self.secondsSinceKeyPress < Self.typingPause { return nil }
        let w = Float(settings.edgeWidth)
        var best: (control: Control, side: EdgeSide, distance: Float)?
        for (control, side) in [(Control.volume, settings.volumeSide), (.brightness, settings.brightnessSide)] {
            if side == .off { continue }
            if settings.bottomQuarter && !side.horizontal && y > 0.25 { continue }
            // Distance from the edge as a share of the trackpad's width, so a top or bottom
            // strip is as thick under the finger as a side one.
            let distance: Float
            switch side {
            case .left: distance = x
            case .right: distance = 1 - x
            case .bottom: distance = y / Self.aspect
            case .top: distance = (1 - y) / Self.aspect
            case .off: continue
            }
            if distance < w && distance < (best?.distance ?? .infinity) { best = (control, side, distance) }
        }
        return best.map { ($0.control, $0.side) }
    }

    /// Width over height of a Mac trackpad, near enough for every model.
    private static let aspect: Float = 1.6

    /// How long after a key press an edge touch counts as a palm.
    private static let typingPause: Double = 0.8

    /// Read from the window server's event counters; needs no Input Monitoring access.
    private static var secondsSinceKeyPress: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
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

    /// A quick tap that barely moved, in a corner that has an action. A second one within
    /// 0.4s at the same spot runs it. With tap to click on, the same double tap is also a
    /// double-click wherever the pointer is, which is why every corner starts empty.
    private func checkTap(_ t: Track, time: Double) {
        guard !t.active, time - t.startTime < 0.25, t.moved < 0.015,
              let corner = Corner.at(x: t.startX, y: t.startY),
              let action = settings.corners[corner], action.isSet else { lastTap = nil; return }
        if let first = lastTap, first.corner == corner, time - first.time < 0.4,
           abs(t.startX - first.x) < 0.04, abs(t.startY - first.y) < 0.04 {
            lastTap = nil
            run(action)
        } else {
            lastTap = (time, t.startX, t.startY, corner)
        }
    }

    private func run(_ action: CornerAction) {
        if action.kind == .mute {
            let muted = !Volume.isMuted
            Volume.isMuted = muted
            status.muted = muted
            hud.show(kind: .volume, value: Volume.level, muted: muted, unavailable: !Volume.isAdjustable)
            return
        }
        if action.needsAccessibility && !Actions.trusted {
            hud.message(symbol: "lock.shield", title: "TocaPad needs Accessibility access")
            return
        }
        Actions.run(action)
        // Actions that open something on screen speak for themselves.
        if [.playPause, .nextTrack, .previousTrack, .shortcut].contains(action.kind) {
            hud.message(symbol: action.symbol, title: action.title)
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
