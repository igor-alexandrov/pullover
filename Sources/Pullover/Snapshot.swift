import AppKit
import SwiftUI

/// Renders the popup offscreen to a PNG and quits: `PULLOVER_DEMO=1
/// PULLOVER_SNAPSHOT=out.png`, with `PULLOVER_SNAPSHOT_STATE` set to
/// `settings`, `repositories`, `compact` or `dark` for the other screens.
/// For documentation and for checking a layout change without a screen.
@MainActor
enum Snapshot {
    static func run(to path: String) {
        let state = ProcessInfo.processInfo.environment["PULLOVER_SNAPSHOT_STATE"] ?? ""
        let model = AppModel()
        model.launch()

        Task { @MainActor in
            await model.inbox.whenIdle()
            try? await Task.sleep(for: .seconds(2))
            if state.contains("compact") { model.updateSettings { $0.layout = .compact } }
            if state.contains("settings") { model.showSettings = true }
            if state.contains("repositories") {
                model.updateSettings { $0.watchAllRepositories = false }
                model.showSettings = true
                model.settingsPane = .repositories
            }
            model.popupWillOpen()

            // The popover paints the background behind the views; offscreen, nothing does.
            let view = NSHostingView(rootView: RootView(model: model).background(Color(nsColor: .windowBackgroundColor)))
            view.frame = NSRect(x: 0, y: 0, width: 440, height: 620)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: state.contains("dark") ? .darkAqua : .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = view
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(2))

            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
