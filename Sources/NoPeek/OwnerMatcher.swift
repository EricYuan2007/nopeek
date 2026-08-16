import CoreVideo
import Vision

/// Owner identity via Vision image feature prints on face regions.
///
/// Why feature prints instead of an embedded MobileFaceNet CoreML model: zero model
/// files, zero conversion tooling, zero licensing surface, fully on-device — and the
/// class boundary keeps the door open to swapping in a dedicated embedding network
/// later (same call sites). Feature prints on aligned-enough face crops discriminate
/// "same person, slightly turned" from "different person" well enough for gating
/// alerts; the match threshold is user-tunable with live distances in the debug
/// overlay (d=… labels).
///
/// Confined to the camera analysis queue (called from FaceAnalyzer.analyze).
final class OwnerMatcher: @unchecked Sendable {

    /// Pinned so stored prints stay comparable across OS updates. If a future OS
    /// drops revision 2, distance computation throws → logged → treated as no-match.
    private let featurePrintRequest: VNGenerateImageFeaturePrintRequest = {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill
        return request
    }()

    /// Enrollment is written from MainActor (settings/enrollment UI) while reads
    /// happen on the camera queue — guard with a lock. The prints themselves are
    /// immutable once created.
    private let enrollmentLock = NSLock()
    private var enrolledStorage: [VNFeaturePrintObservation] = []

    var enrolled: [VNFeaturePrintObservation] {
        enrollmentLock.lock()
        defer { enrollmentLock.unlock() }
        return enrolledStorage
    }

    var isReady: Bool { !enrolled.isEmpty }

    func setEnrolled(_ prints: [VNFeaturePrintObservation]) {
        enrollmentLock.lock()
        enrolledStorage = prints
        enrollmentLock.unlock()
        Log.detection.info("owner matcher enrolled with \(prints.count) samples")
    }

    func loadFromStore() {
        let loaded = OwnerStore.load()
        setEnrolled(loaded)
        if !loaded.isEmpty {
            Log.detection.info("owner matcher loaded \(loaded.count) samples")
        }
    }

    /// Feature print of a face's region in the current frame.
    func featurePrint(for face: VNFaceObservation, handler: VNImageRequestHandler) -> VNFeaturePrintObservation? {
        // Clamp the ROI into the unit square: face boxes near the frame edge can
        // extend past [0,1], and an out-of-bounds ROI makes the request throw.
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let roi = face.boundingBox.intersection(unit)
        guard !roi.isNull, roi.width > 0, roi.height > 0 else { return nil }
        featurePrintRequest.regionOfInterest = roi
        do {
            try handler.perform([featurePrintRequest])
        } catch {
            Log.detection.error("feature print failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return featurePrintRequest.results?.first
    }

    /// Distance to the nearest enrolled sample; lower = more similar. Nil if no
    /// enrollment or the prints are incomparable (revision mismatch).
    func ownerDistance(to print: VNFeaturePrintObservation) -> Float? {
        guard isReady else { return nil }
        var best: Float = .greatestFiniteMagnitude
        var computed = false
        for enrolledPrint in enrolled {
            var distance: Float = .greatestFiniteMagnitude
            do {
                try print.computeDistance(&distance, to: enrolledPrint)
                best = min(best, distance)
                computed = true
            } catch {
                Log.detection.error("feature print distance failed (re-enroll needed): \(error.localizedDescription, privacy: .public)")
            }
        }
        return computed ? best : nil
    }
}
