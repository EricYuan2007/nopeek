import Foundation

/// Hysteresis state machine over per-frame intruder assessments.
///
///     off → starting → monitoring ⇄ suspicious →(score ≥ 3)→ alert
///     alert →(12 clean frames)→ cooldown →(4 s quiet)→ monitoring
///     cooldown →(score ≥ 2)→ alert   // fast re-trigger
///
/// Entry uses a LEAKY BUCKET instead of a strict consecutive streak: a suspicious
/// frame adds +1, a clean frame leaks −1 (floor 0). A sustained intruder still
/// confirms in 3 frames (~0.2 s at burst rate), but one dropped detection mid-
/// sequence no longer resets confirmation to zero (I,I,C,I,I alerts in 5 frames
/// instead of 6) — while a 50%-duty-cycle flicker source oscillates 0↔1 and never
/// alerts, exactly like the old design. The slow exit (~1.2 s) keeps brief
/// occlusions from flapping the privacy shield; cooldown re-triggers fast.
///
/// Not thread-safe by itself — confine to one queue (MainActor in the app, direct
/// calls in tests).
public final class DetectionStateMachine: @unchecked Sendable {

    public private(set) var state: DetectionState = .off

    /// Fired synchronously on transitions. `trigger` is the assessment that caused an
    /// alert entry (nil for other transitions).
    public var onTransition: ((_ from: DetectionState, _ to: DetectionState, _ trigger: Assessment?) -> Void)?

    private var config: DetectionConfig
    private var suspicionScore: Double = 0
    private var cleanStreak = 0
    private var cooldownBegan: TimeInterval?

    public init(config: DetectionConfig = DetectionConfig()) {
        self.config = config
    }

    public func updateConfig(_ config: DetectionConfig) {
        self.config = config
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled {
            guard state == .off else { return }
            transition(to: .starting, trigger: nil)
        } else {
            guard state != .off else { return }
            resetCounters()
            transition(to: .off, trigger: nil)
        }
    }

    /// The camera reports it is actually delivering frames.
    public func notifyCameraRunning() {
        guard state == .starting else { return }
        transition(to: .monitoring, trigger: nil)
    }

    public func handle(_ assessment: Assessment, at timestamp: TimeInterval) {
        let intruderPresent = !assessment.intruders.isEmpty
        switch state {
        case .off, .starting:
            break
        case .monitoring:
            if intruderPresent {
                suspicionScore = 1
                cleanStreak = 0
                transition(to: .suspicious, trigger: assessment)
            }
        case .suspicious:
            if intruderPresent {
                suspicionScore += 1
                if suspicionScore >= Double(config.enterFrames) {
                    resetCounters()
                    transition(to: .alert, trigger: assessment)
                }
            } else {
                suspicionScore = max(0, suspicionScore - config.entryMissPenalty)
                if suspicionScore == 0 {
                    transition(to: .monitoring, trigger: nil)
                }
            }
        case .alert:
            if intruderPresent {
                cleanStreak = 0
            } else {
                cleanStreak += 1
                if cleanStreak >= config.exitFrames {
                    resetCounters()
                    cooldownBegan = timestamp
                    transition(to: .cooldown, trigger: nil)
                }
            }
        case .cooldown:
            if intruderPresent {
                suspicionScore += 1
                cleanStreak = 0
                if suspicionScore >= Double(config.cooldownEnterFrames) {
                    resetCounters()
                    transition(to: .alert, trigger: assessment)
                }
            } else {
                suspicionScore = 0
                if let began = cooldownBegan, timestamp - began >= config.cooldownSeconds {
                    transition(to: .monitoring, trigger: nil)
                }
            }
        }
    }

    private func resetCounters() {
        suspicionScore = 0
        cleanStreak = 0
    }

    private func transition(to newState: DetectionState, trigger: Assessment?) {
        guard newState != state else { return }
        let old = state
        state = newState
        onTransition?(old, newState, trigger)
    }
}
