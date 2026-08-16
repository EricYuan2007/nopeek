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
    // V2 owner recognition
    ("v2 owner by identity not size", testV2OwnerAnchoredByIdentityNotSize),
    ("v2 stranger alone alerts", testV2StrangerAloneAlerts),
    ("v2 owner alone quiet", testV2OwnerAloneIsQuiet),
    ("v2 disabled → heuristic", testV2DisabledFallsBackToHeuristic),
    ("v2 no distances → heuristic", testV2NoDistancesFallsBackToHeuristic),
    ("v2 threshold boundary", testV2ThresholdBoundary),
    ("v2 verdict wins over raw distance", testV2VerdictWinsOverRawDistance),
    ("v2 stranger verdict wins too", testV2StrangerVerdictWinsToo),
    ("v2 verdict-only frame stays v2", testV2VerdictParticipatesInIdentityPresence),
    // PoseBins (guided enrollment)
    ("pose bins center", testPoseBinsCenter),
    ("pose bins sectors", testPoseBinsSectors),
    ("pose bins rejects", testPoseBinsRejects),
    // DetectionStateMachine
    ("boots to monitoring", testMachineBootsToMonitoring),
    ("flicker never alerts", testMachineFlickerNeverAlerts),
    ("dropout-tolerant entry", testMachineToleratesSingleDropout),
    ("sustained intruder alerts", testMachineSustainedIntruderAlerts),
    ("slow exit prevents flapping", testMachineSlowExitPreventsFlapping),
    ("cooldown fast retrigger", testMachineCooldownFastRetrigger),
    ("cooldown expires to monitoring", testMachineCooldownExpiresToMonitoring),
    ("disable from alert", testMachineDisableFromAlert),
    ("ignores frames when off", testMachineIgnoresFramesWhenOff),
]

for (name, body) in suites {
    body()
    print("· \(name)")
}
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
