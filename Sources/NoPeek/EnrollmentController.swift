import AppKit
import AVFoundation
import SwiftUI
import Vision

/// Owner enrollment, Face-ID style: the user frames their face in the oval guide and
/// capture STARTS AUTOMATICALLY once the pose is stable — no button, no countdown to
/// race. A ring of 8 sectors appears around the oval; turning the head lights up the
/// sector in that direction (one sample per sector + 3 near-frontal), so the enrolled
/// set covers every pose the runtime matcher can encounter. Full coverage → save.
///
/// The capture itself runs on the camera queue (frames must not leave it); this
/// controller is MainActor and only receives progress updates. Pose binning is the
/// unit-tested pure function PoseBins.bin (NoPeekCore).
@MainActor
final class EnrollmentController: ObservableObject {

    static let shared = EnrollmentController()

    enum State: Equatable {
        case idle
        /// Window open, waiting for a well-framed stable face to auto-start.
        case waitingForFace
        case capturing(collected: Int, target: Int, sectors: [Bool], centerDone: Int)
        case done(Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var enrolledSampleCount = 0

    private var window: NSWindow?
    private var analyzer: FaceAnalyzer?
    private var session: AVCaptureSession?

    // MARK: - Capture tuning

    /// Samples are paced so consecutive prints actually differ.
    nonisolated private static let pacing: TimeInterval = 0.3
    /// How long the framing pose must hold before capture auto-starts.
    nonisolated private static let autoStartHold: TimeInterval = 0.8
    nonisolated private static let minQuality: Float = 0.25
    nonisolated private static let centerMinQuality: Float = 0.30

    /// Camera-queue confined capture state (all access under its lock).
    private final class CaptureContext: @unchecked Sendable {
        var matcher: OwnerMatcher?
        var prints: [VNFeaturePrintObservation] = []
        var sectors = [Bool](repeating: false, count: PoseBins.sectorCount)
        var centerDone = 0
        var capturing = false // auto-start latch
        var framedSince: TimeInterval?
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
        captureContext.lock.lock()
        captureContext.prints = []
        captureContext.sectors = [Bool](repeating: false, count: PoseBins.sectorCount)
        captureContext.centerDone = 0
        captureContext.capturing = false
        captureContext.framedSince = nil
        captureContext.lastCaptureAt = 0
        captureContext.lock.unlock()

        state = .waitingForFace
        analyzer.verboseAnalysis = true
        // The collector is armed immediately — it performs the framing gate and the
        // auto-start latch on the camera queue, so capture begins the moment the
        // user's face is properly placed (no racing a countdown).
        analyzer.enrollmentCollector = { [weak self] face, quality, handler in
            self?.collect(face: face, quality: quality, handler: handler)
        }
        showWindow(session: session)
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

    /// Camera queue. Framing gate → auto-start latch → pose-bin coverage capture.
    private nonisolated func collect(face: VNFaceObservation, quality: Float, handler: VNImageRequestHandler) {
        let now = ProcessInfo.processInfo.systemUptime
        let yaw = face.yaw?.doubleValue
        let pitch = face.pitch?.doubleValue
        let bin = PoseBins.bin(yaw: yaw, pitch: pitch)
        let box = face.boundingBox

        // Framing gate for auto-start: near-frontal, centered, close enough, sharp.
        let centered = (0.28...0.72).contains(box.midX) && (0.22...0.82).contains(box.midY)
        let framed = bin == -1 && quality >= Self.centerMinQuality
            && box.width * box.height >= 0.012 && centered

        let context = captureContext
        context.lock.lock()
        if !context.capturing {
            if framed {
                if let since = context.framedSince, now - since >= Self.autoStartHold {
                    context.capturing = true
                    context.framedSince = nil
                    // Enqueuing a Task never blocks — safe under the lock.
                    Task { @MainActor [weak self] in self?.didAutoStart() }
                    // Fall through — this frame doubles as the first center sample.
                } else {
                    if context.framedSince == nil { context.framedSince = now }
                    context.lock.unlock()
                    return
                }
            } else {
                context.framedSince = nil
                context.lock.unlock()
                return
            }
        }

        // Capturing. Pace + quality + bin coverage gates.
        guard now - context.lastCaptureAt >= Self.pacing,
              quality >= Self.minQuality,
              let bin else {
            context.lock.unlock()
            return
        }
        let wanted: Bool
        if bin < 0 {
            wanted = quality >= Self.centerMinQuality && context.centerDone < PoseBins.centerTarget
        } else {
            wanted = !context.sectors[bin]
        }
        guard wanted else {
            context.lock.unlock()
            return
        }
        context.lastCaptureAt = now
        let matcher = context.matcher
        context.lock.unlock()
        guard let matcher else { return }

        guard let print = matcher.featurePrint(for: face, handler: handler) else { return }

        context.lock.lock()
        context.prints.append(print)
        if bin < 0 { context.centerDone += 1 } else { context.sectors[bin] = true }
        let collected = context.prints.count
        let sectors = context.sectors
        let centerDone = context.centerDone
        let complete = centerDone >= PoseBins.centerTarget && sectors.allSatisfy { $0 }
        context.lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .capturing(collected: collected, target: PoseBins.totalTarget,
                                    sectors: sectors, centerDone: centerDone)
            if complete { self.finishCapture(save: true) }
        }
    }

    /// MainActor. Framing pose held long enough — flip to the ring UI with a cue.
    private func didAutoStart() {
        guard case .waitingForFace = state else { return }
        state = .capturing(collected: 0, target: PoseBins.totalTarget,
                           sectors: [Bool](repeating: false, count: PoseBins.sectorCount),
                           centerDone: 0)
        NSSound(named: "Tink")?.play()
    }

    /// MainActor. Stops the collector; optionally persists what was captured.
    private func finishCapture(save: Bool) {
        analyzer?.enrollmentCollector = nil
        analyzer?.verboseAnalysis = false

        captureContext.lock.lock()
        let prints = captureContext.prints
        let matcher = captureContext.matcher
        let wasCapturing = captureContext.capturing
        captureContext.prints = []
        captureContext.lock.unlock()

        if save, !prints.isEmpty {
            do {
                try OwnerStore.save(prints)
                matcher?.setEnrolled(prints)
                enrolledSampleCount = prints.count
                SettingsStore.shared.ownerRecognitionEnabled = true
                state = .done(prints.count)
                NSSound(named: "Glass")?.play()
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
        } else if !wasCapturing, case .idle = state {
            window?.close() // cancelled before capture began — close immediately
        }
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
            window.setContentSize(NSSize(width: 400, height: 420))
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

    /// Extract the coverage arrays from the state (defaults while waiting).
    private var sectors: [Bool] {
        if case .capturing(_, _, let sectors, _) = controller.state { return sectors }
        return [Bool](repeating: false, count: PoseBins.sectorCount)
    }
    private var centerDone: Int {
        if case .capturing(_, _, _, let centerDone) = controller.state { return centerDone }
        return 0
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                CameraPreviewRepresentable(session: session)
                    .frame(width: 360, height: 202)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                // Faint framing oval — the auto-start gate roughly matches it.
                Ellipse()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 148, height: 186)

                // Coverage ring: 8 sectors, one per head direction. (Visual mapping
                // is self-correcting — the user turns toward whatever stays gray.)
                ForEach(0..<PoseBins.sectorCount, id: \.self) { index in
                    Ellipse()
                        .trim(from: Double(index) / Double(PoseBins.sectorCount) + 0.012,
                              to: Double(index + 1) / Double(PoseBins.sectorCount) - 0.012)
                        .stroke(sectors[index] ? Color.green : Color.white.opacity(0.55),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 168, height: 206)
                }

                // Center-bin progress: 3 dots for the near-frontal samples.
                HStack(spacing: 6) {
                    ForEach(0..<PoseBins.centerTarget, id: \.self) { dot in
                        Circle()
                            .fill(dot < centerDone ? Color.green : Color.white.opacity(0.55))
                            .frame(width: 8, height: 8)
                    }
                }
                .offset(y: 108)
            }

            switch controller.state {
            case .idle:
                Text("准备就绪").foregroundStyle(.secondary)
            case .waitingForFace:
                Text("把脸对准椭圆框，保持稳定将自动开始")
                    .font(.callout)
            case .capturing(let collected, let target, _, _):
                VStack(spacing: 6) {
                    Text("缓慢转头一圈，点亮所有扇区")
                        .font(.callout)
                        .fontWeight(.medium)
                    ProgressView(value: Double(collected), total: Double(target))
                    Text("\(collected)/\(target) 个样本 · 朝灰色扇区方向转头")
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
