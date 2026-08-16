import Foundation

// Test functions are plain top-level funcs, enumerated here explicitly.
// (XCTest is unavailable without full Xcode — this runner replaces it.)
let suites: [(String, () -> Void)] = [
    // FaceTracker
    ("tracker stable ids", testTrackerAssignsStableIDs),
    ("tracker new face new id", testTrackerNewFaceGetsNewID),
    ("tracker flags static faces", testTrackerFlagsStaticFaces),
    ("tracker ignores real-head jitter", testTrackerDoesNotFlagRealHeads),
    ("tracker prunes stale tracks", testTrackerPrunesStaleTracks),
    ("IoU math", testIoU),
    // IntruderAssessor
    ("single face is owner", testAssessorSingleFaceIsOwner),
    ("second face is intruder", testAssessorSecondFaceIsIntruder),
    ("distance gate", testAssessorDistanceGate),
    ("pose gate", testAssessorPoseGate),
    ("unknown pose policy", testAssessorUnknownPoseCountsAsFacing),
    ("quality gate", testAssessorQualityGate),
    ("static suppression", testAssessorStaticSuppression),
    ("owner never static-suppressed", testAssessorOwnerNeverStaticSuppressed),
]

for (name, body) in suites {
    body()
    print("· \(name)")
}
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
