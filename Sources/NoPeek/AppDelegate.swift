import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let cameraManager = CameraManager()
    private let faceAnalyzer = FaceAnalyzer()
    private let debugOverlay = DebugOverlayController()

    /// Whether monitoring is desired by the user (M4: driven by SettingsStore).
    private var monitoringWanted = true
    /// Whether the camera is currently allowed to run (not locked / not asleep).
    private var lifecycleActive = true
    /// For the once-per-second detection summary log.
    private var observationCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("NoPeek launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "NoPeek")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "NoPeek 运行中", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "调试浮层", action: #selector(toggleDebugOverlay), keyEquivalent: "d"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 NoPeek",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu

        // Camera frames (camera queue) → Vision analysis (same queue) → observations
        // hop to MainActor for UI/state.
        cameraManager.onFrame = { [faceAnalyzer] buffer, timestamp in
            faceAnalyzer.analyze(buffer, timestamp: timestamp)
        }
        faceAnalyzer.onObservation = { [weak self] observation in
            DispatchQueue.main.async { self?.handle(observation) }
        }
        cameraManager.onStateChange = { state in
            Log.camera.info("camera state → \(state.rawValue)")
        }

        registerLifecycleObservers()
        requestCameraAndStart()
    }

    // MARK: - Per-frame observation (MainActor)

    private func handle(_ observation: FrameObservation) {
        debugOverlay.update(observation)

        observationCount += 1
        if observationCount % 10 == 0 {
            let summary = observation.faces.map { face in
                let yaw = face.yawRad.map { String(format: "%.0f°", $0 * 180 / .pi) } ?? "?"
                return "#\(face.trackID)(a=\(String(format: "%.4f", face.area)),yaw=\(yaw),q=\(String(format: "%.2f", face.quality))\(face.isStaticSuspect ? ",S" : ""))"
            }.joined(separator: " ")
            // Geometry only (areas/angles/quality) — never image data. Public so the
            // numbers are visible for threshold calibration with `make log`.
            Log.detection.debug("faces=\(observation.faces.count) \(summary, privacy: .public)")
        }
    }

    @objc private func toggleDebugOverlay() {
        debugOverlay.toggle(session: cameraManager.captureSession)
    }

    // MARK: - Camera bring-up

    private func requestCameraAndStart() {
        Task {
            let granted = await cameraManager.requestAccess()
            if granted {
                cameraManager.start()
            } else {
                Log.app.warning("camera not authorized — monitoring inactive")
                // M3/M4: reflect noPermission state in the UI + settings deep link.
            }
        }
    }

    // MARK: - Lock / sleep lifecycle
    // The camera LED is the honest privacy signal: stop capturing the moment the user
    // locks the screen or the Mac sleeps, resume when they return.

    private func registerLifecycleObservers() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLifecycleActive(false) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLifecycleActive(true) }
        }
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLifecycleActive(false) }
        }
        wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLifecycleActive(true) }
        }
    }

    private func setLifecycleActive(_ active: Bool) {
        lifecycleActive = active
        Log.app.info("lifecycle active=\(active)")
        updateCameraRunState()
    }

    private func updateCameraRunState() {
        if monitoringWanted && lifecycleActive {
            cameraManager.start()
        } else {
            cameraManager.stop()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        // Process exit tears the session down even if the async stop doesn't land in time.
    }
}
