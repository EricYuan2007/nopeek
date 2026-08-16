import CoreVideo
import Vision

/// Runs the Vision pipeline on throttled camera frames. Confined to the camera queue
/// (wired into CameraManager.onFrame), internally serial — hence @unchecked Sendable.
///
/// Per frame:
///   1. rectangles (rev3) — find faces, drop sub-noise-floor boxes
///   2. landmarks (rev3) + capture-quality — landmarks rev3 is the reliable source of
///      yaw/pitch/roll; quality filters blur/reflection junk. Skipped when 0–1 faces
///      and nobody needs details (no intruder is possible) — the power-saving path.
///   3. owner matching (V2, when enrolled) — feature print per face, distance to the
///      nearest enrolled sample
final class FaceAnalyzer: @unchecked Sendable {

    /// V2 seam — identity matcher (feature prints). Nil/empty = V1 largest-face mode.
    var ownerMatcher: OwnerMatcher?

    /// Identity threshold pushed from settings (MainActor write, camera-queue read —
    /// scalar configuration push, same benign pattern as verboseAnalysis). This is the
    /// NOMINAL midpoint of the identity deadband; verdicts flip at ±identityDeadband
    /// around it so a distance hovering at the line can't flap owner↔stranger.
    var ownerMaxDistance: Float = 0.55

    /// Enrollment capture hook: (face observation, capture quality, frame handler),
    /// called for the LARGEST face each frame while set. Runs on the camera queue —
    /// the handler must not escape it.
    var enrollmentCollector: ((VNFaceObservation, Float, VNImageRequestHandler) -> Void)?

    /// Raw per-frame output, called on the camera queue. Values only — hop to MainActor
    /// at the call site.
    var onObservation: ((FrameObservation) -> Void)?

    /// When true (debug overlay visible), pose/quality runs even for single-face frames
    /// so the overlay has numbers to show.
    var verboseAnalysis = false

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

    // MARK: Identity smoothing (camera-queue confined)
    //
    // Raw feature-print distances jitter with pose — a mere head turn can push the
    // owner's own face over the match threshold (observed live: frontal d≈0.3,
    // turned -24° d≈0.54). Three guards:
    //   1. EMA smoothing per track — brief spikes stay under threshold; a real
    //      stranger sustains a high distance and still trips the 3-frame debounce.
    //   2. Pose-gated updates — beyond ±30° yaw (or low quality) identity reads are
    //      unreliable, so the track's last known distance is HELD, not updated.
    //      Peeking requires facing the camera, so nothing is lost.
    //   3. Verdict deadband — observed live: the owner's own frontal distance can
    //      hover right at the nominal threshold for seconds (d 0.47→0.51 @ 0.5),
    //      slowly EMA-drifting across it into a false alert. So the per-track
    //      owner/stranger verdict only flips OUTSIDE a ±identityDeadband band
    //      around the nominal threshold; inside the band the previous verdict
    //      stands (first-time tracks fall back to the nominal comparison).
    private var smoothedDistanceByTrack: [Int: Float] = [:]
    private var identityIsOwnerByTrack: [Int: Bool] = [:]
    private static let identityMaxYawRad: CGFloat = 0.52 // 30°
    private static let identityMinQuality: Float = 0.25
    private static let identityDeadband: Float = 0.10

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

            // With 0–1 faces there is normally no possible intruder, so the expensive
            // landmarks/quality pass is skipped — the steady state costs one cheap
            // rectangle pass per frame. The pass runs when multi-face frames appear,
            // the debug overlay is open, enrollment is capturing, or owner matching
            // is active (a lone face could be a stranger — identity must be checked).
            let ownerMatchingActive = ownerMatcher?.isReady ?? false
            let needsDetail = rawFaces.count > 1 || verboseAnalysis
                || ownerMatchingActive || enrollmentCollector != nil

