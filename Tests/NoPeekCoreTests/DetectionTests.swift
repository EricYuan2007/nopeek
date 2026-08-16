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
                      quality: Float = 0.5, static: Bool = false) -> FaceInfo {
    let side = area.squareRoot()
    return FaceInfo(boundingBox: CGRect(x: 0.5 - side / 2, y: 0.5 - side / 2, width: side, height: side),
                    yawRad: yaw, pitchRad: pitch, quality: quality, isStaticSuspect: `static`)
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
    let faces = [makeFace(area: 0.05, static: true), makeFace(area: 0.01)]
    let result = IntruderAssessor.assess(faces: faces, config: DetectionConfig())
    expectEqual(result.intruders.count, 1)
}
