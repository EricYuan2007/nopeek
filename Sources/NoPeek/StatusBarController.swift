import AppKit

/// Owns the menu-bar status item: tri-color indicator + menu.
///
///   safe         green eye            monitoring / cooldown
///   suspicious   yellow eye           intruder frames seen, confirmation in progress
///   alert        red badge eye, 1 Hz pulse
///   paused       gray slashed eye     user paused
///   off          gray slashed eye     starting / locked / asleep
///   noPermission gray slashed eye     camera denied (status line explains)
@MainActor
final class StatusBarController {

    enum Indicator {
        case safe, suspicious, alert, paused, off, noPermission
    }

    struct Actions {
        var onTogglePause: () -> Void = {}
        var onToggleDebugOverlay: () -> Void = {}
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem()
    private let actions: Actions

    private var pulseTimer: Timer?
    private var pulseDimmed = false
    private(set) var indicator: Indicator = .off

    init(actions: Actions) {
        self.actions = actions

        statusLineItem.isEnabled = false
        pauseItem.title = "暂停监控"
        pauseItem.target = nil // set below via closure-friendly target
        pauseItem.keyEquivalent = "p"

        let debugItem = NSMenuItem(title: "调试浮层", action: nil, keyEquivalent: "d")
        let quitItem = NSMenuItem(title: "退出 NoPeek",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")

        let menu = NSMenu()
        menu.addItem(statusLineItem)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(debugItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        // MenuItem actions with closures need a target object — use self via helper.
        pauseItem.action = #selector(handleTogglePause)
        pauseItem.target = self
        debugItem.action = #selector(handleToggleDebug)
        debugItem.target = self

        setIndicator(.off)
    }

    func setIndicator(_ newIndicator: Indicator) {
        indicator = newIndicator
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseDimmed = false

        guard let button = statusItem.button else { return }
        button.alphaValue = 1.0

        let symbolName: String
        let tint: NSColor?
        switch newIndicator {
        case .safe:
            symbolName = "eye.fill"; tint = .systemGreen
        case .suspicious:
            symbolName = "eye.fill"; tint = .systemYellow
        case .alert:
            symbolName = "eye.trianglebadge.exclamationmark.fill"; tint = .systemRed
        case .paused, .off, .noPermission:
            symbolName = "eye.slash.fill"; tint = .systemGray
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "NoPeek")
        button.contentTintColor = tint

        if newIndicator == .alert {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pulseStep() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pulseTimer = timer
        }
    }

    private func pulseStep() {
        guard indicator == .alert, let button = statusItem.button else { return }
        pulseDimmed.toggle()
        button.alphaValue = pulseDimmed ? 0.35 : 1.0
    }

    func setStatusLine(_ text: String) {
        statusLineItem.title = text
    }

    func setPaused(_ paused: Bool) {
        pauseItem.title = paused ? "恢复监控" : "暂停监控"
    }

    @objc private func handleTogglePause() { actions.onTogglePause() }
    @objc private func handleToggleDebug() { actions.onToggleDebugOverlay() }
}
