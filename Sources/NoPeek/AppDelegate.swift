import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private let cameraManager = CameraManager()
    private let faceAnalyzer = FaceAnalyzer()
    private let debugOverlay = DebugOverlayController()
    private let detectionConfig = DetectionConfig()
    private lazy var stateMachine = DetectionStateMachine(config: detectionConfig)

    /// Whether monitoring is desired by the user (M4: driven by SettingsStore).
    private var monitoringWanted = true
    /// Whether the camera is currently allowed to run (not locked / not asleep).
    private var lifecycleActive = true
    private var permissionGranted = false
    private var lastFaceCount = 0
    /// For the once-per-second detection summary log.
    private var observationCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("NoPeek launched")

        statusBar = StatusBarController(actions: .init(
            onTogglePause: { [weak self] in self?.togglePause() },
            onToggleDebugOverlay: { [weak self] in self?.toggleDebugOverlay() }
        ))

        // Camera frames (camera queue) → Vision analysis (same queue) → observations
        // hop to MainActor for assessment, state machine, and UI.
        cameraManager.onFrame = { [faceAnalyzer] buffer, timestamp in
            faceAnalyzer.analyze(buffer, timestamp: timestamp)
        }
        faceAnalyzer.onObservation = { [weak self] observation in
            DispatchQueue.main.async { self?.handle(observation) }
        }
        cameraManager.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleCameraState(state) }
        }

        stateMachine.onTransition = { [weak self] from, to, trigger in
            // Fired synchronously from handle(_:) — already on MainActor.
            Log.detection.info("state \(from.rawValue, privacy: .public) → \(to.rawValue, privacy: .public)")
            self?.handleStateTransition(to: to, trigger: trigger)
        }

        registerLifecycleObservers()
        requestCameraAndStart()
        refreshUI()
    }

    // MARK: - Per-frame observation (MainActor)

    private func handle(_ observation: FrameObservation) {
        debugOverlay.update(observation)
        lastFaceCount = observation.faces.count

        let assessment = IntruderAssessor.assess(faces: observation.faces, config: detectionConfig)
        stateMachine.handle(assessment, at: observation.timestamp)

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
        refreshStatusLine()
    }

    // MARK: - State transitions

    private func handleStateTransition(to state: DetectionState, trigger: Assessment?) {
        if state == .alert, let trigger {
            Log.alert.info("ALERT — intruders=\(trigger.intruders.count)")
        }
        refreshUI()
        // M4: AlertManager.alertStarted / alertEnded hook in here.
    }

    private func handleCameraState(_ state: CameraManager.State) {
        if state == .running {
            stateMachine.notifyCameraRunning()
        }
        if state == .error {
            Log.camera.error("camera error — indicator off")
        }
        refreshUI()
    }

    // MARK: - UI refresh

    private func refreshUI() {
        let indicator: StatusBarController.Indicator
        if !permissionGranted {
            indicator = .noPermission
        } else if !monitoringWanted {
            indicator = .paused
        } else {
            switch stateMachine.state {
            case .off, .starting:
                indicator = .off
            case .monitoring, .cooldown:
                indicator = .safe
            case .suspicious:
                indicator = .suspicious
            case .alert:
                indicator = .alert
            }
        }
        statusBar.setIndicator(indicator)
        statusBar.setPaused(!monitoringWanted)
        refreshStatusLine()
    }

    private func refreshStatusLine() {
        let text: String
        if !permissionGranted {
            text = "无摄像头权限"
        } else if !monitoringWanted {
            text = "已暂停"
        } else {
            switch stateMachine.state {
            case .off: text = "未运行"
            case .starting: text = "启动中…"
            case .monitoring: text = "监控中 · \(lastFaceCount) 张人脸"
            case .suspicious: text = "检测到动静…"
            case .alert: text = "⚠️ 有人正在窥屏！"
            case .cooldown: text = "监控中（冷却）· \(lastFaceCount) 张人脸"
            }
        }
        statusBar.setStatusLine(text)
    }

    // MARK: - Actions

    private func togglePause() {
        monitoringWanted.toggle()
        Log.app.info("monitoring wanted=\(self.monitoringWanted)")
        updateCameraRunState()
    }

    private func toggleDebugOverlay() {
        debugOverlay.toggle(session: cameraManager.captureSession)
    }

    // MARK: - Camera bring-up

    private func requestCameraAndStart() {
        Task {
            let granted = await cameraManager.requestAccess()
            permissionGranted = granted
            if !granted {
                Log.app.warning("camera not authorized — monitoring inactive")
                // M4: settings deep link in the status menu.
            }
            updateCameraRunState()
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
        let shouldRun = monitoringWanted && lifecycleActive && permissionGranted
        stateMachine.setEnabled(shouldRun)
        if shouldRun {
            cameraManager.start()
        } else {
            cameraManager.stop()
        }
        refreshUI()
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        // Process exit tears the session down even if the async stop doesn't land in time.
    }
}
