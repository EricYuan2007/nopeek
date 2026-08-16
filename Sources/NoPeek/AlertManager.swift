import AppKit
import UserNotifications

/// Fans one detection episode out to the enabled alert outputs. An episode runs from
/// alertStarted to alertEnded; toggles are read at fire time so changes apply instantly.
@MainActor
final class AlertManager: NSObject {

    private let blurController = PrivacyBlurController()
    private var repeatTimer: Timer?
    /// One notification per episode, re-armed after 5 minutes.
    private var lastNotificationAt: Date = .distantPast

    private(set) var alertActive = false
    private(set) var manualBlurActive = false

    private var settings: SettingsStore { .shared }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Detection episode

    func alertStarted() {
        guard !alertActive else { return }
        alertActive = true

        if settings.alertBlur {
            blurController.show(source: .auto)
        }
        if settings.alertSound {
            playSound()
            scheduleRepeatIfNeeded()
        }
        if settings.alertNotification {
            postNotification()
        }
        // Visual alert (red pulsing indicator) is driven by the status bar itself.
    }

    func alertEnded() {
        guard alertActive else { return }
        alertActive = false
        blurController.hide(source: .auto)
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: - Manual blur ("立即模糊")

    func toggleManualBlur() {
        manualBlurActive.toggle()
        if manualBlurActive {
            blurController.show(source: .manual)
        } else {
            blurController.hide(source: .manual)
        }
        Log.alert.info("manual blur=\(self.manualBlurActive)")
    }

    // MARK: - Owner-absence protection (人一走就模糊)

    /// Independent shield source — never interferes with auto/manual shields.
    func setOwnerAbsentBlur(_ active: Bool) {
        if active {
            blurController.show(source: .ownerAbsent)
        } else {
            blurController.hide(source: .ownerAbsent)
        }
    }

    // MARK: - Sound

    private func playSound() {
        // System sound; a bundled Resources/alert.aiff would drop in here as preferred.
        let sound = NSSound(named: NSSound.Name("Basso"))
        sound?.volume = 0.8
        sound?.play()
    }

    private func scheduleRepeatIfNeeded() {
        let interval = settings.soundRepeatSeconds
        guard interval > 0 else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.alertActive else { return }
                self.playSound()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    // MARK: - Notification

    private func postNotification() {
        let now = Date()
        guard now.timeIntervalSince(lastNotificationAt) > 300 else { return }
        lastNotificationAt = now

        // requestAuthorization returns the existing grant immediately once determined,
        // only prompting the user the first time.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                Log.alert.warning("notification permission not granted — skipping banner")
                return
            }
            Self.deliver()
        }
    }

    private nonisolated static func deliver() {
        let content = UNMutableNotificationContent()
        content.title = "NoPeek 检测到窥屏"
        content.body = "发现有人在你身后看向屏幕。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        Log.alert.info("notification posted")
    }
}

extension AlertManager: UNUserNotificationCenterDelegate {
    /// Accessory apps (LSUIElement) otherwise risk silently dropped banners.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
