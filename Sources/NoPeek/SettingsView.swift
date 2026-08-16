import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var enrollment = EnrollmentController.shared

    /// area → approximate distance in meters (area ∝ 1/d²; 0.026 ≈ 1 m @720p, 15 cm face).
    private var estimatedMeters: Double {
        (0.026 / settings.minIntruderArea).squareRoot()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                monitoringSection
                ownerSection
                absenceSection
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

    private var ownerSection: some View {
        GroupBox("机主识别") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(enrollment.enrolledSampleCount > 0
                             ? "已录入 \(enrollment.enrolledSampleCount) 个样本"
                             : "未录入机主人脸")
                        Text("录入后只有陌生人出现才报警；你不在场时他人看屏也会报警")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if enrollment.enrolledSampleCount > 0 {
                        Button("重新录入") { enrollment.start() }
                        Button("清除") { enrollment.clearEnrollment() }
                    } else {
                        Button("录入机主人脸…") { enrollment.start() }
                    }
                }

                if enrollment.enrolledSampleCount > 0 {
                    Toggle("启用机主识别", isOn: $settings.ownerRecognitionEnabled)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("识别严格度")
                            Spacer()
                            Text(String(format: "阈值 %.2f（%@）", settings.ownerMaxDistance,
                                        settings.ownerMaxDistance < 0.45 ? "严格" : settings.ownerMaxDistance > 0.6 ? "宽松" : "适中"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.ownerMaxDistance, in: 0.3...0.8, step: 0.05)
                        Text("误录陌生人 → 调低；你自己被误报 → 调高。打开调试浮层可看实时距离 d= 值。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!settings.ownerRecognitionEnabled)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var absenceSection: some View {
        GroupBox("离开保护") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("机主离开时自动模糊屏幕", isOn: $settings.ownerAbsentBlurEnabled)
                HStack {
                    Text("离开多久后触发")
                    Spacer()
                    Text("\(Int(settings.ownerAbsentDelaySeconds)) 秒")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.ownerAbsentDelaySeconds, in: 3...30, step: 1)
                    .disabled(!settings.ownerAbsentBlurEnabled)
                Text("人回来自动恢复。录入机主人脸后识别更精准（设置底部的「机主识别」）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
