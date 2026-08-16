import AVFoundation
import CoreVideo

/// Owns the AVCaptureSession. Everything (session control and frame delivery) happens on a
/// single serial queue, so the class is internally synchronized despite being non-actor.
/// Frames are throttled to `analysisFPS` and handed off as borrowed CVPixelBuffers — valid
/// only for the duration of `onFrame`; they are never retained or written to disk.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    enum State: String {
        case stopped, running, interrupted, error, unauthorized
    }

    /// Serial queue for session control AND sample-buffer delivery.
    private let queue = DispatchQueue(label: "com.nopeek.camera")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var lastAnalysisTime: TimeInterval = 0
    private var analyzedFrames = 0

    /// Borrowed frame + presentation timestamp, called on `queue`, at most `analysisFPS`/s.
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    /// State changes, posted on the main queue.
    var onStateChange: ((State) -> Void)?

    /// Detection needs ~10 fps, not the camera's native rate. Eco mode sets this to 6.
    var analysisFPS: Double = 10 {
        didSet { queue.async { self.applyFrameRateCap() } }
    }

    private var captureDevice: AVCaptureDevice?

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            let newState = state
            DispatchQueue.main.async { self.onStateChange?(newState) }
        }
    }

    /// Read-only access for AVCaptureVideoPreviewLayer (debug overlay / bubble preview).
    var captureSession: AVCaptureSession { session }

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                       name: .AVCaptureSessionWasInterrupted, object: session)
        nc.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                       name: .AVCaptureSessionRuntimeError, object: session)
        nc.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                       name: .AVCaptureSessionInterruptionEnded, object: session)
    }

    // MARK: - Permission

    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            Log.camera.info("camera access requested, granted=\(granted)")
            return granted
        case .denied, .restricted:
            Log.camera.warning("camera access denied/restricted")
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Lifecycle (idempotent, dispatched onto `queue`)

    func start() {
        queue.async {
            guard self.state != .unauthorized else { return }
            self.configureIfNeeded()
            guard self.configured, !self.session.isRunning else { return }
            self.session.startRunning()
            self.lastAnalysisTime = 0
            self.state = .running
            Log.camera.info("camera started (\(self.session.sessionPreset.rawValue))")
        }
    }

    func stop() {
        queue.async {
            guard self.session.isRunning else {
                if self.state == .running { self.state = .stopped }
                return
            }
            self.session.stopRunning()
            self.state = .stopped
            Log.camera.info("camera stopped")
        }
    }

    // MARK: - Configuration (on `queue`)

    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
            Log.camera.error("no built-in wide angle camera found")
            state = .error
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                Log.camera.error("cannot add camera input")
                state = .error
                return
            }
            session.addInput(input)
            captureDevice = device
            applyFrameRateCap()
        } catch {
            Log.camera.error("camera input failed: \(error.localizedDescription)")
            state = .error
            return
        }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            Log.camera.error("cannot add video output")
            state = .error
            return
        }
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        configured = true
    }

    /// Cap the sensor's own frame rate as close to the analysis rate as the hardware
    /// allows — without this the camera delivers 30 fps and we silently discard
    /// two-thirds of frames in the delegate (which still pays the per-frame delivery
    /// cost). The PTS throttle in captureOutput stays as a safety net.
    ///
    /// The rate MUST be clamped into videoSupportedFrameRateRanges first: out-of-range
    /// values raise an uncatchable NSException (this MacBook camera only does 15–30 fps,
    /// so 10 fps is unreachable — we cap at 15).
    private func applyFrameRateCap() {
        guard let device = captureDevice,
              let range = device.activeFormat.videoSupportedFrameRateRanges.first else { return }
        let clampedFPS = min(max(analysisFPS, range.minFrameRate), range.maxFrameRate)
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: CMTimeScale(clampedFPS))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            Log.camera.info("sensor frame rate capped at \(clampedFPS) fps (hardware range \(range.minFrameRate)–\(range.maxFrameRate))")
        } catch {
            Log.camera.warning("frame-rate cap failed: \(error.localizedDescription)")
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (on `queue`)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite, timestamp - lastAnalysisTime >= 1.0 / analysisFPS else { return }
        lastAnalysisTime = timestamp
        analyzedFrames += 1
        if analyzedFrames % Int(analysisFPS) == 0 {
            Log.camera.debug("analysis tick — \(self.analyzedFrames) frames total")
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, timestamp)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Expected under load — alwaysDiscardsLateVideoFrames keeps latency bounded.
    }

    // MARK: - Session notifications (main thread → hop to `queue`)

    @objc private func sessionWasInterrupted(_ note: Notification) {
        // The interruption-reason userInfo key is iOS-only; macOS just signals the event.
        Log.camera.warning("session interrupted")
        queue.async { self.state = .interrupted }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        queue.async {
            guard self.state == .interrupted else { return }
            self.state = self.session.isRunning ? .running : .stopped
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let detail = note.userInfo?[AVCaptureSessionErrorKey].map { "\($0)" } ?? "unknown"
        Log.camera.error("session runtime error: \(detail)")
        queue.async { self.state = .error }
    }
}
