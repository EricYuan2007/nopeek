import AppKit
import AVFoundation
import SwiftUI

/// First-run (or permission-missing) explainer window: what NoPeek does, the privacy
/// promise, the global hotkeys, and the camera permission action.
@MainActor
final class OnboardingWindowController {

    private var window: NSWindow?

    var onFinished: (() -> Void)?

    func show() {
        if window == nil {
            let view = OnboardingView(onDone: { [weak self] in
                self?.window?.close()
                self?.onFinished?()
            })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "欢迎使用 NoPeek"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct OnboardingView: View {
    var onDone: () -> Void

    private var cameraAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                Text("NoPeek")
                    .font(.largeTitle.bold())
            }

            Text("当有人在你身后窥屏时，NoPeek 会立刻提醒你，并可自动用毛玻璃遮挡整个屏幕。")
                .font(.body)

            VStack(alignment: .leading, spacing: 8) {
                Label("所有画面仅在本机实时分析，绝不存储、上传或联网", systemImage: "lock.shield.fill")
                Label("摄像头指示灯亮 = 正在监控；锁屏/睡眠自动暂停", systemImage: "light.recessed.fill")
                Label("全局快捷键：⌥⌘B 手动模糊 · ⌥⌘P 暂停监控", systemImage: "keyboard")
            }
            .font(.callout)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("摄像头权限").font(.headline)
                    Text(cameraAuthorized ? "已授权 ✓" : "未授权 — 点击右侧按钮授权")
                        .font(.caption)
                        .foregroundStyle(cameraAuthorized ? .secondary : Color.red)
                }
                Spacer()
                if !cameraAuthorized {
                    Button("打开系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("开始使用") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
