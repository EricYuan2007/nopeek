<p align="center">
  <img src="docs/icon.png" width="128" alt="NoPeek 图标">
</p>

<h1 align="center">NoPeek</h1>

<p align="center">
  <strong>macOS 菜单栏应用：当有人在你身后窥屏时，立刻提醒你。</strong><br>
  全本地实时人脸检测 + 机主识别 —— 不联网、不存储、零妥协。
</p>

<p align="center">
  <a href="https://github.com/EricYuan2007/nopeek/releases"><img src="https://img.shields.io/github/v/release/EricYuan2007/nopeek" alt="Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="平台：macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="许可证：MIT"></a>
</p>

<p align="center"><a href="README.md">English Documentation</a></p>

---

## 概述

窥屏（shoulder surfing）是最没有技术含量的攻击方式：有人直接看你的屏幕——在咖啡馆、开放式办公室、图书馆、高铁上。NoPeek 把 Mac 的内置摄像头变成一位安静的守卫：它持续观察你身后的面孔，判断对方是否确实在注视你的屏幕，并在零点几秒内作出反应——菜单栏警示、全屏隐私盾、提示音、系统通知，任意组合，由你选择。

所有计算均在本机神经网络引擎上完成。摄像头帧在内存中同步消费后立即丢弃：不录像、不存储、不上传。应用为纯 Swift 实现（AVFoundation + Vision），零第三方依赖，且**无需 Xcode**——仅 Command Line Tools 即可构建。

## 功能

**检测**

- 720p 实时人脸检测，约 10 fps 分析（eco 模式 6 fps；检测到人脸时突发模式升至 15 fps）
- 每张人脸的完整遥测：包围框面积（距离代理）、yaw/pitch/roll 头部姿态、画面质量分
- **机主识别（V2）**：一次录入后，仅陌生人触发警报——包括你离开座位时他人靠近的情形
- 抗抖动栈：逐轨道 EMA 平滑、姿态门控的身份更新、±0.10 判定迟滞缓冲带、以及容忍短暂面部遮挡的遮挡守卫
- 海报/照片抑制：基于微动分析（印刷人脸不会颤动）

**告警** —— 四个相互独立的通道：

- 菜单栏视觉警报（图标变红并脉冲闪烁）
- 覆盖所有显示器的全屏隐私盾（点击穿透，人走自动解除）
- 提示音
- 系统通知

**离开保护** —— 你离开后隐私盾在可调延时（3–30 秒）内自动升起，你回来时即刻解除。

**悬浮状态芯片** —— 圆角方形小窗，颜色即状态（绿 / 黄 / 红色脉冲 / 灰）。可拖动，贴边自动收成可见标签，单击展开实时预览卡片。

**全局快捷键** —— `⌥⌘B` 手动开关隐私盾（逃逸舱门），`⌥⌘P` 暂停/恢复监控。

**诚实隐私** —— 摄像头指示灯的含义永不打折扣。锁屏、睡眠、合盖时自动停采，回来后自动恢复。

## 工作原理

```
摄像头 @720p → 节流至 10 fps → Vision 管线（每帧）：
  1. VNDetectFaceRectanglesRequest rev3     定位所有人脸（丢弃过小噪点框）
  2. VNDetectFaceLandmarksRequest rev3      级联填充 yaw/pitch/roll 头部姿态
  3. VNDetectFaceCaptureQualityRequest      质量分（过滤模糊/反光人脸）
  4. VNGenerateImageFeaturePrintRequest     （已录入机主时）每脸身份距离 d
           ↓
  FaceTracker：IoU > 0.3 跨帧匹配 → 稳定 trackID；
               4 秒零微动 → 标记为海报/照片脸
           ↓
  身份平滑：逐轨道 EMA 平滑 d（0.55·旧 + 0.45·新）；|yaw| > 30° 或质量 < 0.35 时冻结
            读数；机主/陌生人判定带 ±0.10 迟滞缓冲带；遮挡尖峰最多保持 5 帧
           ↓
  IntruderAssessor（纯函数）：
     V2：判定为「机主」的脸即你本人；其余每张脸过门
     V1（未录入）：面积最大的脸视为你；其余脸过 5 道门：
         距离 ≥ 0.004 归一化面积（≈2.5 m）｜|yaw| ≤ 35°、|pitch| ≤ 30°
         ｜质量 ≥ 0.10｜非静止海报脸｜姿态缺失默认按「面向」计
           ↓
  DetectionStateMachine（漏桶迟滞）：
     监控 →( suspicion 分值达 3，约 0.2–0.3 s )→ 报警 →( 连续 12 帧干净 )→ 冷却(4 s) → 监控
     冷却期内任何闯入立即重新报警
```

