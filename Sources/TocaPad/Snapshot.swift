import AppKit
import SwiftUI

/// Saves the menu and Settings (light and dark), the on-screen level and the About window as PNGs, at
/// 2x, with sample values so the pictures don't show this Mac's own levels.
enum Snapshot {
    static func run(to folder: URL) -> Never {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let status = Status()
        status.volume = 0.62
        status.brightness = 0.78
        status.trackpads = 1
        // A throwaway defaults domain, so the person's own settings are never touched.
        let scratch = UserDefaults(suiteName: "com.guruhat.tocapad.snapshot")!
        scratch.removePersistentDomain(forName: "com.guruhat.tocapad.snapshot")
        let settings = Settings(defaults: scratch)
        settings.enabled = true
        settings.haptics = true
        settings.cursorFreeze = true
        settings.corners = [.topRight: CornerAction(kind: .mute), .topLeft: CornerAction(kind: .missionControl),
                            .bottomRight: CornerAction(kind: .playPause)]
        settings.bottomQuarter = false
        settings.volumeSide = .right
        settings.brightnessSide = .left
        let updates = UpdateChecker(appName: "TocaPad", repo: "getguruhat/tocapad-macos")
        let model = HUD.Model()
        model.kind = .volume
        model.value = 0.62

        func save(_ view: NSView, _ name: String, appearance: NSAppearance.Name) {
            view.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize == .zero ? view.frame.size : view.fittingSize),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = bounds.size
            view.cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
            print("ok   \(name): \(Int(bounds.width))×\(Int(bounds.height))")
        }

        DispatchQueue.main.async {
            let pages: [(MenuState.Tab, String)] = [
                (.levels, "menu"), (.edges, "settings"), (.corners, "settings-corners"), (.general, "settings-general")]
            for (tab, prefix) in pages {
                for (suffix, look) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                    let state = MenuState(settings: settings)
                    state.tab = tab
                    state.trusted = true
                    save(NSHostingView(rootView: MenuContent(settings: settings, status: status, updates: updates, state: state)),
                         prefix + suffix, appearance: look)
                }
            }
            let hud = NSHostingView(rootView: HUDView(model: model)
                .frame(width: 290, height: 64)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.96))))
            save(hud, "hud", appearance: .aqua)
            save(NSHostingView(rootView: AboutView()), "about", appearance: .aqua)
            scratch.removePersistentDomain(forName: "com.guruhat.tocapad.snapshot")
            exit(0)
        }
        app.run()
        exit(1)
    }
}
