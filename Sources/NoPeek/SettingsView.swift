import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    /// area → approximate distance in meters (area ∝ 1/d²; 0.026 ≈ 1 m @720p, 15 cm face).
    private var estimatedMeters: Double {
        (0.026 / settings.minIntruderArea).squareRoot()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                monitoringSection
                alertsSection
                bubbleSection
                permissionSection
                privacyNote
            }
            .padding(16)
        }
        // Explicit size: Form+NSHostingController can collapse to a broken minimal
        // window on some macOS versions; a fixed frame renders deterministically.
        .frame(width: 500, height: 640)
    }

    private var monitoringSection: some View {
        GroupBox("监控") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用监控", isOn: $settings.monitoringEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("检测距离")
                        Spacer()
                        Text("约 \(estimatedMeters, specifier: "%.1f") 米以内")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.minIntruderArea, in: 0.002...0.012)
                    Text("只在闯入者足够接近（能看清屏幕）时报警")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("低功耗模式（6 fps 分析）", isOn: $settings.ecoMode)
                Toggle("严格朝向模式", isOn: $settings.strictPoseMode)
                Toggle("抑制静止人脸（海报/照片）", isOn: $settings.suppressStaticFaces)
            }
            .padding(.vertical, 6)
        }
    }

    private var alertsSection: some View {
        GroupBox("检测到窥屏时") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("视觉警报（菜单栏图标变红闪烁）", isOn: $settings.alertVisual)
                Toggle("全屏隐私模糊", isOn: $settings.alertBlur)
                Toggle("提示音", isOn: $settings.alertSound)
                Toggle("系统通知", isOn: $settings.alertNotification)
            }
            .padding(.vertical, 6)
        }
    }

    private var bubbleSection: some View {
        GroupBox("悬浮窗") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("显示悬浮小窗", isOn: $settings.bubbleVisible)
                Toggle("固定在原位（不自动隐藏）", isOn: $settings.bubblePinned)
            }
            .padding(.vertical, 6)
        }
    }

    private var permissionSection: some View {
        GroupBox("权限") {
            VStack(alignment: .leading, spacing: 10) {
                cameraPermissionRow
            }
            .padding(.vertical, 6)
        }
    }

    private var cameraPermissionRow: some View {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("摄像头")
                Text(status == .authorized ? "已授权" : "未授权 — 需要摄像头才能检测")
                    .font(.caption)
                    .foregroundStyle(status == .authorized ? Color.secondary : Color.red)
            }
            Spacer()
            if status != .authorized {
                Button("打开系统设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var privacyNote: some View {
        Text("所有画面仅在本机实时分析，绝不存储、上传或联网。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
