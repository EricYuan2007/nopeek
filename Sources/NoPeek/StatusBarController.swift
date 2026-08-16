import AppKit

/// Owns the menu-bar status item: tri-color indicator + menu.
///
///   safe         green eye            monitoring / cooldown
///   suspicious   yellow eye           intruder frames seen, confirmation in progress
///   alert        red badge eye, 1 Hz pulse
///   paused       gray slashed eye     user paused
///   off          gray slashed eye     starting / locked / asleep
///   noPermission gray slashed eye     camera denied (extra menu item opens Settings)
@MainActor
final class StatusBarController {

    enum Indicator {
        case safe, suspicious, alert, paused, off, noPermission
    }

    struct Actions {
        var onTogglePause: () -> Void = {}
        var onToggleManualBlur: () -> Void = {}
        var onOpenSettings: () -> Void = {}
        var onOpenCameraPermission: () -> Void = {}
        var onToggleDebugOverlay: () -> Void = {}
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem()
    private let blurItem = NSMenuItem()
    private let permissionItem = NSMenuItem()
    private let actions: Actions

    private var pulseTimer: Timer?
    private var pulseDimmed = false
    private(set) var indicator: Indicator = .off

    init(actions: Actions) {
        self.actions = actions

        statusLineItem.isEnabled = false

        pauseItem.title = "暂停监控"
        pauseItem.keyEquivalent = "p"
        pauseItem.keyEquivalentModifierMask = [.command, .option]
        pauseItem.action = #selector(handleTogglePause)
        pauseItem.target = self

        blurItem.title = "立即模糊屏幕"
        blurItem.keyEquivalent = "b"
        blurItem.keyEquivalentModifierMask = [.command, .option]
        blurItem.action = #selector(handleToggleManualBlur)
        blurItem.target = self

        permissionItem.title = "摄像头未授权 — 打开系统设置"
        permissionItem.action = #selector(handleOpenCameraPermission)
        permissionItem.target = self
        permissionItem.isHidden = true

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(handleOpenSettings), keyEquivalent: ",")
        settingsItem.target = self

        let debugItem = NSMenuItem(title: "调试浮层", action: #selector(handleToggleDebug), keyEquivalent: "d")
        debugItem.target = self

        let quitItem = NSMenuItem(title: "退出 NoPeek",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")

        let menu = NSMenu()
        menu.addItem(statusLineItem)
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(blurItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(debugItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        setIndicator(.off)
    }

    // MARK: - Indicator

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
        permissionItem.isHidden = (newIndicator != .noPermission)

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

    // MARK: - Menu state

    func setStatusLine(_ text: String) {
        statusLineItem.title = text
    }

    func setPaused(_ paused: Bool) {
        pauseItem.title = paused ? "恢复监控" : "暂停监控"
    }

    func setManualBlurActive(_ active: Bool) {
        blurItem.state = active ? .on : .off
        blurItem.title = active ? "取消模糊" : "立即模糊屏幕"
    }

    // MARK: - Actions

    @objc private func handleTogglePause() { actions.onTogglePause() }
    @objc private func handleToggleManualBlur() { actions.onToggleManualBlur() }
    @objc private func handleOpenSettings() { actions.onOpenSettings() }
    @objc private func handleOpenCameraPermission() { actions.onOpenCameraPermission() }
    @objc private func handleToggleDebug() { actions.onToggleDebugOverlay() }
}
