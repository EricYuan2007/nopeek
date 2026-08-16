import AppKit

/// Full-screen frosted-glass privacy shield: one borderless window per display at
/// `.screenSaver` level (covers the menu bar and full-screen apps), click-through
/// (`ignoresMouseEvents` — a visual shield, not an input blockade).
///
/// Visibility is driven by a set of sources: `.auto` (detection) and `.manual`
/// ("Blur Now" menu toggle) are independent — the shield stays up until EVERY
/// source releases it, so auto-clear never dismisses a deliberate manual shield.
@MainActor
final class PrivacyBlurController {

    enum Source: String {
        case auto, manual
    }

    private var windows: [NSWindow] = []
    private var sources = Set<Source>()
    private var screenObserver: NSObjectProtocol?

    var isVisible: Bool { !windows.isEmpty }

    func show(source: Source) {
        let wasEmpty = sources.isEmpty
        sources.insert(source)
        guard wasEmpty else { return }
        buildWindows()
        Log.alert.info("privacy shield ON (source=\(source.rawValue, privacy: .public))")
    }

    func hide(source: Source) {
        sources.remove(source)
        guard sources.isEmpty, !windows.isEmpty else { return }
        tearDown(animated: true)
        Log.alert.info("privacy shield OFF (source=\(source.rawValue, privacy: .public))")
    }

    // MARK: - Window lifecycle

    private func buildWindows() {
        for screen in NSScreen.screens {
            windows.append(makeWindow(for: screen))
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            windows.forEach { $0.animator().alphaValue = 1 }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    /// Displays hot-plugged/resized while the shield is up — rebuild to cover them.
    private func rebuild() {
        guard !sources.isEmpty else { return }
        tearDown(animated: false)
        buildWindows()
    }

    private func tearDown(animated: Bool) {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        let old = windows
        windows = []
        for window in old {
            if animated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.15
                    window.animator().alphaValue = 0
                }, completionHandler: {
                    // AppKit animation completions run on the main thread.
                    MainActor.assumeIsolated { window.orderOut(nil) }
                })
            } else {
                window.orderOut(nil)
            }
        }
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 0

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active

        let label = NSTextField(labelWithString: "⚠️ NoPeek 隐私盾\n检测到身后有人窥屏，屏幕已临时遮挡\n\n⌥⌘B 手动模糊开关 · ⌥⌘P 暂停监控")
        label.textColor = .white
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])

        window.contentView = effect
        window.orderFrontRegardless()
        return window
    }
}
