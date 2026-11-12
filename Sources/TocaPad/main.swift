import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let status = Status()
    private let hud = HUD()
    private var engine: EdgeEngine!
    private var touch: Multitouch!
    private var menu: MenuController!
    private var watcher: TrackpadWatcher?
    private let updates = UpdateChecker(appName: "TocaPad", repo: "getguruhat/tocapad-macos")
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = EdgeEngine(settings: settings, status: status, hud: hud)
        touch = Multitouch { [weak self] device, touches, time in
            // Frames arrive on the framework's own thread.
            DispatchQueue.main.async { self?.engine.handle(device: device, touches: touches, time: time) }
        }
        rescan()
        status.refresh()
        watcher = TrackpadWatcher { [weak self] in self?.rescan() }
        updates.start()
        menu = MenuController(settings: settings, status: status, updates: updates, onOpen: { [weak self] in
            self?.rescan()
            self?.status.refresh()
        })

        // With the icon hidden, opening TocaPad by hand is the only way in, so show Settings,
        // but not when it starts at login.
        if !settings.showInMenuBar && !launchedAtLogin && ProcessInfo.processInfo.systemUptime > 180 {
            DispatchQueue.main.async { self.menu.show(tab: .general) }
        }

        // Trackpads stop sending after sleep; listen again on wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.rescan() }
        }
    }

    /// Opening TocaPad again from Applications, Spotlight or the Dock shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menu.show(tab: .general)
        return false
    }

    private func rescan() {
        engine.reset()
        touch.restart()
        status.trackpads = touch.deviceCount
    }

    func applicationWillTerminate(_ notification: Notification) {
        touch.stopAll()
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

@main
enum Entry {
    static func main() {
        // `TocaPad --snapshot <folder>` saves the menu and About window as PNGs for the
        // README and website, not the app.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// The menu bar item and the panel it opens, sized to its content, as in ServerHat.
final class MenuController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: MenuPanel
    private let hosting: MenuHostingView
    private let settings: Settings
    private let state: MenuState
    private let onOpen: () -> Void
    private var outsideClicks: Any?
    private var watchers: Set<AnyCancellable> = []

    init(settings: Settings, status: Status, updates: UpdateChecker, onOpen: @escaping () -> Void) {
        self.settings = settings
        self.onOpen = onOpen
        state = MenuState(settings: settings)
        hosting = MenuHostingView(rootView: MenuContent(settings: settings, status: status, updates: updates, state: state))
        panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak self] in self?.close() }
        hosting.onResize = { [weak self] in self?.fit() }
        state.chooseApp = { [weak self] corner in self?.chooseApp(for: corner) }

        item.button?.target = self
        item.button?.action = #selector(toggle)
        updateItem()
        settings.$enabled.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateItem() }
        }.store(in: &watchers)
        settings.$showInMenuBar.receive(on: DispatchQueue.main).sink { [weak self] shown in
            self?.item.isVisible = shown
            if !shown { self?.item.button?.highlight(false) }
        }.store(in: &watchers)
        // The About window sits below the menu's level, so the menu gets out of its way.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] note in
                guard let self, (note.object as? NSWindow) !== self.panel else { return }
                self.close()
            }.store(in: &watchers)
    }

    private func updateItem() {
        item.button?.image = Self.glyph(on: settings.enabled)
        item.button?.setAccessibilityLabel("TocaPad")
        item.button?.appearsDisabled = !settings.enabled
    }

    /// The menu bar glyph: a trackpad with a fingertip on its right edge (just the
    /// trackpad when TocaPad is off).
    static func glyph(on: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 15), flipped: false) { _ in
            NSColor.black.set()
            let pad = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 1.75, width: 17.5, height: 11.5), xRadius: 3, yRadius: 3)
            pad.lineWidth = 1.5
            pad.stroke()
            guard on else { return true }
            NSBezierPath(roundedRect: NSRect(x: 14.4, y: 3.9, width: 1.7, height: 4.6), xRadius: 0.85, yRadius: 0.85).fill()
            NSBezierPath(ovalIn: NSRect(x: 12.9, y: 7.6, width: 4.7, height: 4.7)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func toggle() { panel.isVisible ? close() : show() }

    func show(tab: MenuState.Tab = .levels) {
        onOpen()
        state.tab = tab
        state.trusted = Actions.trusted
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if let button = item.button, let buttonWindow = button.window, item.isVisible,
           buttonWindow.occlusionState.contains(.visible) {
            let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
            panel.setFrame(NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height), display: true)
            button.highlight(true)
        } else {
            // No icon to hang from (hidden in Settings or by macOS): top center of the screen.
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - 8 - size.height,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        guard panel.isVisible else { return }
        state.stopRecording()
        panel.orderOut(nil)
        item.button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    /// Picks an app for a corner with an open panel, then comes back to Settings.
    private func chooseApp(for corner: Corner) {
        close()
        let open = NSOpenPanel()
        open.title = Strings.fill(Strings.current.chooseAppTitle, corner.title.lowercased())
        open.prompt = Strings.current.choose
        open.allowedContentTypes = [.application]
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        if open.runModal() == .OK, let url = open.url {
            settings.corners[corner] = CornerAction(kind: .openApp, appPath: url.path)
        }
        show(tab: .corners)
    }

    private func fit() {
        guard panel.isVisible else { return }
        DispatchQueue.main.async { [self] in
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            var frame = panel.frame
            guard abs(frame.height - size.height) > 0.5 else { return }
            frame.origin.y = frame.maxY - size.height
            frame.size = size
            panel.setFrame(frame, display: true)
        }
    }
}

final class MenuHostingView: NSHostingView<MenuContent> {
    var onResize: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onResize?()
    }
}

final class MenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: Theme

enum Theme {
    static let page = dynamic(rgb(0.953, 0.957, 0.969), rgb(0.078, 0.078, 0.086))
    static let card = dynamic(.white, rgb(0.118, 0.122, 0.133))
    static let accent = dynamic(rgb(0.263, 0.384, 1.0), rgb(0.322, 0.435, 1.0))
    static let orange = dynamic(rgb(0.851, 0.467, 0.024), rgb(0.984, 0.749, 0.141))
    static let green = dynamic(rgb(0.086, 0.678, 0.369), rgb(0.263, 0.812, 0.494))
    static let text = dynamic(rgb(0.102, 0.110, 0.137), rgb(0.961, 0.965, 0.973))
    static let secondary = dynamic(rgb(0.420, 0.443, 0.494), rgb(0.616, 0.635, 0.678))
    static let stroke = dynamic(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.09))
    /// The trackpad drawn in the menu.
    static let pad = dynamic(rgb(0.910, 0.925, 0.941), rgb(0.165, 0.204, 0.275))
    static let padEdge = dynamic(NSColor.black.withAlphaComponent(0.06), NSColor.white.withAlphaComponent(0.12))
    static let control = dynamic(rgb(0.937, 0.941, 0.953), rgb(0.180, 0.184, 0.200))

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
}

struct CircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Theme.card))
            .overlay(Circle().strokeBorder(Theme.stroke))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
    }
}

/// A switch in the accent color that looks the same whether or not the panel is key,
/// so the menu (and its screenshots) never shows greyed-out switches.
struct AccentSwitch: ToggleStyle {
    var width: CGFloat = 38

    func makeBody(configuration: Configuration) -> some View {
        let height = width * 0.58
        return Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Theme.accent : Theme.control)
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                Circle().fill(.white).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: width, height: height)
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? Strings.current.on : Strings.current.off)
    }
}

extension View {
    func card(padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
    }
}

