import SwiftUI
import AppKit

/// Which tab the menu shows, and the shortcut being recorded. (No @State without the
/// macro plugin, so this lives in an object.)
final class MenuState: ObservableObject {
    /// The menu's tabs, one at a time so the panel fits on a small screen.
    enum Tab: String, CaseIterable, Identifiable {
        case levels, edges, corners, general
        var id: String { rawValue }
        var title: String {
            switch self {
            case .levels: "Levels"
            case .edges: "Edges"
            case .corners: "Corners"
            case .general: "General"
            }
        }
        var symbol: String {
            switch self {
            case .levels: "slider.vertical.3"
            case .edges: "rectangle.portrait.lefthalf.inset.filled"
            case .corners: "square.grid.2x2"
            case .general: "gearshape"
            }
        }
    }

    @Published var tab: Tab = .levels
    @Published var recording: Corner?
    @Published var trusted = Actions.trusted
    var chooseApp: (Corner) -> Void = { _ in }

    private let settings: Settings
    private var monitor: Any?

    init(settings: Settings) { self.settings = settings }

    /// The next key press with its modifiers becomes the corner's shortcut; Escape cancels.
    func record(_ corner: Corner) {
        stopRecording()
        recording = corner
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let corner = self.recording else { return event }
            if let action = CornerAction.shortcut(from: event) {
                self.settings.corners[corner] = action
                if !Actions.trusted { Actions.requestAccess() }
            }
            self.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    func choose(_ kind: CornerAction.Kind, for corner: Corner) {
        switch kind {
        case .shortcut: record(corner)
        case .openApp: chooseApp(corner)
        default:
            stopRecording()
            let action = CornerAction(kind: kind)
            settings.corners[corner] = action
            if action.needsAccessibility && !Actions.trusted { Actions.requestAccess() }
        }
        trusted = Actions.trusted
    }
}

struct MenuContent: View {
    @ObservedObject var settings: Settings
    @ObservedObject var status: Status
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var state: MenuState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            notices
            tabBar
            switch state.tab {
            case .levels: levelsTab
            case .edges: edgesTab
            case .corners: cornersTab
            case .general: generalTab
            }
        }
        .padding(12)
        .frame(width: 340)
        .foregroundStyle(Theme.text)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.page)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Levels

    /// A missing trackpad or a new version, shown above every tab.
    @ViewBuilder private var notices: some View {
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
    }

    @ViewBuilder private var levelsTab: some View {
        levels
        VStack(alignment: .leading, spacing: 10) {
            row("Haptic feedback", "A light tick as you slide.", "waveform", $settings.haptics)
            Divider()
            slider("Sensitivity", String(format: "%.1f×", settings.sensitivity), $settings.sensitivity, 0.5...3)
        }
        .card()
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                AppIconImage(size: 18)
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

    /// The levels drawn on a little trackpad: each edge filled as far as its level, the
    /// way you'd slide it, with a dot in every corner that has a tap set.
    private var levels: some View {
        let brightness = PadLevel(title: "Brightness", symbol: "sun.max.fill", value: status.brightness,
                                  note: status.brightnessAdjustable ? nil : "Not adjustable", color: Theme.orange)
        let volume = PadLevel(title: "Volume", symbol: status.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                              value: status.volume,
                              note: !status.volumeAdjustable ? "Not adjustable" : status.muted ? "Muted" : nil,
                              color: Theme.accent)
        // Readings read left to right in the order their edges sit on the pad.
        let rank: [EdgeSide: Int] = [.left: 0, .top: 1, .bottom: 1, .off: 1, .right: 2]
        let placed = [(brightness, settings.brightnessSide), (volume, settings.volumeSide)]
        let ordered = placed.sorted { rank[$0.1]! < rank[$1.1]! }
        let first = ordered[0], second = ordered[1]
        return VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.pad)
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.padEdge)
                HStack(spacing: 0) {
                    padReading(first.0, alignment: .leading)
                    Spacer(minLength: 8)
                    padReading(second.0, alignment: .trailing)
                }
                .padding(.horizontal, 14).padding(.vertical, 20)
                ForEach(placed.filter { $0.1 != .off }, id: \.1) { level, side in
                    edgeStrip(level, side: side)
                }
                ForEach(Corner.allCases) { corner in
                    if settings.corners[corner]?.isSet == true {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: Alignment(horizontal: corner.isLeft ? .leading : .trailing,
                                                        vertical: corner.isTop ? .top : .bottom))
                            .padding(8)
                    }
                }
            }
            .frame(height: 118)
            .accessibilityElement(children: .combine)
            Text("Slide an edge. The middle still points and clicks.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .card(padding: 10)
    }

    private struct PadLevel {
        let title: String, symbol: String, value: Float, note: String?, color: Color
    }

    /// A level drawn along the edge it is slid on: bottom to top on a side, left to right
    /// on the top or bottom.
    private func edgeStrip(_ level: PadLevel, side: EdgeSide) -> some View {
        let fill = CGFloat(level.note == nil ? level.value : 0)
        return GeometryReader { geo in
            ZStack(alignment: side.horizontal ? .leading : .bottom) {
                Capsule().fill(Theme.control)
                Capsule().fill(level.color)
                    .frame(width: side.horizontal ? max(6, geo.size.width * fill) : nil,
                           height: side.horizontal ? nil : max(6, geo.size.height * fill))
                    .shadow(color: level.color.opacity(0.45), radius: 4)
            }
        }
        .frame(width: side.horizontal ? nil : 6, height: side.horizontal ? 6 : nil)
        .padding(side.horizontal ? .horizontal : .vertical, 20)
        .padding(side.horizontal ? .vertical : .horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side.alignment)
    }

    private func padReading(_ level: PadLevel, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: level.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(level.color)
                Text(level.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            if let note = level.note {
                Text(note).font(.system(size: 13, weight: .semibold))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int((level.value * 100).rounded()))").font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    Text("%").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: Edges, Corners, General

    /// The tabs, like a segmented control in the menu's own look.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(MenuState.Tab.allCases.enumerated()), id: \.element) { index, tab in
                let selected = state.tab == tab
                Button {
                    state.stopRecording()
                    state.tab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 10, weight: .semibold))
                        Text(tab.title).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(selected ? Color.white : Theme.secondary)
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(Capsule().fill(selected ? Theme.accent : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.stroke))
    }

    @ViewBuilder private var edgesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            sideRow("Volume", "speaker.wave.2.fill", $settings.volumeSide)
            Divider()
            sideRow("Brightness", "sun.max.fill", $settings.brightnessSide)
            Divider()
            row("Ignore while typing", "Palms on the edges do nothing just after a key press.", "keyboard", $settings.typingGuard)
            Divider()
            row("Bottom quarter only", "Left and right edges ignore touches higher up.", "rectangle.bottomhalf.filled", $settings.bottomQuarter)
            Divider()
            row("Cursor freeze", "The pointer stays put.", "cursorarrow", $settings.cursorFreeze)
            Divider()
            slider("Edge width", "\(Int((settings.edgeWidth * 100).rounded()))%", $settings.edgeWidth, 0.04...0.25)
            Text("Hold ⇧⌥ while sliding for fine steps.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .card()
    }

    @ViewBuilder private var cornersTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Double-tap a corner of the trackpad to run an action.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Laid out like the trackpad itself.
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { cornerTile(.topLeft); cornerTile(.topRight) }
                GridRow { cornerTile(.bottomLeft); cornerTile(.bottomRight) }
            }
            if needsAccess {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill").foregroundStyle(Theme.orange)
                    Text("Media keys and shortcuts need Accessibility access.")
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Allow…") { Actions.requestAccess() }.controlSize(.small)
                }
            }
            if settings.corners.values.contains(where: \.isSet) {
                Text("With tap to click on, a double tap is also a double-click where the pointer is.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    @ViewBuilder private var generalTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Open at login", "Starts when you log in.", "power", $settings.openAtLogin)
            Divider()
            row("Show in menu bar",
                settings.showInMenuBar ? "The TocaPad icon at the top of the screen."
                                       : "Hidden. Open TocaPad from Applications to come back here.",
                "menubar.rectangle", $settings.showInMenuBar)
        }
        .card()
        Text("TocaPad \(appVersion)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity)
    }

    private var needsAccess: Bool {
        !state.trusted && settings.corners.values.contains(where: \.needsAccessibility)
    }

    private func cornerTile(_ corner: Corner) -> some View {
        let action = settings.corners[corner] ?? .none
        let recording = state.recording == corner
        return VStack(alignment: corner.isLeft ? .leading : .trailing, spacing: 6) {
            HStack(spacing: 6) {
                if !corner.isLeft { Spacer(minLength: 0) }
                CornerIcon(corner: corner, active: action.isSet)
                Text(corner.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                if corner.isLeft { Spacer(minLength: 0) }
            }
            if recording {
                Text("Press keys · ⎋")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
            } else {
                Menu {
                    Button(CornerAction.title(.none)) { state.choose(.none, for: corner) }
                    Divider()
                    ForEach([CornerAction.Kind.mute, .playPause, .nextTrack, .previousTrack], id: \.self) { kind in
                        Button(CornerAction.title(kind)) { state.choose(kind, for: corner) }
                    }
                    Divider()
                    ForEach([CornerAction.Kind.missionControl, .showDesktop, .lockScreen, .screenshot], id: \.self) { kind in
                        Button(CornerAction.title(kind)) { state.choose(kind, for: corner) }
                    }
                    Divider()
                    Button(CornerAction.title(.openApp)) { state.choose(.openApp, for: corner) }
                    Button(CornerAction.title(.shortcut)) { state.choose(.shortcut, for: corner) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: action.symbol).font(.system(size: 10, weight: .semibold))
                        Text(action.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(action.isSet ? Theme.text : Theme.secondary)
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(Capsule().fill(Theme.card))
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                    .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("\(corner.title) corner: \(action.title)")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.page))
    }

    // MARK: Parts

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.13)))
    }

    private func row(_ title: String, _ detail: String, _ symbol: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            icon(symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle(title, isOn: value).toggleStyle(AccentSwitch()).labelsHidden().accessibilityLabel(title)
        }
    }

    /// A control and the edge it sits on, chosen from a menu.
    private func sideRow(_ title: String, _ symbol: String, _ side: Binding<EdgeSide>) -> some View {
        let value = side.wrappedValue
        let detail = value == .off ? "Not on any edge." : value.horizontal ? "Slide left and right." : "Slide up and down."
        return HStack(spacing: 10) {
            icon(symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 6)
            Menu {
                ForEach(EdgeSide.allCases) { option in
                    if option == .left { Divider() }
                    Button {
                        side.wrappedValue = option
                    } label: {
                        if option == value { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(value.title).font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(value == .off ? Theme.secondary : Theme.text)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().strokeBorder(Theme.stroke))
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(title) edge: \(value.title)")
        }
    }

    private func slider(_ title: String, _ value: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            Slider(value: binding, in: range).controlSize(.small).tint(Theme.accent)
        }
    }
}

/// A little trackpad with a dot in one corner.
struct CornerIcon: View {
    let corner: Corner
    let active: Bool

    var body: some View {
        ZStack(alignment: Alignment(horizontal: corner.isLeft ? .leading : .trailing,
                                    vertical: corner.isTop ? .top : .bottom)) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.5)
            Circle().fill(active ? Theme.accent : Theme.secondary.opacity(0.5))
                .frame(width: 5, height: 5).padding(2.5)
        }
        .frame(width: 18, height: 13)
    }
}

/// The app icon, for the menu header.
struct AppIconImage: View {
    let size: CGFloat
    private static let image: NSImage? = Bundle.main.url(forResource: "icon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        ?? NSImage(contentsOfFile: "icon.png")

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "hand.point.up.left.fill").font(.system(size: size * 0.7)).foregroundStyle(Theme.accent)
        }
    }
}

extension EdgeSide {
    /// Where this edge is inside the little trackpad drawing.
    var alignment: Alignment {
        switch self {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom, .off: .bottom
        }
    }
}
