import SwiftUI
import AppKit

/// The on-screen level shown while sliding, at the top right like macOS's own volume and
/// brightness display.
final class HUD {
    enum Kind { case volume, brightness }

    final class Model: ObservableObject {
        @Published var kind: Kind = .volume
        @Published var value: Float = 0
        @Published var muted = false
        @Published var unavailable = false
    }

    private let model = Model()
    private let panel: NSPanel
    private var hide: DispatchWorkItem?
    private let size = NSSize(width: 290, height: 64)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        panel.contentView = blur
    }

    func show(kind: Kind, value: Float, muted: Bool, unavailable: Bool) {
        model.kind = kind
        model.value = value
        model.muted = muted
        model.unavailable = unavailable

        if !panel.isVisible || panel.alphaValue < 1 {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let area = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 14, y: area.maxY - size.height - 10))
            }
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }
}

struct HUDView: View {
    @ObservedObject var model: HUD.Model

    private var symbol: String {
        switch model.kind {
        case .brightness: return "sun.max.fill"
        case .volume:
            if model.muted || model.value == 0 { return "speaker.slash.fill" }
            return model.value < 0.34 ? "speaker.wave.1.fill" : model.value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }

    private var title: String { model.kind == .volume ? "Sound" : "Display" }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(model.unavailable ? "Not adjustable" : model.muted ? "Muted" : "\(Int((model.value * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(Color.primary.opacity(model.muted || model.unavailable ? 0.3 : 0.9))
                            .frame(width: max(6, geo.size.width * CGFloat(model.value)))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
