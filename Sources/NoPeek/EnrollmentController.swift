import AppKit
import AVFoundation
import SwiftUI
import Vision

/// Owner enrollment: a guided capture flow. Problems with the old one-shot version:
/// sampling started the instant the window opened (before the user had reacted), and
/// 8 near-identical frontal samples covered too little appearance space — the matcher
/// then misjudged the owner under everyday pose/lighting drift.
///
/// The guided flow instead:
///   1. counts down 3 s so the user is ready and framed (oval guide on the preview);
///   2. walks three phases with on-screen instructions — frontal ×4, slow left/right
///      turns ×6 (both directions required), slow nod/tilt ×2 — each sample gated by
///      the phase's pose range, capture quality, and (phase 0) face centering/size;
///   3. paces captures (~0.35 s) so samples differ; per-phase timeout advances with
///      whatever was captured; needs ≥4 samples total to save.
///
/// The capture itself runs on the camera queue (frames must not leave it); this
/// controller is MainActor and only receives progress updates.
@MainActor
final class EnrollmentController: ObservableObject {

    static let shared = EnrollmentController()

    enum State: Equatable {
        case idle
        case countdown(Int)
        case capturing(phase: Int, phaseCount: Int, collected: Int, target: Int)
        case done(Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var enrolledSampleCount = 0

    private var window: NSWindow?
    private var analyzer: FaceAnalyzer?
    private var session: AVCaptureSession?
    private var countdownTimer: Timer?
    private var phaseTimer: Timer?

    // MARK: - Capture plan (all state lives in the camera-queue lock-box)

    private struct Phase {
        let instruction: String
        let target: Int
        /// Camera-queue gate: does this frame's face qualify as a sample for the phase?
        let accepts: (_ yaw: Double?, _ pitch: Double?, _ quality: Float, _ box: CGRect) -> Bool
    }

    // nonisolated: referenced from collect() on the camera queue.
    nonisolated private static let pacing: TimeInterval = 0.35
    nonisolated private static let phaseTimeout: TimeInterval = 12
    nonisolated private static let minSamplesToSave = 4

    nonisolated private static func makePhases() -> [Phase] {
        [
            Phase(instruction: "正对屏幕，把脸放进椭圆框", target: 4) { yaw, pitch, quality, box in
                guard quality >= 0.30 else { return false }
                guard let yaw, abs(yaw) <= 0.21, let pitch, abs(pitch) <= 0.26 else { return false }
                // Framing gate: near-centered and close enough (≲1.2 m).
                let centerX = box.midX, centerY = box.midY
                return box.width * box.height >= 0.012
                    && (0.25...0.75).contains(centerX) && (0.2...0.85).contains(centerY)
            },
            Phase(instruction: "缓慢向左转头，再向右转头", target: 6) { yaw, _, quality, _ in
                guard quality >= 0.25, let yaw else { return false }
                let magnitude = abs(yaw)
                return magnitude > 0.21 && magnitude <= 0.70 // 12°…40°
            },
            Phase(instruction: "缓慢抬头，再低头", target: 2) { _, pitch, quality, _ in
                guard quality >= 0.25, let pitch else { return false }
                return abs(pitch) >= 0.17 // ≥10°
            },
        ]
    }

    /// Camera-queue confined capture state (all access under its lock).
    private final class CaptureContext: @unchecked Sendable {
        var matcher: OwnerMatcher?
        var prints: [VNFeaturePrintObservation] = []
        var phaseIndex = 0
        var phaseCollected = 0
        var yawPositive = 0 // phase 1 sign buckets — both directions must be covered
        var yawNegative = 0
        var lastCaptureAt: TimeInterval = 0
        let lock = NSLock()
    }
    nonisolated private let captureContext = CaptureContext()

    private init() {}

    func configure(session: AVCaptureSession, analyzer: FaceAnalyzer, matcher: OwnerMatcher) {
        self.session = session
        self.analyzer = analyzer
        captureContext.lock.lock()
        captureContext.matcher = matcher
        captureContext.lock.unlock()
        enrolledSampleCount = matcher.enrolled.count
    }

    // MARK: - Flow (MainActor)

    func start() {
        guard case .idle = state, let analyzer, let session else { return }
        resetCaptureContext()

        showWindow(session: session)
        analyzer.verboseAnalysis = true

        // Countdown BEFORE arming the collector — the user gets 3 s to settle into
        // the guide oval; no sample can be captured before they're ready.
        state = .countdown(3)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, case .countdown(let n) = self.state else { return }
                if n > 1 {
                    self.state = .countdown(n - 1)
                } else {
                    self.countdownTimer?.invalidate()
                    self.beginCapture()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func beginCapture() {
        guard let analyzer else { return }
        armPhaseTimer()
        state = .capturing(phase: 0, phaseCount: 0, collected: 0, target: Self.totalTarget)
        analyzer.enrollmentCollector = { [weak self] face, quality, handler in
            self?.collect(face: face, quality: quality, handler: handler)
        }
    }

    func cancel() {
        finishCapture(save: false)
    }

    func clearEnrollment() {
        OwnerStore.clear()
        captureContext.lock.lock()
        let matcher = captureContext.matcher
        captureContext.lock.unlock()
        matcher?.setEnrolled([])
        enrolledSampleCount = 0
        SettingsStore.shared.ownerRecognitionEnabled = false
        Log.detection.info("owner enrollment cleared")
    }

    nonisolated private static var totalTarget: Int { makePhases().reduce(0) { $0 + $1.target } }

    private func resetCaptureContext() {
        captureContext.lock.lock()
        captureContext.prints = []
        captureContext.phaseIndex = 0
        captureContext.phaseCollected = 0
        captureContext.yawPositive = 0
        captureContext.yawNegative = 0
        captureContext.lastCaptureAt = 0
        captureContext.lock.unlock()
    }

    /// Per-phase safety net: if the user can't hit a pose, advance with whatever was
    /// captured rather than trapping them in the flow.
    private func armPhaseTimer() {
        phaseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.phaseTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advancePhase() }
        }
        RunLoop.main.add(timer, forMode: .common)
        phaseTimer = timer
    }

    /// MainActor. Move to the next phase, or finish when the plan is done.
    private func advancePhase() {
        captureContext.lock.lock()
        let next = captureContext.phaseIndex + 1
        let total = captureContext.prints.count
        if next < Self.makePhases().count {
            captureContext.phaseIndex = next
            captureContext.phaseCollected = 0
            captureContext.yawPositive = 0
            captureContext.yawNegative = 0
        }
        captureContext.lock.unlock()

        if next < Self.makePhases().count {
            state = .capturing(phase: next, phaseCount: 0, collected: total, target: Self.totalTarget)
            armPhaseTimer()
        } else {
            finishCapture(save: total >= Self.minSamplesToSave)
            if total < Self.minSamplesToSave {
                state = .failed("采样不足（\(total) 个）—— 请对准椭圆框、按提示转动头部后重试")
            }
        }
    }

    /// Camera queue. Phase-gated + paced; appends one feature print per accepted sample.
    private nonisolated func collect(face: VNFaceObservation, quality: Float, handler: VNImageRequestHandler) {
        let now = ProcessInfo.processInfo.systemUptime
        let yaw = face.yaw?.doubleValue
        let pitch = face.pitch?.doubleValue
        let phases = Self.makePhases()

        let context = captureContext
        context.lock.lock()
        let phaseIndex = context.phaseIndex
        guard phaseIndex < phases.count else { context.lock.unlock(); return }
        let phase = phases[phaseIndex]
        let paced = now - context.lastCaptureAt >= Self.pacing
        // Phase 1 requires BOTH turn directions; a saturated-sign sample is skipped
        // unless the phase is already over-collected (then take it and move on).
        let signSaturated: Bool
        if phaseIndex == 1, let yaw {
            let positive = yaw > 0
            let sameSignCount = positive ? context.yawPositive : context.yawNegative
            let otherSignCount = positive ? context.yawNegative : context.yawPositive
            signSaturated = sameSignCount >= 2 && otherSignCount < 2 && context.phaseCollected < phase.target + 2
        } else {
            signSaturated = false
        }
        let accepted = paced
            && phase.accepts(yaw, pitch, quality, face.boundingBox)
            && !signSaturated
        if accepted { context.lastCaptureAt = now }
        let matcher = context.matcher
        context.lock.unlock()
        guard accepted, let matcher else { return }

        guard let print = matcher.featurePrint(for: face, handler: handler) else { return }

        context.lock.lock()
        context.prints.append(print)
        context.phaseCollected += 1
        if phaseIndex == 1, let yaw {
            if yaw > 0 { context.yawPositive += 1 } else { context.yawNegative += 1 }
        }
        let collected = context.prints.count
        let phaseCount = context.phaseCollected
        let phaseDone: Bool
        if phaseIndex == 1 {
            phaseDone = phaseCount >= phase.target
                && context.yawPositive >= 2 && context.yawNegative >= 2
        } else {
            phaseDone = phaseCount >= phase.target
        }
        context.lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .capturing(phase: phaseIndex, phaseCount: phaseCount,
                                    collected: collected, target: Self.totalTarget)
            if phaseDone { self.advancePhase() }
        }
    }

