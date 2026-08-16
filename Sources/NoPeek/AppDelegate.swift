import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let cameraManager = CameraManager()

    /// Whether monitoring is desired by the user (M4: driven by SettingsStore).
    private var monitoringWanted = true
    /// Whether the camera is currently allowed to run (not locked / not asleep).
    private var lifecycleActive = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("NoPeek launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "NoPeek")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "NoPeek 运行中", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 NoPeek",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu

        cameraManager.onFrame = { _, _ in
            // M2 hooks FaceAnalyzer here.
        }

        registerLifecycleObservers()
        requestCameraAndStart()
    }

    // MARK: - Camera bring-up

    private func requestCameraAndStart() {
        Task {
            let granted = await cameraManager.requestAccess()
            if granted {
                cameraManager.start()
            } else {
                Log.app.warning("camera not authorized — monitoring inactive")
                // M3/M4: reflect noPermission state in the UI + settings deep link.
            }
        }
    }

    // MARK: - Lock / sleep lifecycle
    // The camera LED is the honest privacy signal: stop capturing the moment the user
    // locks the screen or the Mac sleeps, resume when they return.

    private func registerLifecycleObservers() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLifecycleActive(false) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLifecycleActive(true) }
        }
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLifecycleActive(false) }
        }
        wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLifecycleActive(true) }
        }
    }

    private func setLifecycleActive(_ active: Bool) {
        lifecycleActive = active
        Log.app.info("lifecycle active=\(active)")
        updateCameraRunState()
    }

    private func updateCameraRunState() {
        if monitoringWanted && lifecycleActive {
            cameraManager.start()
        } else {
            cameraManager.stop()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        // Process exit tears the session down even if the async stop doesn't land in time.
    }
}
