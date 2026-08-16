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
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
