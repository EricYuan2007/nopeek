import Foundation

/// All user-tunable settings, persisted to UserDefaults on every change.
///
/// ObservableObject (not @Observable) so SwiftUI binds with `$` AND the AppKit side
/// gets a single `onChange` callback from each didSet — no observation bridging.
@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    /// Invoked on every change — AppDelegate re-pushes config/run-state from here.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    private enum Key {
        static let monitoringEnabled = "monitoringEnabled"
        static let alertVisual = "alertVisual"
        static let alertBlur = "alertBlur"
        static let alertSound = "alertSound"
        static let alertNotification = "alertNotification"
        static let soundRepeatSeconds = "soundRepeatSeconds"
        static let minIntruderArea = "minIntruderArea"
        static let strictPoseMode = "strictPoseMode"
        static let suppressStaticFaces = "suppressStaticFaces"
        static let ecoMode = "ecoMode"
        static let bubbleVisible = "bubbleVisible"
        static let bubblePinned = "bubblePinned"
        static let bubbleX = "bubbleX"
        static let bubbleY = "bubbleY"
        static let ownerAbsentBlurEnabled = "ownerAbsentBlurEnabled"
        static let ownerAbsentDelaySeconds = "ownerAbsentDelaySeconds"
    }

    // MARK: - Monitoring

    @Published var monitoringEnabled = true { didSet { persist(Key.monitoringEnabled, monitoringEnabled) } }
    /// Intruder distance gate as normalized bbox area. 0.002 ≈ 3.5 m … 0.012 ≈ 1.4 m.
    @Published var minIntruderArea = 0.004 { didSet { persist(Key.minIntruderArea, minIntruderArea) } }
    /// Require a known head pose to alert (fewer false alerts, more misses).
    @Published var strictPoseMode = false { didSet { persist(Key.strictPoseMode, strictPoseMode) } }
    /// Suppress poster/photo faces (tracked, zero micro-motion).
    @Published var suppressStaticFaces = true { didSet { persist(Key.suppressStaticFaces, suppressStaticFaces) } }
    /// 6 fps instead of 10 fps analysis — halves Vision energy use.
    @Published var ecoMode = false { didSet { persist(Key.ecoMode, ecoMode) } }

    // MARK: - Alert outputs (each independently toggleable)

    @Published var alertVisual = true { didSet { persist(Key.alertVisual, alertVisual) } }
    @Published var alertBlur = true { didSet { persist(Key.alertBlur, alertBlur) } }
    @Published var alertSound = true { didSet { persist(Key.alertSound, alertSound) } }
    @Published var alertNotification = true { didSet { persist(Key.alertNotification, alertNotification) } }
    /// 0 = single ping per episode; >0 = repeat every N seconds while alerting.
    @Published var soundRepeatSeconds = 0.0 { didSet { persist(Key.soundRepeatSeconds, soundRepeatSeconds) } }

    // MARK: - Owner-absence protection (人一走就模糊)

    /// Blur the whole screen when no owner face has been seen for a while.
    /// V1: "owner" = largest face, so this fires when the camera sees nobody.
    /// V2 (with enrollment): fires when the enrolled owner isn't in view.
    @Published var ownerAbsentBlurEnabled = false { didSet { persist(Key.ownerAbsentBlurEnabled, ownerAbsentBlurEnabled) } }
    /// Seconds without an owner face before the shield goes up.
    @Published var ownerAbsentDelaySeconds = 5.0 { didSet { persist(Key.ownerAbsentDelaySeconds, ownerAbsentDelaySeconds) } }

    // MARK: - Floating bubble (M5)

    @Published var bubbleVisible = true { didSet { persist(Key.bubbleVisible, bubbleVisible) } }
    @Published var bubblePinned = false { didSet { persist(Key.bubblePinned, bubblePinned) } }
    /// Last bubble position; NaN = never placed (default corner).
    @Published var bubbleX = Double.nan { didSet { persist(Key.bubbleX, bubbleX) } }
    @Published var bubbleY = Double.nan { didSet { persist(Key.bubbleY, bubbleY) } }

    private init() {
        defaults.register(defaults: [
            Key.monitoringEnabled: true,
            Key.alertVisual: true,
            Key.alertBlur: true,
            Key.alertSound: true,
            Key.alertNotification: true,
            Key.soundRepeatSeconds: 0.0,
            Key.minIntruderArea: 0.004,
            Key.strictPoseMode: false,
            Key.suppressStaticFaces: true,
            Key.ecoMode: false,
            Key.bubbleVisible: true,
            Key.bubblePinned: false,
            Key.bubbleX: Double.nan,
            Key.bubbleY: Double.nan,
            Key.ownerAbsentBlurEnabled: false,
            Key.ownerAbsentDelaySeconds: 5.0,
        ])
        monitoringEnabled = defaults.bool(forKey: Key.monitoringEnabled)
        alertVisual = defaults.bool(forKey: Key.alertVisual)
        alertBlur = defaults.bool(forKey: Key.alertBlur)
        alertSound = defaults.bool(forKey: Key.alertSound)
        alertNotification = defaults.bool(forKey: Key.alertNotification)
        soundRepeatSeconds = defaults.double(forKey: Key.soundRepeatSeconds)
        minIntruderArea = defaults.double(forKey: Key.minIntruderArea)
        strictPoseMode = defaults.bool(forKey: Key.strictPoseMode)
        suppressStaticFaces = defaults.bool(forKey: Key.suppressStaticFaces)
        ecoMode = defaults.bool(forKey: Key.ecoMode)
        bubbleVisible = defaults.bool(forKey: Key.bubbleVisible)
        bubblePinned = defaults.bool(forKey: Key.bubblePinned)
        bubbleX = defaults.double(forKey: Key.bubbleX)
        bubbleY = defaults.double(forKey: Key.bubbleY)
        ownerAbsentBlurEnabled = defaults.bool(forKey: Key.ownerAbsentBlurEnabled)
        ownerAbsentDelaySeconds = defaults.double(forKey: Key.ownerAbsentDelaySeconds)
    }

    private func persist(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}
