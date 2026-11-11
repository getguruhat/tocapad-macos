import SwiftUI
import AppKit

/// The About window the menu's info button opens, laid out like AI Meter's.
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About TocaPad"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AboutView: View {
    private let donationURL = URL(string: "https://www.paypal.com/donate/?hosted_button_id=FHGYWD46722JS")!

    var body: some View {
        VStack(spacing: 14) {
            if let url = Bundle.main.url(forResource: "icon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 88, height: 88)
            }
            Text("TocaPad").font(.title2).bold()
            Text("Version \(appVersion)").foregroundStyle(.secondary)
            Text("Slide the trackpad edges for volume and brightness.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("A GuruHat tool").font(.subheadline).foregroundStyle(.secondary)
            Divider().padding(.vertical, 6)
            Link(destination: donationURL) {
                Label("Support TocaPad", systemImage: "heart.fill").frame(maxWidth: .infinity)
            }
            Text("Thank you for supporting this project!")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 390, height: 400)
    }
}
