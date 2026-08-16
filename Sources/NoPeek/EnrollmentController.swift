import AppKit
import AVFoundation
import SwiftUI
import Vision

/// Owner enrollment: a small window with a live preview that captures 8 feature-print
/// samples of the largest face over ~4 seconds (paced, quality-gated), then persists
/// them to the Keychain and enables owner recognition.
///
/// The capture itself runs on the camera queue (frames must not leave it); this
/// controller is MainActor and only receives count updates.
@MainActor
final class EnrollmentController: ObservableObject {

    static let shared = EnrollmentController()

    enum State: Equatable {
        case idle
        case capturing(count: Int, target: Int)
        case done(Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var enrolledSampleCount = 0

    private let targetCount = 8
    private let minQuality: Float = 0.25
    private let captureInterval: TimeInterval = 0.5

    private var window: NSWindow?
    private var analyzer: FaceAnalyzer?
    private var session: AVCaptureSession?

    /// Camera-queue confined capture context (all access under its lock).
    private final class CaptureContext: @unchecked Sendable {
        var matcher: OwnerMatcher?
        var prints: [VNFeaturePrintObservation] = []
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
        captureContext.lastCaptureAt = 0
        captureContext.lock.unlock()

        state = .capturing(count: 0, target: targetCount)
        analyzer.verboseAnalysis = true
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

    /// Camera queue. Paced + quality-gated; appends one feature print per capture.
    private nonisolated func collect(face: VNFaceObservation, quality: Float, handler: VNImageRequestHandler) {
        guard quality >= minQuality else { return }
        let now = ProcessInfo.processInfo.systemUptime

        let context = captureContext
        context.lock.lock()
        let ready = now - context.lastCaptureAt >= captureInterval && context.prints.count < targetCount
        if ready { context.lastCaptureAt = now }
        let matcher = context.matcher
        context.lock.unlock()
        guard ready, let matcher else { return }

        guard let print = matcher.featurePrint(for: face, handler: handler) else { return }

        context.lock.lock()
        context.prints.append(print)
        let count = context.prints.count
        context.lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .capturing(count: count, target: self.targetCount)
            if count >= self.targetCount {
                self.finishCapture(save: true)
            }
        }
    }

    /// MainActor. Stops the collector; optionally persists what was captured.
    private func finishCapture(save: Bool) {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.window?.close()
                self?.state = .idle
            }
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
            window.setContentSize(NSSize(width: 360, height: 330))
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
            CameraPreviewRepresentable(session: session)
                .frame(width: 320, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            switch controller.state {
            case .idle:
                Text("准备就绪").foregroundStyle(.secondary)
            case .capturing(let count, let target):
                VStack(spacing: 6) {
                    Text("请正对屏幕，缓慢左右转动头部")
                        .font(.callout)
                    ProgressView(value: Double(count), total: Double(target))
                    Text("\(count) / \(target)")
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
            }

            HStack {
                Spacer()
                Button("取消") { controller.cancel() }
            }
        }
        .padding(20)
    }
}

private struct CameraPreviewRepresentable: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(preview)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
