import AppKit
import AVFoundation

/// The floating bubble: a 52pt circular always-on-top panel that mirrors the detection
/// state (colored ring), can be dragged anywhere, docks to screen edges (auto-shrinking
/// to a sliver when idle, sliding back on hover), and clicks open into a card with a
/// live preview + quick actions. Right-click pins it in place.
///
/// Level is `.statusBar` — deliberately BELOW the privacy shield's `.screenSaver`, so
/// an onlooker never sees the camera feed while the shield is up.
@MainActor
final class FloatingPanelController {

    struct Actions {
        var onTogglePause: () -> Void = {}
        var onToggleManualBlur: () -> Void = {}
        var onOpenSettings: () -> Void = {}
    }

    private enum Edge { case left, right, top, bottom }
    private enum DockState: Equatable { case floating, docked(Edge), sliver(Edge) }

    private static let bubbleSize: CGFloat = 52
    private static let dockedVisible: CGFloat = 12
    private static let sliverVisible: CGFloat = 6
    private static let edgeSnapDistance: CGFloat = 28
    private static let expandedSize = NSSize(width: 300, height: 230)

    private let actions: Actions
    private let settings = SettingsStore.shared

    private var panel: NSPanel?
    private var bubbleView: BubbleView?
    private var cardView: NSView?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var pausedOverlay: NSTextField?
    private var cardTitle: NSTextField?

    private var session: AVCaptureSession?
    private var dockState: DockState = .floating
    private var expanded = false
    private var indicator: StatusBarController.Indicator = .off
    private var cameraRunning = false

    private var idleTimer: Timer?
    private var collapseTimer: Timer?
    private var outsideClickMonitor: Any?

    init(actions: Actions) {
        self.actions = actions
    }

    // MARK: - External state

    func attach(session: AVCaptureSession) {
        self.session = session
    }

    func setIndicator(_ indicator: StatusBarController.Indicator) {
        self.indicator = indicator
        let color: NSColor
        switch indicator {
        case .safe: color = .systemGreen
        case .suspicious: color = .systemYellow
        case .alert: color = .systemRed
        case .paused, .off, .noPermission: color = .systemGray
        }
        bubbleView?.setState(color, pulsing: indicator == .alert)
        cardTitle?.stringValue = titleForIndicator()
    }

    func setCameraRunning(_ running: Bool) {
        cameraRunning = running
        pausedOverlay?.isHidden = running
    }

    /// Settings toggle — show/hide the bubble.
    func applyVisibility() {
        if settings.bubbleVisible {
            if panel == nil { createPanel() }
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func titleForIndicator() -> String {
        switch indicator {
        case .safe: return "监控中，一切正常"
        case .suspicious: return "检测到动静…"
        case .alert: return "⚠️ 有人正在窥屏！"
        case .paused: return "已暂停"
        case .off: return "未运行"
        case .noPermission: return "无摄像头权限"
        }
    }

    // MARK: - Panel creation

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: initialOrigin(), size: NSSize(width: Self.bubbleSize, height: Self.bubbleSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false // manual drag math — isMovableByWindowBackground swallows clicks

        let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: Self.bubbleSize, height: Self.bubbleSize)))
        panel.contentView = container

        let bubble = BubbleView(frame: container.bounds)
        bubble.onClick = { [weak self] in self?.expand() }
        bubble.onDragStart = { [weak self] in self?.didDragStart() }
        bubble.onDragEnd = { [weak self] in self?.didDragEnd() }
        bubble.onRightClick = { [weak self] event in self?.showContextMenu(with: event) }
        bubble.onHoverChange = { [weak self] hovering in self?.didHover(hovering) }
        container.addSubview(bubble)
        bubbleView = bubble
        bubble.setState(.systemGray, pulsing: false)

