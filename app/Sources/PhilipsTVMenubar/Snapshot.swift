import SwiftUI
import AppKit

/// `PhilipsTVMenubar --snapshot <dir>`: renders the real UI (live, read-only data from
/// the TV) into PNGs, one per tab, then quits. Used for README / blog screenshots.
/// Sends no commands to the TV and doesn't start the YouTube lounge session.
enum Snapshot {
    static var outputDir: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor static func run(dir: String) async {
        let state = AppState()
        let savedTab = UserDefaults.standard.string(forKey: "tab")

        let host = NSHostingView(rootView: ContentView().environmentObject(state).frame(width: 340))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.backgroundColor = .black
        window.setFrameOrigin(NSPoint(x: 40, y: 80))
        window.orderFrontRegardless()

        try? await Task.sleep(nanoseconds: 6_000_000_000)           // past the Local Network race
        await state.refresh()
        await state.loadApps()
        try? await Task.sleep(nanoseconds: 8_000_000_000)           // let app icons download
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        for tab in [Tab.home, .apps, .remote, .sources, .ambilight, .orange] {
            if tab == .orange && state.orangeHost == nil { continue }
            UserDefaults.standard.set(tab.rawValue, forKey: "tab")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                   CGWindowID(window.windowNumber),
                                                   [.boundsIgnoreFraming, .bestResolution]) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("app-\(tab.rawValue).png"))
            }
        }
        UserDefaults.standard.set(savedTab, forKey: "tab")
        exit(0)
    }
}
