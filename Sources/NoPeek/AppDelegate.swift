import AppKit
import AVFoundation
import Carbon.HIToolbox
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private let cameraManager = CameraManager()
    private let faceAnalyzer = FaceAnalyzer()
    private let debugOverlay = DebugOverlayController()
    private let alertManager = AlertManager()
    private let settingsWindow = SettingsWindowController()
    private let settings = SettingsStore.shared
    private let hotKeys = GlobalHotKey()
    private var floatingBubble: FloatingPanelController!
    private let onboarding = OnboardingWindowController()
    private let ownerMatcher = OwnerMatcher()
    private lazy var stateMachine = DetectionStateMachine(config: Self.makeConfig(from: settings))

    /// Whether the camera is currently allowed to run (not locked / not asleep).
    private var lifecycleActive = true
    private var permissionGranted = false
    private var lastFaceCount = 0
    /// For the once-per-second detection summary log.
    private var observationCount = 0
    /// Owner-absence protection bookkeeping. Timestamps share the host-time base
    /// (capture PTS == CACurrentMediaTime epoch).
    private var lastOwnerSeenAt: TimeInterval?
    private var cameraStartedAt: TimeInterval?
    private var ownerAbsentBlurActive = false
    private var absenceTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("NoPeek launched")

        statusBar = StatusBarController(actions: .init(
            onTogglePause: { [weak self] in self?.togglePause() },
            onToggleManualBlur: { [weak self] in self?.toggleManualBlur() },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() },
            onOpenCameraPermission: { [weak self] in self?.openCameraPermissionSettings() },
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
            self?.handleStateTransition(from: from, to: to, trigger: trigger)
        }

        settings.onChange = { [weak self] in self?.applySettings() }

        // V2 owner recognition: load enrolled prints from the Keychain, wire the
        // matcher into the analyzer, and let the settings UI drive enrollment.
        ownerMatcher.loadFromStore()
        faceAnalyzer.ownerMatcher = ownerMatcher
        EnrollmentController.shared.configure(session: cameraManager.captureSession,
                                              analyzer: faceAnalyzer,
                                              matcher: ownerMatcher)

        floatingBubble = FloatingPanelController(actions: .init(
            onTogglePause: { [weak self] in self?.togglePause() },
            onToggleManualBlur: { [weak self] in self?.toggleManualBlur() },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() }
        ))
        floatingBubble.attach(session: cameraManager.captureSession)
        floatingBubble.applyVisibility()

        // Push persisted settings into the pipeline once at launch (stateMachine got
        // its config via lazy init; this also covers eco FPS + identity threshold).
        applySettings()

        // Global escape hatches — crucial when the shield frosts the whole screen.
        hotKeys.register([
            .init(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
                self?.toggleManualBlur()
            },
            .init(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
                self?.togglePause()
            },
        ])

        registerLifecycleObservers()

        // Owner-absence check, once per second (guard conditions inside).
        let absenceTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkOwnerAbsence() }
        }
        RunLoop.main.add(absenceTimer, forMode: .common)
        self.absenceTimer = absenceTimer

        // First run (or camera still denied): explain before asking for the camera.
        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let cameraDenied = AVCaptureDevice.authorizationStatus(for: .video) == .denied
            || AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        if !hasOnboarded || cameraDenied {
            onboarding.onFinished = { [weak self] in
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                self?.requestCameraAndStart()
            }
            onboarding.show()
        } else {
            requestCameraAndStart()
        }
        refreshUI()
    }

    // MARK: - Settings → pipeline push

    private static func makeConfig(from settings: SettingsStore) -> DetectionConfig {
        var config = DetectionConfig()
        config.minIntruderArea = settings.minIntruderArea
        config.requireKnownPose = settings.strictPoseMode
        config.suppressStaticFaces = settings.suppressStaticFaces
        config.ownerRecognitionEnabled = settings.ownerRecognitionEnabled
        config.ownerMaxDistance = Float(settings.ownerMaxDistance)
        if settings.strictPoseMode {
            config.maxYawRad = 25 * .pi / 180
            config.maxPitchRad = 20 * .pi / 180
        }
        return config
    }

    private func applySettings() {
        stateMachine.updateConfig(Self.makeConfig(from: settings))
        cameraManager.analysisFPS = settings.ecoMode ? 6 : 10
        faceAnalyzer.ownerMaxDistance = Float(settings.ownerMaxDistance)
        floatingBubble.applyVisibility()
        updateCameraRunState()
    }

    /// Burst mode: the steady state analyzes at 10 fps (6 eco), but the moment
    /// something interesting happens — any intruder candidate, a second face, or a
    /// non-idle state — every sensor frame (15 fps, the hardware cap) is analyzed.
    /// Confirmation latency drops to ~0.2 s exactly when it matters; idle power
    /// stays untouched.
    private func updateAnalysisRate(faces: Int, intruders: Int) {
        let engaged = intruders > 0 || faces >= 2
            || stateMachine.state == .suspicious || stateMachine.state == .alert
            || stateMachine.state == .cooldown
        let base: Double = settings.ecoMode ? 6 : 10
        let target = engaged ? 15 : base
        if cameraManager.analysisFPS != target {
            cameraManager.analysisFPS = target
            Log.detection.debug("analysis rate → \(target, privacy: .public) fps (engaged=\(engaged))")
        }
    }

    // MARK: - Per-frame observation (MainActor)

    private func handle(_ observation: FrameObservation) {
        debugOverlay.update(observation)
        lastFaceCount = observation.faces.count

        let assessment = IntruderAssessor.assess(faces: observation.faces,
                                                 config: Self.makeConfig(from: settings))
        stateMachine.handle(assessment, at: observation.timestamp)
        updateAnalysisRate(faces: observation.faces.count, intruders: assessment.intruders.count)

        // Owner-absence tracking: owner seen → remember + drop the absence shield.
        if assessment.owner != nil {
            lastOwnerSeenAt = observation.timestamp
            if ownerAbsentBlurActive { clearOwnerAbsentBlur() }
        }

        observationCount += 1
        if observationCount % 10 == 0 {
            let summary = observation.faces.map { face in
                let yaw = face.yawRad.map { String(format: "%.0f°", $0 * 180 / .pi) } ?? "?"
                let distance = face.ownerDistance.map { String(format: ",d=%.2f", $0) } ?? ""
                return "#\(face.trackID)(a=\(String(format: "%.4f", face.area)),yaw=\(yaw),q=\(String(format: "%.2f", face.quality))\(distance)\(face.isStaticSuspect ? ",S" : ""))"
            }.joined(separator: " ")
            // Geometry only (areas/angles/quality) — never image data. Public so the
            // numbers are visible for threshold calibration with `make log`.
            Log.detection.debug("faces=\(observation.faces.count) \(summary, privacy: .public)")
        }
        refreshStatusLine()
    }

    // MARK: - State transitions → alerts

    private func handleStateTransition(from: DetectionState, to: DetectionState, trigger: Assessment?) {
        if to == .alert {
            // Log the triggering faces (geometry/identity numbers only, never image
            // data) so every alert episode is self-diagnosing from `make log` output.
            let detail = (trigger?.intruders ?? []).map { face in
                let yaw = face.yawRad.map { String(format: "%.0f°", $0 * 180 / .pi) } ?? "?"
                let distance = face.ownerDistance.map { String(format: "%.2f", $0) } ?? "nil"
                let verdict = face.isOwner.map { $0 ? "owner" : "stranger" } ?? "?"
                return "#\(face.trackID)(a=\(String(format: "%.4f", face.area)),yaw=\(yaw),q=\(String(format: "%.2f", face.quality)),d=\(distance),id=\(verdict)\(face.isStaticSuspect ? ",S" : ""))"
            }.joined(separator: " ")
            Log.alert.info("ALERT — intruders=\(trigger?.intruders.count ?? 0) \(detail, privacy: .public)")
            alertManager.alertStarted()
        } else if from == .alert {
            alertManager.alertEnded()
        }
        if to == .off {
            alertManager.alertEnded() // safety: leaving alert via disable
        }
        refreshUI()
    }

    private func handleCameraState(_ state: CameraManager.State) {
        if state == .running {
            stateMachine.notifyCameraRunning()
            cameraStartedAt = CACurrentMediaTime()
            lastOwnerSeenAt = nil
        }
        floatingBubble.setCameraRunning(state == .running)
        refreshUI()
    }

    // MARK: - Owner-absence protection (人一走就模糊)

    private func checkOwnerAbsence() {
        let monitoringLive = permissionGranted && settings.monitoringEnabled && lifecycleActive
            && stateMachine.state != .off && stateMachine.state != .starting
        guard settings.ownerAbsentBlurEnabled, monitoringLive else {
            if ownerAbsentBlurActive { clearOwnerAbsentBlur() }
            return
        }
        let now = CACurrentMediaTime()
        // Never-seen-owner counts from camera start (grace period covers startup).
        let reference = lastOwnerSeenAt ?? cameraStartedAt ?? now
        let absentFor = now - reference
        guard absentFor >= settings.ownerAbsentDelaySeconds else { return }
        guard !ownerAbsentBlurActive else { return }
        ownerAbsentBlurActive = true
        alertManager.setOwnerAbsentBlur(true)
        Log.alert.info("owner-absent shield ON (no owner for \(String(format: "%.1f", absentFor), privacy: .public)s)")
    }

    private func clearOwnerAbsentBlur() {
        ownerAbsentBlurActive = false
        alertManager.setOwnerAbsentBlur(false)
        Log.alert.info("owner-absent shield OFF")
    }

    // MARK: - UI refresh

    private func refreshUI() {
        let indicator: StatusBarController.Indicator
        if !permissionGranted {
            indicator = .noPermission
        } else if !settings.monitoringEnabled {
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
                // Visual alert is itself a toggleable output.
                indicator = settings.alertVisual ? .alert : .safe
            }
        }
        statusBar.setIndicator(indicator)
        statusBar.setPaused(!settings.monitoringEnabled)
        statusBar.setManualBlurActive(alertManager.manualBlurActive)
        floatingBubble.setIndicator(indicator)
        refreshStatusLine()
    }

    private func refreshStatusLine() {
        let text: String
        if !permissionGranted {
            text = "无摄像头权限"
        } else if !settings.monitoringEnabled {
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
        settings.monitoringEnabled.toggle()
        Log.app.info("monitoring enabled=\(self.settings.monitoringEnabled)")
        // SettingsStore.onChange → applySettings → updateCameraRunState.
    }

    private func toggleManualBlur() {
        alertManager.toggleManualBlur()
        refreshUI()
    }

    private func toggleDebugOverlay() {
        debugOverlay.toggle(session: cameraManager.captureSession,
                            videoSize: cameraManager.activeVideoSize)
        faceAnalyzer.verboseAnalysis = debugOverlay.isVisible
    }

    private func openCameraPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Camera bring-up

    private func requestCameraAndStart() {
        Task {
            let granted = await cameraManager.requestAccess()
            permissionGranted = granted
            if !granted {
                Log.app.warning("camera not authorized — monitoring inactive")
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
        let shouldRun = settings.monitoringEnabled && lifecycleActive && permissionGranted
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
