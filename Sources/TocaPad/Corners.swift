import AppKit
import ApplicationServices

/// A corner of the trackpad that a double tap can run an action from.
enum Corner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }

    /// The corner a point is in, in trackpad coordinates (0–1, y up), if it's in one.
    static func at(x: Float, y: Float) -> Corner? {
        let left = x < 0.1, right = x > 0.9, top = y > 0.85, bottom = y < 0.15
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: return nil
        }
    }
}

/// What a corner does when double-tapped.
struct CornerAction: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case none, mute, playPause, nextTrack, previousTrack
        case missionControl, showDesktop, lockScreen, screenshot
        case openApp, shortcut
    }

    var kind: Kind = .none
    var appPath: String?
    var keyCode: UInt16?
    var modifiers: UInt?
    var keyName: String?

    static let none = CornerAction()

    var isSet: Bool { kind != .none }

    /// Media keys and shortcuts are sent as key presses, which macOS only allows with
    /// Accessibility access.
    var needsAccessibility: Bool {
        [.playPause, .nextTrack, .previousTrack, .shortcut].contains(kind)
    }

    var title: String {
        switch kind {
        case .openApp:
            guard let appPath else { return Self.title(.openApp) }
            return "Open " + FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
        case .shortcut:
            guard let keyName else { return Self.title(.shortcut) }
            return Self.modifierSymbols(modifiers ?? 0) + keyName
        default:
            return Self.title(kind)
        }
    }

    var symbol: String { Self.symbol(kind) }

    static func title(_ kind: Kind) -> String {
        switch kind {
        case .none: return "Nothing"
        case .mute: return "Mute"
        case .playPause: return "Play or pause"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .missionControl: return "Mission Control"
        case .showDesktop: return "Show desktop"
        case .lockScreen: return "Lock screen"
        case .screenshot: return "Screenshot"
        case .openApp: return "Open an app…"
        case .shortcut: return "Keyboard shortcut…"
        }
    }

    static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .none: return "circle.dashed"
        case .mute: return "speaker.slash.fill"
        case .playPause: return "playpause.fill"
        case .nextTrack: return "forward.fill"
        case .previousTrack: return "backward.fill"
        case .missionControl: return "rectangle.3.group"
        case .showDesktop: return "menubar.dock.rectangle"
        case .lockScreen: return "lock.fill"
        case .screenshot: return "camera.viewfinder"
        case .openApp: return "app.badge"
        case .shortcut: return "command"
        }
    }

    static func modifierSymbols(_ raw: UInt) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }

    /// A recorded key press, or nil for Escape alone (which cancels recording).
    static func shortcut(from event: NSEvent) -> CornerAction? {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if event.keyCode == 53 && flags.isEmpty { return nil }
        let named: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        let name = named[event.keyCode] ?? (event.characters(byApplyingModifiers: [])?.uppercased() ?? "?")
        return CornerAction(kind: .shortcut, keyCode: event.keyCode, modifiers: flags.rawValue, keyName: name)
    }
}

/// Runs corner actions (mute is handled by the engine, which also updates the menu).
enum Actions {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS for Accessibility access and opens its pane in System Settings.
    static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func run(_ action: CornerAction) {
        switch action.kind {
        case .none, .mute: break
        case .playPause: mediaKey(16)
        case .nextTrack: mediaKey(17)
        case .previousTrack: mediaKey(18)
        case .missionControl: openApp("/System/Applications/Mission Control.app")
        case .showDesktop: missionControl(argument: "1")
        case .lockScreen: lockScreen()
        case .screenshot: openApp("/System/Applications/Utilities/Screenshot.app")
        case .openApp: if let path = action.appPath { openApp(path) }
        case .shortcut:
            guard let code = action.keyCode else { return }
            pressKey(code, modifiers: NSEvent.ModifierFlags(rawValue: action.modifiers ?? 0))
        }
    }

    private static func openApp(_ path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    /// Mission Control's own binary takes 1 for Show Desktop and 2 for App Exposé.
    private static func missionControl(argument: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
        process.arguments = [argument]
        try? process.run()
    }

    private static func lockScreen() {
        typealias Lock = @convention(c) () -> Void
        if let lib = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let sym = dlsym(lib, "SACLockScreenImmediate") {
            unsafeBitCast(sym, to: Lock.self)()
        }
    }

    /// Presses and releases a media key (play, next, previous) as the keyboard does.
    private static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: (key << 16) | (state << 8), data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func pressKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags) {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
