import CoreVideo
import Vision

/// V2 seam: identity embedding extractor (MobileFaceNet via CoreML). Nil in V1 —
/// the largest face is treated as the owner. Setting this switches owner anchoring
/// to identity matching with no other code changes.
protocol FaceEmbeddingExtractor: Sendable {
    func embedding(for face: VNFaceObservation, in buffer: CVPixelBuffer) -> [Float]?
}

/// Runs the Vision pipeline on throttled camera frames. Confined to the camera queue
/// (wired into CameraManager.onFrame), internally serial — hence @unchecked Sendable.
///
/// Per frame, two `perform` passes over three reused requests:
///   1. rectangles (rev3) — find faces, drop sub-noise-floor boxes
///   2. landmarks (rev3) + capture-quality — landmarks rev3 is the reliable source of
///      yaw/pitch/roll; quality filters blur/reflection junk
final class FaceAnalyzer: @unchecked Sendable {

    /// Snapshot pushed from MainActor whenever settings change.
    var config = DetectionConfig()

    /// V2 seam — nil in V1.
    var embeddingExtractor: (any FaceEmbeddingExtractor)?

    /// Raw per-frame output, called on the camera queue. Values only — hop to MainActor
    /// at the call site.
    var onObservation: ((FrameObservation) -> Void)?

    private let tracker = FaceTracker()

    private let rectanglesRequest: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()
    private let landmarksRequest: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        return request
    }()
    private let qualityRequest = VNDetectFaceCaptureQualityRequest()

    /// Minimum normalized bbox area to bother with at all (far below the intruder gate).
    private let noiseFloorArea: CGFloat = 0.0008

    func analyze(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([rectanglesRequest])
            let rawFaces = (rectanglesRequest.results ?? []).filter {
                $0.boundingBox.width * $0.boundingBox.height >= noiseFloorArea
            }
            guard !rawFaces.isEmpty else {
                emit(FrameObservation(timestamp: timestamp, faces: []))
                return
            }

            landmarksRequest.inputFaceObservations = rawFaces
            qualityRequest.inputFaceObservations = rawFaces
            try handler.perform([landmarksRequest, qualityRequest])

            var poseByUUID: [UUID: VNFaceObservation] = [:]
            for observation in landmarksRequest.results ?? [] {
                poseByUUID[observation.uuid] = observation
            }
            var qualityByUUID: [UUID: VNFaceObservation] = [:]
            for observation in qualityRequest.results ?? [] {
                qualityByUUID[observation.uuid] = observation
            }

            let faces: [FaceInfo] = rawFaces.map { rect in
                let poseSource = poseByUUID[rect.uuid] ?? rect
                return FaceInfo(
                    boundingBox: rect.boundingBox,
                    yawRad: poseSource.yaw.map { CGFloat($0.doubleValue) },
                    pitchRad: poseSource.pitch.map { CGFloat($0.doubleValue) },
                    quality: qualityByUUID[rect.uuid]?.faceCaptureQuality ?? 0
                )
            }

            let tracked = tracker.process(faces, at: timestamp)
                .sorted { $0.area > $1.area }
            emit(FrameObservation(timestamp: timestamp, faces: tracked))
        } catch {
            Log.detection.error("vision perform failed: \(error.localizedDescription)")
        }
    }

    private func emit(_ observation: FrameObservation) {
        onObservation?(observation)
    }
}
