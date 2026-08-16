import AppKit
import SwiftUI

/// Hosts the SwiftUI SettingsView in a regular window. LSUIElement apps must call
/// NSApp.activate to get a key window.
@MainActor
final class SettingsWindowController {

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "NoPeek 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            // Belt and braces for the sizing-collapse failure mode: fix the content
            // size explicitly instead of relying on hosting-controller sizing.
            window.setContentSize(NSSize(width: 500, height: 640))
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
