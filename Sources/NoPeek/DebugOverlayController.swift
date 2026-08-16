import AppKit
import AVFoundation

/// Debug tuning window: live camera preview with per-face boxes and telemetry labels
/// (track id, area, yaw/pitch in degrees, quality, identity distance, static flag).
/// This is the stand-in for Xcode's debugger when calibrating thresholds — watch the
/// numbers while moving a test face (phone video / printed photo / a friend) around
/// behind the laptop.
@MainActor
final class DebugOverlayController {

    private var window: NSWindow?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var boxSublayers: [CALayer] = []
    /// Sensor pixel dimensions at the time the window opened (for aspect-fit math).
    private var videoSize: CGSize = CGSize(width: 1280, height: 720)

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle(session: AVCaptureSession, videoSize: CGSize) {
        if isVisible {
            window?.close()
            window = nil
            return
        }
        show(session: session, videoSize: videoSize)
    }

    func show(session: AVCaptureSession, videoSize: CGSize) {
        if videoSize.width > 0, videoSize.height > 0 {
            self.videoSize = videoSize
        }
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NoPeek 调试浮层"
        window.isReleasedWhenClosed = false

        // Custom container: CALayer.autoresizingMask is unreliable for sublayers of a
        // view-backed layer on macOS, so frames are assigned in layout() instead —
        // the preview and the box overlay always exactly cover the window.
        let contentView = OverlayContentView(frame: window.contentLayoutRect)
        contentView.wantsLayer = true
        window.contentView = contentView

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        preview.frame = contentView.bounds
        contentView.layer?.addSublayer(preview)
        contentView.previewLayer = preview

        contentView.layer?.addSublayer(contentView.boxesLayer)
        contentView.needsLayout = true

        self.window = window
        self.previewLayer = preview
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.ui.info("debug overlay shown")
    }

    func update(_ observation: FrameObservation) {
        guard isVisible, let preview = previewLayer,
              let contentView = window?.contentView as? OverlayContentView else { return }
        boxSublayers.forEach { $0.removeFromSuperlayer() }
        boxSublayers = []

        let bounds = contentView.bounds
        // Mirroring can be toggled by the system for front cameras — ask, don't assume.
        let mirrored = preview.connection?.isVideoMirrored ?? false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for face in observation.faces {
            let rect = layerRect(for: face.boundingBox, in: bounds, mirrored: mirrored)

            let box = CALayer()
            box.frame = rect
            box.borderWidth = 2
            if face.isOwner == false {
                box.borderColor = NSColor.systemRed.cgColor
            } else if face.isStaticSuspect {
                box.borderColor = NSColor.systemOrange.cgColor
            } else {
                box.borderColor = NSColor.systemGreen.cgColor
            }

            let yawDeg = face.yawRad.map { String(format: "%.0f°", $0 * 180 / .pi) } ?? "?"
            let pitchDeg = face.pitchRad.map { String(format: "%.0f°", $0 * 180 / .pi) } ?? "?"
            let distance = face.ownerDistance.map { String(format: " d=%.2f", $0) } ?? ""
            let identity = face.isOwner.map { $0 ? " OWNER" : " STRANGER" } ?? ""
            let label = CATextLayer()
            label.string = "#\(face.trackID) a=\(String(format: "%.4f", face.area)) y=\(yawDeg) p=\(pitchDeg) q=\(String(format: "%.2f", face.quality))\(distance)\(identity)\(face.isStaticSuspect ? " STATIC" : "")"
            label.fontSize = 10
            label.foregroundColor = NSColor.white.cgColor
            label.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            label.frame = CGRect(x: rect.minX, y: rect.maxY + 2, width: 230, height: 13)

            contentView.boxesLayer.addSublayer(box)
            contentView.boxesLayer.addSublayer(label)
            boxSublayers.append(box)
            boxSublayers.append(label)
        }
        CATransaction.commit()
    }

    /// Vision-normalized face box (bottom-left origin, y-up) → layer coordinates.
    ///
    /// Manual math instead of layerRectConverted(fromMetadataOutputRect:): the metadata
    /// coordinate space's origin/mirroring conventions differ across OS versions, which
    /// produced visibly offset boxes. Both the preview and Vision see the same buffer
    /// with orientation .up, and macOS layer space is y-up — so the mapping is a direct
    /// aspect-fit scale with NO coordinate flip (mirroring handled explicitly).
    private func layerRect(for faceBox: CGRect, in bounds: CGRect, mirrored: Bool) -> CGRect {
        let videoW = max(videoSize.width, 1)
        let videoH = max(videoSize.height, 1)
        let scale = min(bounds.width / videoW, bounds.height / videoH)
        let fit = CGRect(x: (bounds.width - videoW * scale) / 2,
                         y: (bounds.height - videoH * scale) / 2,
                         width: videoW * scale,
                         height: videoH * scale)
        let x = mirrored
            ? fit.minX + (1 - faceBox.minX - faceBox.width) * fit.width
            : fit.minX + faceBox.minX * fit.width
        return CGRect(x: x,
                      y: fit.minY + faceBox.minY * fit.height,
                      width: faceBox.width * fit.width,
                      height: faceBox.height * fit.height)
    }
}

/// Container whose sublayers (preview + box overlay) always track its bounds.
private final class OverlayContentView: NSView {
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    let boxesLayer = CALayer()

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        boxesLayer.frame = bounds
    }
}
