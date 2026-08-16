import AppKit
import AVFoundation

/// Debug tuning window: live camera preview with per-face boxes and telemetry labels
/// (track id, area, yaw/pitch in degrees, quality, static flag). This is the stand-in
/// for Xcode's debugger when calibrating thresholds — watch the numbers while moving
/// a test face (phone video / printed photo / a friend) around behind the laptop.
@MainActor
final class DebugOverlayController {

    private var window: NSWindow?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var boxLayer = CALayer()
    private var boxSublayers: [CALayer] = []

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle(session: AVCaptureSession) {
        if isVisible {
            window?.close()
            window = nil
            return
        }
        show(session: session)
    }

    func show(session: AVCaptureSession) {
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

        let contentView = NSView(frame: window.contentLayoutRect)
        contentView.wantsLayer = true
        window.contentView = contentView

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        preview.frame = contentView.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentView.layer?.addSublayer(preview)

        boxLayer.frame = contentView.bounds
        boxLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentView.layer?.addSublayer(boxLayer)

        self.window = window
        self.previewLayer = preview
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.ui.info("debug overlay shown")
    }

    func update(_ observation: FrameObservation) {
        guard isVisible, let preview = previewLayer else { return }
        boxSublayers.forEach { $0.removeFromSuperlayer() }
        boxSublayers = []

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for face in observation.faces {
            // Vision coords are normalized bottom-left; metadata-output coords (what the
            // conversion API expects) are normalized top-left → flip Y.
            let flipped = CGRect(x: face.boundingBox.minX,
                                 y: 1 - face.boundingBox.minY - face.boundingBox.height,
                                 width: face.boundingBox.width,
                                 height: face.boundingBox.height)
            let rect = preview.layerRectConverted(fromMetadataOutputRect: flipped)

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

            boxLayer.addSublayer(box)
            boxLayer.addSublayer(label)
            boxSublayers.append(box)
            boxSublayers.append(label)
        }
        CATransaction.commit()
    }
}
