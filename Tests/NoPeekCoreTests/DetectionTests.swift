import CoreGraphics
import Foundation

// MARK: - FaceTracker

func testTrackerAssignsStableIDs() {
    let tracker = FaceTracker()
    let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    let f1 = tracker.process([FaceInfo(boundingBox: box)], at: 0)
    let f2 = tracker.process([FaceInfo(boundingBox: box.offsetBy(dx: 0.01, dy: 0))], at: 0.1)
    expectEqual(f1.count, 1)
    expectEqual(f2.count, 1)
    expectEqual(f2[0].trackID, f1[0].trackID, "same face across frames keeps its trackID")
}

func testTrackerNewFaceGetsNewID() {
    let tracker = FaceTracker()
    let near = FaceInfo(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
    let far = FaceInfo(boundingBox: CGRect(x: 0.7, y: 0.6, width: 0.2, height: 0.2))
    let out = tracker.process([near, far], at: 0)
    expectEqual(Set(out.map(\.trackID)).count, 2, "two distinct faces → two tracks")
}

func testTrackerFlagsStaticFaces() {
    let tracker = FaceTracker()
    let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    var last: [FaceInfo] = []
    // A perfectly motionless "printed" face held for 5 seconds.
    for i in 0...50 {
        last = tracker.process([FaceInfo(boundingBox: box)], at: TimeInterval(i) / 10)
    }
    expect(last[0].isStaticSuspect, "motionless face older than 4s is a static suspect")
}

func testTrackerDoesNotFlagRealHeads() {
    let tracker = FaceTracker()
    var last: [FaceInfo] = []
    // Same face with realistic micro-jitter (±0.005 normalized) over 5 seconds.
    for i in 0...50 {
        let t = TimeInterval(i) / 10
        let jitter = CGFloat(i % 7) * 0.0015 - 0.0045
        let box = CGRect(x: 0.4 + jitter, y: 0.4 - jitter, width: 0.2 + jitter, height: 0.2)
        last = tracker.process([FaceInfo(boundingBox: box)], at: t)
    }
    expect(!last[0].isStaticSuspect, "micro-moving face is never a static suspect")
}

func testTrackerPrunesStaleTracks() {
    let tracker = FaceTracker()
    let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    let first = tracker.process([FaceInfo(boundingBox: box)], at: 0)
    _ = tracker.process([], at: 3) // 3 s gap > maxTrackGap — old track pruned
    let later = tracker.process([FaceInfo(boundingBox: box)], at: 3.1)
    expect(later[0].trackID != first[0].trackID, "reappearing face after a gap gets a fresh trackID")
}

func testIoU() {
    let a = CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
    expectEqual(FaceTracker.iou(a, a), 1.0)
    expectEqual(FaceTracker.iou(a, a.offsetBy(dx: 0.3, dy: 0)), 0.0)
    let halfOverlap = FaceTracker.iou(a, a.offsetBy(dx: 0.1, dy: 0))
    expect(abs(halfOverlap - 1.0 / 3.0) < 0.001, "half-shifted box IoU ≈ 1/3, got \(halfOverlap)")
}

// MARK: - IntruderAssessor

private func makeFace(area: CGFloat, yaw: CGFloat? = 0, pitch: CGFloat? = 0,
                      quality: Float = 0.5, static: Bool = false,
                      trackID: Int = 0, ownerDistance: Float? = nil,
                      isOwner: Bool? = nil) -> FaceInfo {
    let side = area.squareRoot()
    return FaceInfo(trackID: trackID,
                    boundingBox: CGRect(x: 0.5 - side / 2, y: 0.5 - side / 2, width: side, height: side),
                    yawRad: yaw, pitchRad: pitch, quality: quality, isStaticSuspect: `static`,
                    ownerDistance: ownerDistance, isOwner: isOwner)
}

func testAssessorSingleFaceIsOwner() {
    let result = IntruderAssessor.assess(faces: [makeFace(area: 0.05)], config: DetectionConfig())
    expect(result.owner != nil)
    expectEqual(result.intruders.count, 0, "one face = owner, no intruder")
}

func testAssessorSecondFaceIsIntruder() {
    let faces = [makeFace(area: 0.05), makeFace(area: 0.01)]
    let result = IntruderAssessor.assess(faces: faces, config: DetectionConfig())
    expectEqual(result.intruders.count, 1, "second facing face nearby → intruder")
    expect(abs((result.owner?.area ?? 0) - 0.05) < 1e-9, "largest face is the owner")
}

func testAssessorDistanceGate() {
    var config = DetectionConfig()
    config.minIntruderArea = 0.004
    let farFace = makeFace(area: 0.001) // ~4+ m away
    let result = IntruderAssessor.assess(faces: [makeFace(area: 0.05), farFace], config: config)
    expectEqual(result.intruders.count, 0, "tiny far-away face is gated by distance")
}

func testAssessorPoseGate() {
    let profile = makeFace(area: 0.01, yaw: 0.9, pitch: 0) // ~52° to the side
    let result = IntruderAssessor.assess(faces: [makeFace(area: 0.05), profile], config: DetectionConfig())
    expectEqual(result.intruders.count, 0, "profile face (looking away) is gated by pose")
}

func testAssessorUnknownPoseCountsAsFacing() {
    let noPose = makeFace(area: 0.01, yaw: nil, pitch: nil)
    let result = IntruderAssessor.assess(faces: [makeFace(area: 0.05), noPose], config: DetectionConfig())
    expectEqual(result.intruders.count, 1, "unknown pose counts as facing (fail toward alerting)")

    var strict = DetectionConfig()
    strict.requireKnownPose = true
    let strictResult = IntruderAssessor.assess(faces: [makeFace(area: 0.05), noPose], config: strict)
    expectEqual(strictResult.intruders.count, 0, "strict mode requires known pose")
}

func testAssessorQualityGate() {
    let blurry = makeFace(area: 0.01, quality: 0.05)
    let result = IntruderAssessor.assess(faces: [makeFace(area: 0.05), blurry], config: DetectionConfig())
    expectEqual(result.intruders.count, 0, "low-quality face is gated")
}

func testAssessorStaticSuppression() {
    let poster = makeFace(area: 0.01, static: true)
    let result = IntruderAssessor.assess(faces: [makeFace(area: 0.05), poster], config: DetectionConfig())
    expectEqual(result.intruders.count, 0, "static suspect (poster) suppressed")

    var allow = DetectionConfig()
    allow.suppressStaticFaces = false
    let allowed = IntruderAssessor.assess(faces: [makeFace(area: 0.05), poster], config: allow)
    expectEqual(allowed.intruders.count, 1, "suppression disabled → poster counts again")
}

func testAssessorOwnerNeverStaticSuppressed() {
    // Pathological: owner's own face flagged static (e.g. user froze for a photo) —
    // owner stays owner regardless; suppression only gates intruders.
    let faces = [makeFace(area: 0.05, static: true, trackID: 1), makeFace(area: 0.01, trackID: 2)]
    let result = IntruderAssessor.assess(faces: faces, config: DetectionConfig())
    expectEqual(result.intruders.count, 1)
}

// MARK: - V2 owner recognition

private func v2Config(threshold: Float = 0.5) -> DetectionConfig {
    var config = DetectionConfig()
    config.ownerRecognitionEnabled = true
    config.ownerMaxDistance = threshold
    return config
}

func testV2OwnerAnchoredByIdentityNotSize() {
    // The owner's face is SMALLER (leaning back) than the stranger's — V1 would
    // anchor the stranger; V2 must anchor by identity.
    let faces = [
        makeFace(area: 0.01, trackID: 1, ownerDistance: 0.30), // owner, smaller
        makeFace(area: 0.05, trackID: 2, ownerDistance: 0.90), // stranger, bigger
    ]
    let result = IntruderAssessor.assess(faces: faces, config: v2Config())
    expectEqual(result.owner?.trackID, 1, "owner anchored by identity")
    expectEqual(result.intruders.count, 1, "the bigger stranger is the intruder")
    expectEqual(result.intruders.first?.trackID, 2)
}

func testV2StrangerAloneAlerts() {
    // Owner absent: the lone face matches nobody → stranger → intruder.
    let faces = [makeFace(area: 0.02, trackID: 1, ownerDistance: 0.85)]
    let result = IntruderAssessor.assess(faces: faces, config: v2Config())
    expect(result.owner == nil, "no face under threshold → no owner")
    expectEqual(result.intruders.count, 1, "owner absent + stranger ⇒ alert")
}

func testV2OwnerAloneIsQuiet() {
    let faces = [makeFace(area: 0.02, trackID: 1, ownerDistance: 0.25)]
    let result = IntruderAssessor.assess(faces: faces, config: v2Config())
    expectEqual(result.owner?.trackID, 1)
    expectEqual(result.intruders.count, 0)
}

func testV2DisabledFallsBackToHeuristic() {
    // Recognition off → distances ignored, largest face is owner.
    let faces = [
        makeFace(area: 0.01, trackID: 1, ownerDistance: 0.30),
        makeFace(area: 0.05, trackID: 2, ownerDistance: 0.90),
    ]
    let result = IntruderAssessor.assess(faces: faces, config: DetectionConfig())
    expectEqual(result.owner?.trackID, 2, "V1: largest face is owner")
    expectEqual(result.intruders.first?.trackID, 1)
}

func testV2NoDistancesFallsBackToHeuristic() {
    // Recognition on but this frame computed no distances (feature print failed) →
    // graceful V1 behavior rather than flagging everyone.
    let faces = [makeFace(area: 0.05, trackID: 1), makeFace(area: 0.01, trackID: 2)]
    let result = IntruderAssessor.assess(faces: faces, config: v2Config())
    expectEqual(result.owner?.trackID, 1)
    expectEqual(result.intruders.count, 1)
}

func testV2ThresholdBoundary() {
    let faces = [
        makeFace(area: 0.03, trackID: 1, ownerDistance: 0.49),
        makeFace(area: 0.02, trackID: 2, ownerDistance: 0.51),
    ]
    let result = IntruderAssessor.assess(faces: faces, config: v2Config(threshold: 0.5))
    expectEqual(result.owner?.trackID, 1, "0.49 < 0.5 → owner")
    expectEqual(result.intruders.count, 1, "0.51 > 0.5 → stranger")
}

func testV2VerdictWinsOverRawDistance() {
    // Regression test for the live-observed false alert: the owner's own frontal
    // distance hovered at the threshold (d 0.47→0.51 @ nominal 0.5) and crossed it.
    // The analyzer's deadband verdict (isOwner=true) must win over the raw distance.
    let faces = [makeFace(area: 0.02, trackID: 1, ownerDistance: 0.51, isOwner: true)]
    let result = IntruderAssessor.assess(faces: faces, config: v2Config(threshold: 0.5))
    expectEqual(result.owner?.trackID, 1, "verdict owner despite d over nominal threshold")
    expectEqual(result.intruders.count, 0, "no false alert from threshold hover")
}

func testV2StrangerVerdictWinsToo() {
    // Symmetric: a face under the raw threshold but verdict-stranger stays a stranger
    // (e.g. verdict established at high distance, distance now held in the deadband).
    let faces = [makeFace(area: 0.02, trackID: 1, ownerDistance: 0.48, isOwner: false)]
    let result = IntruderAssessor.assess(faces: faces, config: v2Config(threshold: 0.5))
    expect(result.owner == nil, "verdict stranger despite d under nominal threshold")
    expectEqual(result.intruders.count, 1)
}

func testV2VerdictParticipatesInIdentityPresence() {
    // A frame whose ONLY identity info is a verdict (no distance — e.g. distance
    // pruned but verdict held) must still take the V2 path, not the V1 fallback.
    let faces = [
        makeFace(area: 0.01, trackID: 1, isOwner: true),   // owner, smaller
        makeFace(area: 0.05, trackID: 2),                  // no identity info at all
    ]
    let result = IntruderAssessor.assess(faces: faces, config: v2Config())
    expectEqual(result.owner?.trackID, 1, "verdict-only owner anchors")
    expectEqual(result.intruders.count, 1)
}
