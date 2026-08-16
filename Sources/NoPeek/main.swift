import AppKit
import os

/// Structured logging. View live with: make log
enum Log {
    static let subsystem = "com.nopeek.NoPeek"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let detection = Logger(subsystem: subsystem, category: "detection")
    static let alert = Logger(subsystem: subsystem, category: "alert")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}

// Manual bootstrap — no @main, no storyboard. LSUIElement in Info.plist plus the
// .accessory activation policy below keep NoPeek out of the Dock and app switcher.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
