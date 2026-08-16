import Foundation

/// Hysteresis state machine over per-frame intruder assessments.
///
///     off → starting → monitoring ⇄ suspicious →(3 intruder frames)→ alert
///     alert →(12 clean frames)→ cooldown →(4 s quiet)→ monitoring
///     cooldown →(2 intruder frames)→ alert   // fast re-trigger
///
/// Entering alert at ~0.3 s feels instant yet ignores single-frame flicker; the slow
/// exit (~1.2 s) keeps brief occlusions from flapping the privacy shield; cooldown
/// re-triggers fast when the peeker comes back.
///
/// Not thread-safe by itself — confine to one queue (MainActor in the app, direct
/// calls in tests).
public final class DetectionStateMachine: @unchecked Sendable {

    public private(set) var state: DetectionState = .off

    /// Fired synchronously on transitions. `trigger` is the assessment that caused an
    /// alert entry (nil for other transitions).
    public var onTransition: ((_ from: DetectionState, _ to: DetectionState, _ trigger: Assessment?) -> Void)?

    private var config: DetectionConfig
    private var intruderStreak = 0
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
                intruderStreak = 1
                cleanStreak = 0
                transition(to: .suspicious, trigger: assessment)
            }
        case .suspicious:
            if intruderPresent {
                intruderStreak += 1
                if intruderStreak >= config.enterFrames {
                    resetCounters()
                    transition(to: .alert, trigger: assessment)
                }
            } else {
                resetCounters()
                transition(to: .monitoring, trigger: nil)
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
                intruderStreak += 1
                cleanStreak = 0
                if intruderStreak >= config.cooldownEnterFrames {
                    resetCounters()
                    transition(to: .alert, trigger: assessment)
                }
            } else {
                intruderStreak = 0
                if let began = cooldownBegan, timestamp - began >= config.cooldownSeconds {
                    transition(to: .monitoring, trigger: nil)
                }
            }
        }
    }

    private func resetCounters() {
        intruderStreak = 0
        cleanStreak = 0
    }

    private func transition(to newState: DetectionState, trigger: Assessment?) {
        guard newState != state else { return }
        let old = state
        state = newState
        onTransition?(old, newState, trigger)
    }
}
