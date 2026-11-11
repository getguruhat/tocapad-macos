import SwiftUI
import AppKit
import Combine

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

        // Trackpads stop sending after sleep; listen again on wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.rescan() }
        }
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
    private let onOpen: () -> Void
    private var outsideClicks: Any?
    private var watchers: Set<AnyCancellable> = []

    init(settings: Settings, status: Status, updates: UpdateChecker, onOpen: @escaping () -> Void) {
        self.settings = settings
        self.onOpen = onOpen
        hosting = MenuHostingView(rootView: MenuContent(settings: settings, status: status, updates: updates))
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

        item.button?.target = self
        item.button?.action = #selector(toggle)
        updateItem()
        settings.$enabled.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateItem() }
        }.store(in: &watchers)
        // The About window sits below the menu's level, so the menu gets out of its way.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] note in
                guard let self, (note.object as? NSWindow) !== self.panel else { return }
                self.close()
            }.store(in: &watchers)
    }

    private func updateItem() {
        let image = NSImage(systemSymbolName: settings.enabled ? "hand.point.up.left.fill" : "hand.point.up.left",
                            accessibilityDescription: "TocaPad")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.appearsDisabled = !settings.enabled
    }

    @objc private func toggle() { panel.isVisible ? close() : show() }

    func show() {
        onOpen()
        guard let button = item.button, let buttonWindow = button.window else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
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
    static let orange = dynamic(rgb(0.961, 0.502, 0.098), rgb(1.0, 0.616, 0.263))
    static let green = dynamic(rgb(0.086, 0.678, 0.369), rgb(0.263, 0.812, 0.494))
    static let text = dynamic(rgb(0.102, 0.110, 0.137), rgb(0.961, 0.965, 0.973))
    static let secondary = dynamic(rgb(0.420, 0.443, 0.494), rgb(0.616, 0.635, 0.678))
    static let stroke = dynamic(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.09))
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
        .accessibilityValue(configuration.isOn ? "On" : "Off")
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

// MARK: Menu

struct MenuContent: View {
    @ObservedObject var settings: Settings
    @ObservedObject var status: Status
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if status.trackpads == 0 {
                Label("No trackpad found. TocaPad needs a built-in or Magic Trackpad.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .card()
            }
            if let update = updates.available {
                Link(destination: update.page) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
                        Text("TocaPad \(update.version) is available").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                    .card()
                }
                .buttonStyle(.plain)
            }
            levels
            features
            tuning
            HStack {
                Toggle("Open at login", isOn: $settings.openAtLogin).toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                Text("Version \(appVersion)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 340)
        .foregroundStyle(Theme.text)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.page)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hand.point.up.left.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                Text("TocaPad").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Toggle("TocaPad on", isOn: $settings.enabled).toggleStyle(AccentSwitch(width: 32)).labelsHidden()
                    .help(settings.enabled ? "Turn TocaPad off" : "Turn TocaPad on")
            }
            .padding(.leading, 12).padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.stroke))

            Button { AboutWindowController.shared.show() } label: { Image(systemName: "info") }
                .buttonStyle(CircleButtonStyle())
                .help("About TocaPad").accessibilityLabel("About TocaPad")

            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(CircleButtonStyle())
                .help("Quit TocaPad").accessibilityLabel("Quit TocaPad")
        }
    }

    private var levels: some View {
        let left = settings.swapSides ? "Volume" : "Brightness"
        let right = settings.swapSides ? "Brightness" : "Volume"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                level(title: "Brightness", symbol: "sun.max.fill", value: status.brightness,
                      note: status.brightnessAdjustable ? nil : "Not adjustable", color: Theme.orange)
                level(title: "Volume", symbol: status.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                      value: status.volume, note: !status.volumeAdjustable ? "Not adjustable" : status.muted ? "Muted" : nil,
                      color: Theme.accent)
            }
            Text("Slide one finger up or down the left edge for \(left.lowercased()), the right edge for \(right.lowercased()).")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func level(title: String, symbol: String, value: Float, note: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            Text(note ?? "\(Int((value * 100).rounded()))%")
                .font(.system(size: note == nil ? 22 : 13, weight: .semibold).monospacedDigit())
                .frame(height: 26, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.control)
                    Capsule().fill(color).frame(width: max(4, geo.size.width * CGFloat(value)))
                }
            }
            .frame(height: 5)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.page))
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Haptic feedback", "A light tick under your finger as you slide.", "waveform", $settings.haptics)
            Divider()
            row("Quick mute", "Double-tap the very top-right corner. A double-click there mutes too.", "speaker.slash", $settings.quickMute)
            Divider()
            row("Cursor freeze", "The pointer stays put while you slide.", "cursorarrow", $settings.cursorFreeze)
            Divider()
            row("Bottom quarter only", "Only the lower part of the trackpad responds.", "rectangle.bottomhalf.filled", $settings.bottomQuarter)
            Divider()
            row("Swap sides", "Volume on the left, brightness on the right.", "arrow.left.arrow.right", $settings.swapSides)
        }
        .card()
    }

    private func row(_ title: String, _ detail: String, _ symbol: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle(title, isOn: value).toggleStyle(AccentSwitch()).labelsHidden().accessibilityLabel(title)
        }
    }

    private var tuning: some View {
        VStack(alignment: .leading, spacing: 10) {
            slider("Sensitivity", String(format: "%.1f×", settings.sensitivity), $settings.sensitivity, 0.5...3)
            slider("Edge width", "\(Int((settings.edgeWidth * 100).rounded()))%", $settings.edgeWidth, 0.06...0.25)
            Text("Hold Shift-Option while sliding for fine steps.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .card()
    }

    private func slider(_ title: String, _ value: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            Slider(value: binding, in: range).controlSize(.small)
        }
    }
}