误报对策：海报与照片（微动抑制）、远处路人（距离门）、路过而不看屏幕者（朝向门）、单帧抖动（漏桶确认）、你本人外观随光线的漂移（身份缓冲带 + EMA）。已知局限：电视里活动的陌生人脸仍可能触发警报——语义上，它确实在"看"你的屏幕。

**机主识别细节**。录入采用 Face ID 式引导：将脸对准椭圆框并保持 0.8 秒自动开始，随后缓慢转头一圈。应用共采集 11 个特征印迹——正对 3 个 + 8 个姿态扇区各 1 个（覆盖 ±35°），与运行时实际匹配的姿态范围完全对应。样本经 NSSecureCoding 归档后存入 Keychain（ThisDeviceOnly）。匹配取最近样本的 `computeDistance` 距离。调参方法：打开调试浮层（菜单栏 → 调试浮层），观察自己脸上的实时 `d=` 值与 OWNER/STRANGER 标签，再将「识别严格度」滑块调至 *你的 d 值 + 0.15* 左右。

## 隐私设计

- 像素缓冲只在内存中同步消费——**从不写盘、从不保留**
- 无网络请求、无埋点、无沙盒外访问
- 摄像头预览画面只在你主动点开时显示
- 隐私盾启动时悬浮窗按层级设计被盖在盾下——窥屏者看不到预览画面
- 绝不干预系统摄像头指示灯：它是监控状态的诚实信号

## 安装

### 下载发布版

从[最新 Release](https://github.com/EricYuan2007/nopeek/releases) 获取 `NoPeek.app.zip`，解压后打开。二进制为自签名构建，Gatekeeper 会询问一次——右键 → **打开**。

### 从源码构建

需要 macOS 14+ 与 Command Line Tools（`xcode-select --install`）。无需 Xcode，无第三方依赖。

```bash
git clone https://github.com/EricYuan2007/nopeek.git
cd nopeek
make cert   # 一次性：生成稳定的自签名代码签名身份
make run    # 编译、打包、签名、启动
```

> 为什么需要 `make cert`：macOS TCC 把权限授权绑定到代码签名身份。ad-hoc 签名每次编译都会变化，摄像头权限将反复重弹；固定的自签名证书使授权持久有效。证书仅存在于你的本机钥匙串，永不提交进 git。

常用构建目标：

```bash
make log                # 实时结构化日志（人脸数、姿态、状态机迁移）
make test               # NoPeekCore 单元测试（68 项断言）
make icon               # 重新生成应用图标（scripts/make-icon.swift → AppIcon.icns）
make reset-permissions  # 重置摄像头/通知授权，重测首次运行流程
make clean
```

## 使用

1. 通过 `make run`（或打开已安装的应用）启动。应用驻留菜单栏，无 Dock 图标。
2. 按提示授予摄像头权限。图标变绿即开始监控。
3. 从菜单打开**设置**，录入你的脸（引导式环形采集，约 15 秒）。
4. 完成。让朋友从你身后走过即可看到触发效果；打开调试浮层可实时观察判定过程。

## 项目结构

```
Makefile                   # 无 Xcode 构建：swiftc 单模块编译 + .app 组装 + 签名
Resources/Info.plist       # LSUIElement + NSCameraUsageDescription（bundle ID 不可更改）
Resources/AppIcon.icns     # 由 scripts/make-icon.swift 程序化生生成
Sources/
  NoPeekCore/              # 纯逻辑（可单测）：检测类型、五门判定、状态机、人脸跟踪、录入姿态分箱
  NoPeek/                  # App 壳：摄像头管线、Vision 分析、告警、菜单栏、悬浮窗、录入 UI、设置
Tests/NoPeekCoreTests/     # 断言式测试运行器（纯 CLT 环境无 XCTest）
scripts/make-icon.swift    # 程序化图标生成器
```

## 路线图

- 机主样本在线自适应：光线/外观随时间漂移时自动补充高置信度样本，减少重新录入
- 可选替换为专用嵌入模型（MobileFaceNet 类）；`OwnerMatcher` 边界已隔离，替换实现不触碰管线

## 故障排查

| 症状 | 处理 |
|---|---|
| 每次编译后摄像头权限重弹 | 未执行 `make cert`，或更改了 bundle ID（不可更改） |
| 快捷键无响应 | 与其他 App 的 `⌥⌘B`/`⌥⌘P` 冲突；`make log` 会输出注册失败警告 |
| 误报（电视/海报） | 开启静止人脸抑制、调近检测距离、或开启严格朝向模式 |
| 机主本人被误报 | 打开调试浮层读取实时 `d=` 值，相应调高严格度滑块；或在更好光线下重新录入 |
| 彻底重置 | `make reset-permissions`，然后删除应用 |

## 许可证

[MIT](LICENSE) © 2026 EricYuan2007

## 致谢

NoPeek 的设计参考了窥屏检测领域的既有产品（如 EyesOff），并在 Apple Vision 框架之上以零第三方代码独立实现。