    /// MainActor. Stops the collector; optionally persists what was captured.
    private func finishCapture(save: Bool) {
        countdownTimer?.invalidate()
        phaseTimer?.invalidate()
        analyzer?.enrollmentCollector = nil
        analyzer?.verboseAnalysis = false

        captureContext.lock.lock()
        let prints = captureContext.prints
        let matcher = captureContext.matcher
        captureContext.prints = []
        captureContext.lock.unlock()

        if save, !prints.isEmpty {
            do {
                try OwnerStore.save(prints)
                matcher?.setEnrolled(prints)
                enrolledSampleCount = prints.count
                SettingsStore.shared.ownerRecognitionEnabled = true
                state = .done(prints.count)
                Log.detection.info("enrollment saved \(prints.count) samples to keychain")
            } catch {
                state = .failed("保存到钥匙串失败：\(error.localizedDescription)")
                Log.detection.error("enrollment save failed: \(error.localizedDescription)")
            }
        } else {
            state = .idle
        }

        // Auto-close shortly after success.
        if case .done = state {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.window?.close()
                self?.state = .idle
            }
        }
    }

    /// Instruction for the current capturing state (UI).
    var currentInstruction: String {
        guard case .capturing(let phase, _, _, _) = state else { return "" }
        let phases = Self.makePhases()
        return phase < phases.count ? phases[phase].instruction : ""
    }