        self.panel = panel
        setIndicator(indicator)
        Log.ui.info("floating bubble created")
    }

    private func initialOrigin() -> NSPoint {
        // Restore persisted position, clamped onto a visible screen.
        if !settings.bubbleX.isNaN, !settings.bubbleY.isNaN {
            let point = NSPoint(x: settings.bubbleX, y: settings.bubbleY)
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(point) }) {
                return clamped(point, to: screen, size: Self.bubbleSize)
            }
        }
        // Default: bottom-right of the main screen with a comfortable margin.
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: visible.maxX - Self.bubbleSize - 24, y: visible.minY + 24)
    }

    private func clamped(_ origin: NSPoint, to screen: NSScreen, size: CGFloat) -> NSPoint {
        let vf = screen.visibleFrame
        return NSPoint(x: min(max(origin.x, vf.minX), vf.maxX - size),
                       y: min(max(origin.y, vf.minY), vf.maxY - size))
    }

    // MARK: - Drag & edge docking

    private func didDragStart() {
        guard let panel, dockState != .floating else { return }
        // Pop back to full size so the drag grabs a fully-visible bubble.
        let edge = currentEdge()
        idleTimer?.invalidate()
        moveToEdge(edge, visible: Self.bubbleSize, animated: false)
        dockState = .floating
        _ = panel
    }

    private func didDragEnd() {
        persistPosition()
        guard !settings.bubblePinned, let panel else {
            dockState = .floating
            return
        }
        guard let screen = screenUnderPanel() else { return }
        let vf = screen.visibleFrame
        let f = panel.frame
        let candidates: [(Edge, CGFloat)] = [
            (.left, f.minX - vf.minX), (.right, vf.maxX - f.maxX),
            (.bottom, f.minY - vf.minY), (.top, vf.maxY - f.maxY),
        ]
        if let (edge, distance) = candidates.min(by: { $0.1 < $1.1 }), distance <= Self.edgeSnapDistance {
            dock(to: edge)
        } else {
            dockState = .floating
        }
    }

    private func currentEdge() -> Edge {
        switch dockState {
        case .floating: return .right // unused — only called when docked/sliver
        case .docked(let edge), .sliver(let edge): return edge
        }
    }

    private func dock(to edge: Edge) {
        dockState = .docked(edge)
        moveToEdge(edge, visible: Self.dockedVisible, animated: true)
        // Shrink to a sliver after 3 s idle.
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .docked(let edge) = self.dockState else { return }
                self.dockState = .sliver(edge)
                self.moveToEdge(edge, visible: Self.sliverVisible, animated: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func didHover(_ hovering: Bool) {
        guard !settings.bubblePinned || hovering else { return }
        if hovering {
            idleTimer?.invalidate()
            switch dockState {
            case .docked(let edge), .sliver(let edge):
                moveToEdge(edge, visible: Self.bubbleSize, animated: true)
            case .floating:
                break
            }
        } else {
            switch dockState {
            case .docked(let edge):
                moveToEdge(edge, visible: Self.dockedVisible, animated: true)
                dock(to: edge) // re-arm the idle → sliver timer
            case .sliver(let edge):
                moveToEdge(edge, visible: Self.sliverVisible, animated: true)
            case .floating:
                break
            }
        }
    }

    /// Positions the panel so `visible` points of it peek out from `edge` of its screen.
    private func moveToEdge(_ edge: Edge, visible: CGFloat, animated: Bool) {
        guard let panel, let screen = screenUnderPanel() else { return }
        let vf = screen.visibleFrame
        var f = panel.frame
        let hidden = Self.bubbleSize - visible
        switch edge {
        case .left: f.origin.x = vf.minX - hidden
        case .right: f.origin.x = vf.maxX - visible
        case .bottom: f.origin.y = vf.minY - hidden
        case .top: f.origin.y = vf.maxY - visible
        }
        panel.setFrame(f, display: true, animate: animated)
    }

    private func screenUnderPanel() -> NSScreen? {
        guard let panel else { return nil }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
    }

    private func persistPosition() {
        guard let panel else { return }
        settings.bubbleX = Double(panel.frame.origin.x)
        settings.bubbleY = Double(panel.frame.origin.y)
    }

    // MARK: - Context menu (right-click)

    private func showContextMenu(with event: NSEvent) {
        guard let bubbleView else { return }
        let menu = NSMenu()
        let pinItem = NSMenuItem(title: settings.bubblePinned ? "取消固定" : "固定在原位",
                                 action: #selector(togglePinned), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)
        let hideItem = NSMenuItem(title: "隐藏悬浮窗", action: #selector(hideBubble), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)
        NSMenu.popUpContextMenu(menu, with: event, for: bubbleView)
    }

    @objc private func togglePinned() {
        settings.bubblePinned.toggle()
        if !settings.bubblePinned, case .floating = dockState {
            // Unpinning leaves the bubble where it is until the next drag.
        }
    }

    @objc private func hideBubble() {
        settings.bubbleVisible = false
    }

    // MARK: - Expanded card

    private func expand() {
        guard let panel, !expanded else { return }
        expanded = true
        idleTimer?.invalidate()

        buildCardIfNeeded()
        cardView?.isHidden = false
        bubbleView?.isHidden = true
        cardTitle?.stringValue = titleForIndicator()
        pausedOverlay?.isHidden = cameraRunning

        var frame = NSRect(origin: .zero, size: Self.expandedSize)
        frame.origin = NSPoint(x: panel.frame.midX - frame.width / 2,
                               y: panel.frame.midY - frame.height / 2)
        if let screen = screenUnderPanel() {
            let vf = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, vf.minX + 8), vf.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.origin.y, vf.minY + 8), vf.maxY - frame.height - 8)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().setFrame(frame, display: true)
        }

        // Auto-collapse after 15 s, or on any click delivered to another app.
        let timer = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.collapse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        collapseTimer = timer
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.collapse() }
        }
    }

    private func collapse() {
        guard expanded, let panel else { return }
        expanded = false
        collapseTimer?.invalidate()
        collapseTimer = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }

        var frame = panel.frame
        frame.origin.x += (frame.width - Self.bubbleSize) / 2
        frame.origin.y += (frame.height - Self.bubbleSize) / 2
        frame.size = NSSize(width: Self.bubbleSize, height: Self.bubbleSize)
        bubbleView?.isHidden = false
        cardView?.isHidden = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func buildCardIfNeeded() {
        guard cardView == nil, let panel, let container = panel.contentView else { return }

        let card = NSView(frame: NSRect(origin: .zero, size: Self.expandedSize))
        card.wantsLayer = true
        card.isHidden = true

        let effect = NSVisualEffectView(frame: card.bounds)
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        card.addSubview(effect)

        // Live preview (user-invoked only — the app's standing promise is no preview
        // on screen unless the user explicitly opens it).
        let previewHeight = Self.expandedSize.width * 9 / 16
        let previewContainer = NSView(frame: NSRect(x: 0, y: Self.expandedSize.height - previewHeight,
                                                    width: Self.expandedSize.width, height: previewHeight))
        previewContainer.wantsLayer = true
        if let session {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = previewContainer.bounds
            previewContainer.layer?.addSublayer(preview)
            previewLayer = preview
        }
        let paused = NSTextField(labelWithString: "监控已暂停")
        paused.textColor = .white
        paused.font = .systemFont(ofSize: 13, weight: .medium)
        paused.alignment = .center
        paused.frame = previewContainer.bounds
        paused.isHidden = cameraRunning
        previewContainer.addSubview(paused)
        pausedOverlay = paused
        effect.addSubview(previewContainer)

        let title = NSTextField(labelWithString: titleForIndicator())
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: Self.expandedSize.height - previewHeight - 28,
                             width: Self.expandedSize.width, height: 20)
        effect.addSubview(title)
        cardTitle = title

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually
        buttonRow.frame = NSRect(x: 12, y: 10, width: Self.expandedSize.width - 24, height: 26)

        let pauseButton = NSButton(title: "暂停/继续", target: self, action: #selector(handlePauseButton))
        let blurButton = NSButton(title: "模糊屏幕", target: self, action: #selector(handleBlurButton))
        let settingsButton = NSButton(title: "设置…", target: self, action: #selector(handleSettingsButton))
        [pauseButton, blurButton, settingsButton].forEach {
            $0.bezelStyle = .rounded
            $0.font = .systemFont(ofSize: 12)
            buttonRow.addArrangedSubview($0)
        }
        effect.addSubview(buttonRow)

        container.addSubview(card)
        card.frame = container.bounds
        card.autoresizingMask = [.width, .height]
        cardView = card
    }

    @objc private func handlePauseButton() { actions.onTogglePause() }
    @objc private func handleBlurButton() { actions.onToggleManualBlur() }
    @objc private func handleSettingsButton() {
        collapse()
        actions.onOpenSettings()
    }
}

// MARK: - BubbleView

/// The circular bubble: vibrancy disc + colored state ring + eye glyph.
/// Handles its own mouse events (manual drag math, click, right-click, hover).
@MainActor
private final class BubbleView: NSView {

    var onClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private let ringLayer = CAShapeLayer()
    private let discLayer = CAShapeLayer()
    private let eyeView: NSImageView
    private var dragStartMouse: NSPoint?
    private var windowOriginStart: NSPoint?
    private var dragging = false

    override init(frame frameRect: NSRect) {
        eyeView = NSImageView(image: NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil) ?? NSImage())
        super.init(frame: frameRect)
        wantsLayer = true

        // Self-drawn translucent disc — NOT NSVisualEffectView: neither cornerRadius
        // nor maskImage reliably clips that view's private material on recent macOS
        // (the blur kept rendering as a rounded rect). A CAShapeLayer ellipse is
        // circular BY CONSTRUCTION, so the rectangle can never come back. Alpha 0.92
        // keeps a frosted feel against the wallpaper.
        discLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        discLayer.frame = bounds
        layer?.addSublayer(discLayer)
        updateDiscColor()

        // State ring follows the circle edge.
        let inset: CGFloat = 2
        ringLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 3.5
        ringLayer.frame = bounds
        layer?.addSublayer(ringLayer)

        // Subtle drop shadow. Without an explicit shadowPath the empty backing layer
        // casts a SQUARE shadow (a visible rectangular halo around the circle) —
        // pin it to the circle's outline instead.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 6
        layer?.shadowOffset = .zero
        layer?.shadowPath = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)

        let symbolSize: CGFloat = 22
        eyeView.frame = NSRect(x: (frameRect.width - symbolSize) / 2, y: (frameRect.height - symbolSize) / 2,
                               width: symbolSize, height: symbolSize)
        eyeView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(eyeView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Theme-adaptive disc: near-white in light mode, dark gray in dark mode.
    private func updateDiscColor() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        discLayer.fillColor = NSColor(white: dark ? 0.17 : 0.97, alpha: 0.92).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDiscColor()
    }

    /// State color drives BOTH the ring and the eye glyph (menu-bar parity);
    /// alert additionally pulses the ring at ~1 Hz like the status item.
    func setState(_ color: NSColor, pulsing: Bool) {
        ringLayer.strokeColor = color.cgColor
        eyeView.contentTintColor = color
        if pulsing, ringLayer.animation(forKey: "pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.5
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            ringLayer.add(pulse, forKey: "pulse")
        } else if !pulsing {
            ringLayer.removeAnimation(forKey: "pulse")
            ringLayer.opacity = 1
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        windowOriginStart = window?.frame.origin
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = dragStartMouse, let startOrigin = windowOriginStart else { return }
        let now = NSEvent.mouseLocation
        let delta = NSPoint(x: now.x - startMouse.x, y: now.y - startMouse.y)
        if !dragging && hypot(delta.x, delta.y) > 4 {
            dragging = true
            onDragStart?()
            // didDragStart may have moved the window (un-docking) — re-anchor.
            dragStartMouse = now
            windowOriginStart = window?.frame.origin
            return
        }
        if dragging {
            window?.setFrameOrigin(NSPoint(x: startOrigin.x + delta.x, y: startOrigin.y + delta.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartMouse = nil
            windowOriginStart = nil
            dragging = false
        }
        if dragging {
            onDragEnd?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}
