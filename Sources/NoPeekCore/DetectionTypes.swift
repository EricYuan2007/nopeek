import CoreGraphics
import Foundation

// MARK: - Per-face snapshot

/// One detected face in one frame. Vision-normalized coordinates (bottom-left origin).
public struct FaceInfo: Sendable, Equatable {
    /// Stable across frames via FaceTracker (IoU matching).
    public var trackID: Int
    public var boundingBox: CGRect
    /// Normalized width*height — distance proxy. Larger = closer to the camera.
    public var area: CGFloat
    /// Head pose in radians; nil = pose unknown (Vision could not estimate it).
    public var yawRad: CGFloat?
    public var pitchRad: CGFloat?
    /// faceCaptureQuality 0...1 — junk filter for blur/extreme angle/reflections.
    public var quality: Float
    /// Poster/photo heuristic: tracked for a while with near-zero micro-motion.
    public var isStaticSuspect: Bool
    /// V2: distance to the nearest enrolled owner feature print (lower = more similar).
    /// nil = owner recognition not active or not computable for this face.
    public var ownerDistance: Float?
    /// V2: analyzer-side identity verdict WITH hysteresis (deadband around the
    /// threshold, so a distance hovering near the line can't flap the verdict).
    /// Wins over the raw distance when present; nil = no verdict available.
    public var isOwner: Bool?

    public init(trackID: Int = 0, boundingBox: CGRect, yawRad: CGFloat? = nil,
                pitchRad: CGFloat? = nil, quality: Float = 0, isStaticSuspect: Bool = false,
                ownerDistance: Float? = nil, isOwner: Bool? = nil) {
        self.trackID = trackID
        self.boundingBox = boundingBox
        self.area = boundingBox.width * boundingBox.height
        self.yawRad = yawRad
        self.pitchRad = pitchRad
        self.quality = quality
        self.isStaticSuspect = isStaticSuspect
        self.ownerDistance = ownerDistance
        self.isOwner = isOwner
    }
}

// MARK: - Per-frame observation

/// Raw analyzer output for one frame — the only value crossing queue boundaries.
public struct FrameObservation: Sendable, Equatable {
    public var timestamp: TimeInterval
    /// Faces sorted by area, descending (index 0 is the presumed owner in V1).
    public var faces: [FaceInfo]

    public init(timestamp: TimeInterval, faces: [FaceInfo]) {
        self.timestamp = timestamp
        self.faces = faces
    }
}

// MARK: - Per-frame decision (output of IntruderAssessor)

public struct Assessment: Sendable, Equatable {
    /// The face treated as "you". V1: largest face. V2: identity-matched face.
    public var owner: FaceInfo?
    /// Non-owner faces passing every gate (distance, pose, quality, static).
    public var intruders: [FaceInfo]
    public var faceCount: Int

    public init(owner: FaceInfo?, intruders: [FaceInfo], faceCount: Int) {
        self.owner = owner
        self.intruders = intruders
        self.faceCount = faceCount
    }
}

// MARK: - Detection states

public enum DetectionState: String, Sendable, Equatable {
    case off          // user paused / no permission
    case starting     // camera coming up
    case monitoring   // watching, nobody suspicious
    case suspicious   // intruder seen, counting consecutive frames
    case alert        // intruder confirmed — alerts are live
    case cooldown     // just cleared; quick to re-alert, slow to declare safe
}

// MARK: - Tunables

public struct DetectionConfig: Sendable, Equatable {
    /// Normalized bbox area floor for an intruder ≈ distance gate.
    /// 0.004 ≈ 2.5 m @720p (15 cm face, ~63° HFOV). Slider range 0.002 (far) … 0.012 (near).
    public var minIntruderArea: CGFloat = 0.004
    /// |yaw| limit: looking at the screen ≈ facing the camera. Default 35°.
    public var maxYawRad: CGFloat = 0.61
    /// |pitch| limit. Default 30°.
    public var maxPitchRad: CGFloat = 0.52
    public var minQuality: Float = 0.10
    /// Privacy tool bias: unknown pose counts as "facing" unless strict mode is on.
    public var requireKnownPose = false
    public var suppressStaticFaces = true
    /// Hysteresis, in frames at ~10 fps.
    public var enterFrames = 3        // suspicious → alert  (~0.3 s)
    public var exitFrames = 12        // alert → cooldown    (~1.2 s)
    public var cooldownEnterFrames = 2 // cooldown → alert fast re-trigger
    public var cooldownSeconds: TimeInterval = 4

    // MARK: V2 — owner recognition

    /// Identity-based owner anchoring (requires enrollment). Falls back to the
    /// largest-face heuristic for frames where no distance could be computed.
    public var ownerRecognitionEnabled = false
    /// Feature-print distance ceiling for "this is the owner". Lower = stricter.
    /// Calibrate with the debug overlay's live d= labels.
    public var ownerMaxDistance: Float = 0.5

    public init() {}
}

// MARK: - Intruder assessment (pure decision core)

public enum IntruderAssessor {
    /// Pure function: raw faces → owner + intruders. Unit-tested in NoPeekCoreTests.
    ///
    /// Owner anchoring:
    ///  - V2 (recognition enabled AND at least one face has identity info): the closest
    ///    face whose hysteresis verdict is "owner" (or, without a verdict, whose
    ///    distance is under `ownerMaxDistance`) is the owner; if none matches,
    ///    owner = nil and EVERY face is a stranger candidate ("owner absent +
    ///    stranger ⇒ alert").
    ///  - V1 (default): the largest face is the owner.
    public static func assess(faces: [FaceInfo], config: DetectionConfig) -> Assessment {
        guard !faces.isEmpty else {
            return Assessment(owner: nil, intruders: [], faceCount: 0)
        }

        let owner: FaceInfo?
        let candidates: [FaceInfo]
        let hasIdentity = faces.contains { $0.isOwner != nil || $0.ownerDistance != nil }
        if config.ownerRecognitionEnabled, hasIdentity {
            // Analyzer's hysteresis verdict wins; fall back to the raw threshold
            // for faces without a verdict (e.g. synthesized in tests).
            let matched = faces
                .filter { face in
                    if let isOwner = face.isOwner { return isOwner }
                    guard let distance = face.ownerDistance else { return false }
                    return distance <= config.ownerMaxDistance
                }
                .sorted { ($0.ownerDistance ?? .infinity) < ($1.ownerDistance ?? .infinity) }
            owner = matched.first
            candidates = faces.filter { $0.trackID != owner?.trackID }
        } else {
            let sorted = faces.sorted { $0.area > $1.area }
            owner = sorted.first
            candidates = Array(sorted.dropFirst())
        }

        let intruders = candidates.filter { isIntruder($0, config: config) }
        return Assessment(owner: owner, intruders: intruders, faceCount: faces.count)
    }

    private static func isIntruder(_ face: FaceInfo, config: DetectionConfig) -> Bool {
        // Distance gate — far-away faces can't read the screen.
        guard face.area >= config.minIntruderArea else { return false }
        // Quality gate — smeared/partial/reflection faces.
        guard face.quality >= config.minQuality else { return false }
        // Static-suppression gate — posters & photos (never applies to the owner,
        // handled by the caller which only passes non-owner faces here).
        if config.suppressStaticFaces && face.isStaticSuspect { return false }
        // Pose gate — looking at the screen ≈ facing the camera above it.
        switch (face.yawRad, face.pitchRad) {
        case let (yaw?, pitch?):
            guard abs(yaw) <= config.maxYawRad, abs(pitch) <= config.maxPitchRad else { return false }
        default:
            if config.requireKnownPose { return false }
        }
        return true
    }
}