    // MARK: - Window

    private func showWindow(session: AVCaptureSession) {
        if window == nil {
            let view = EnrollmentView(session: session, controller: self)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "录入机主人脸"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 400, height: 430))
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Enrollment UI

private struct EnrollmentView: View {
    let session: AVCaptureSession
    @ObservedObject var controller: EnrollmentController

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                CameraPreviewRepresentable(session: session)
                    .frame(width: 360, height: 202)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                // Framing guide — phase 0's gate roughly matches this oval.
                Ellipse()
                    .stroke(Color.white.opacity(0.8), lineWidth: 2)
                    .frame(width: 150, height: 190)
                    .shadow(color: .black.opacity(0.4), radius: 2)

                if case .countdown(let n) = controller.state {
                    Text("\(n)")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                }
            }

            switch controller.state {
            case .idle:
                Text("准备就绪").foregroundStyle(.secondary)
            case .countdown:
                Text("请坐好，把脸对准椭圆框…")
                    .font(.callout)
            case .capturing(let phase, let phaseCount, let collected, let target):
                VStack(spacing: 6) {
                    Text(controller.currentInstruction)
                        .font(.callout)
                        .fontWeight(.medium)
                    ProgressView(value: Double(collected), total: Double(target))
                    Text("第 \(phase + 1)/3 步 · 本步 \(phaseCount) 个 · 共 \(collected)/\(target) 个样本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .done(let count):
                Text("录入完成 ✓（\(count) 个样本）")
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Spacer()
                Button("取消") { controller.cancel() }
            }
        }
        .padding(20)
    }
}

/// Preview whose video layer always tracks the view's bounds. (CALayer
/// autoresizingMask is unreliable for sublayers of view-backed layers on macOS,
/// which left the video stuck at its creation frame — the "face not in the box" bug.)
private final class PreviewContainerView: NSView {
    var videoLayer: AVCaptureVideoPreviewLayer? {
        didSet { needsLayout = true }
    }
    override func layout() {
        super.layout()
        videoLayer?.frame = bounds
    }
}

private struct CameraPreviewRepresentable: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = PreviewContainerView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer?.addSublayer(preview)
        view.videoLayer = preview
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