            if needsDetail {
                landmarksRequest.inputFaceObservations = rawFaces
                qualityRequest.inputFaceObservations = rawFaces
                try handler.perform([landmarksRequest, qualityRequest])
            }

            var poseByUUID: [UUID: VNFaceObservation] = [:]
            if needsDetail {
                for observation in landmarksRequest.results ?? [] {
                    poseByUUID[observation.uuid] = observation
                }
            }
            var qualityByUUID: [UUID: VNFaceObservation] = [:]
            if needsDetail {
                for observation in qualityRequest.results ?? [] {
                    qualityByUUID[observation.uuid] = observation
                }
            }

            // V2: identity distance per face (feature print on the face region).
            var distanceByUUID: [UUID: Float] = [:]
            if ownerMatchingActive, let matcher = ownerMatcher {
                for face in rawFaces {
                    if let print = matcher.featurePrint(for: face, handler: handler),
                       let distance = matcher.ownerDistance(to: print) {
                        distanceByUUID[face.uuid] = distance
                    }
                }
            }

            let faces: [FaceInfo] = rawFaces.map { rect in
                let poseSource = poseByUUID[rect.uuid] ?? rect
                return FaceInfo(
                    boundingBox: rect.boundingBox,
                    yawRad: poseSource.yaw.map { CGFloat($0.doubleValue) },
                    pitchRad: poseSource.pitch.map { CGFloat($0.doubleValue) },
                    quality: qualityByUUID[rect.uuid]?.faceCaptureQuality ?? 0,
                    ownerDistance: distanceByUUID[rect.uuid]
                )
            }

            // Enrollment capture: largest face, quality-gated, paced by the collector.
            if let collector = enrollmentCollector,
               let largest = rawFaces.max(by: { $0.boundingBox.width * $0.boundingBox.height
                                                < $1.boundingBox.width * $1.boundingBox.height }) {
                let quality = qualityByUUID[largest.uuid]?.faceCaptureQuality ?? 0
                collector(largest, quality, handler)
            }

            var tracked = tracker.process(faces, at: timestamp)
                .sorted { $0.area > $1.area }

            if ownerMatchingActive {
                for index in tracked.indices {
                    var face = tracked[index]
                    let poseReliable = (face.yawRad.map { abs($0) <= Self.identityMaxYawRad } ?? false)
                        && face.quality >= Self.identityMinQuality
                    if poseReliable, let raw = face.ownerDistance {
                        let previous = smoothedDistanceByTrack[face.trackID]
                        let smoothed = previous.map { $0 * 0.55 + raw * 0.45 } ?? raw
                        smoothedDistanceByTrack[face.trackID] = smoothed
                        face.ownerDistance = smoothed
                        // Deadband verdict: only a decisive excursion flips identity.
                        let nominal = ownerMaxDistance
                        let verdict: Bool
                        if smoothed <= nominal - Self.identityDeadband {
                            verdict = true
                        } else if smoothed >= nominal + Self.identityDeadband {
                            verdict = false
                        } else if let established = identityIsOwnerByTrack[face.trackID] {
                            verdict = established
                        } else {
                            verdict = smoothed <= nominal
                        }
                        identityIsOwnerByTrack[face.trackID] = verdict
                        face.isOwner = verdict
                    } else {
                        // Unreliable read (turned/blurry) — hold the last known values.
                        face.ownerDistance = smoothedDistanceByTrack[face.trackID]
                        face.isOwner = identityIsOwnerByTrack[face.trackID]
                    }
                    tracked[index] = face
                }
                let liveIDs = Set(tracked.map(\.trackID))
                smoothedDistanceByTrack = smoothedDistanceByTrack.filter { liveIDs.contains($0.key) }
                identityIsOwnerByTrack = identityIsOwnerByTrack.filter { liveIDs.contains($0.key) }
            }

            emit(FrameObservation(timestamp: timestamp, faces: tracked))
        } catch {
            Log.detection.error("vision perform failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func emit(_ observation: FrameObservation) {
        onObservation?(observation)
    }
}
