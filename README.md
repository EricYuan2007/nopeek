<p align="center">
  <img src="docs/icon.png" width="128" alt="NoPeek icon">
</p>

<h1 align="center">NoPeek</h1>

<p align="center">
  <strong>A macOS menu-bar app that alerts you the moment someone peeks at your screen.</strong><br>
  Real-time, on-device face detection with owner recognition — no network, no storage, no compromise.
</p>

<p align="center">
  <a href="https://github.com/EricYuan2007/nopeek/releases"><img src="https://img.shields.io/github/v/release/EricYuan2007/nopeek" alt="Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="Platform: macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT"></a>
</p>

<p align="center"><a href="README_zh-CN.md">简体中文文档</a></p>

---

## Overview

Shoulder surfing is the most low-tech attack there is: someone simply looks at your screen — in a café, an open office, a library, on a train. NoPeek turns your Mac's built-in camera into a quiet guard. It watches for faces behind you, decides whether they are actually looking at your screen, and reacts within a fraction of a second: a menu-bar warning, a full-screen privacy shield, a sound, a notification — or any combination you choose.

Everything runs locally on the Neural Engine. Camera frames are consumed in memory and discarded immediately; nothing is recorded, stored, or transmitted. The app is pure Swift (AVFoundation + Vision) with zero third-party dependencies, and it builds without Xcode — Command Line Tools are all you need.

## Features

**Detection**

- Real-time face detection at 720p, ~10 fps analysis (6 fps eco mode, 15 fps burst mode when a face appears)
- Per-face telemetry: bounding-box area (distance proxy), yaw/pitch/roll head pose, capture quality
- **Owner recognition (V2)**: enroll once, and only strangers trigger alerts — including when you are away from the desk and someone else walks up
- Anti-jitter stack: per-track EMA smoothing, pose-gated identity updates, a ±0.10 verdict deadband, and an occlusion guard that tolerates a partially covered face
- Poster/photo suppression via micro-motion analysis (a printed face doesn't fidget)

**Alerts** — four independently toggleable channels:

- Menu-bar visual alarm (icon turns red and pulses)
- Full-screen privacy shield on every display (click-through, auto-dismisses when the coast is clear)
- Alert sound
- System notification

**Away protection** — if you leave, the shield rises automatically after a configurable delay (3–30 s) and drops the moment you return.

**Floating status chip** — a small rounded-square panel whose color mirrors the state (green / yellow / pulsing red / gray). Draggable, docks to screen edges as a visible tab, expands on click into a live camera preview card.

**Global hotkeys** — `⌥⌘B` toggles the privacy shield manually (your escape hatch), `⌥⌘P` pauses/resumes monitoring.

**Honest privacy** — the camera indicator LED means what it says. Capture stops automatically on lock screen, sleep, or lid close, and resumes when you do.

## How It Works

```
Camera @720p → throttled to 10 fps → Vision pipeline (per frame):
  1. VNDetectFaceRectanglesRequest rev3     locate all faces (drop tiny noise boxes)
  2. VNDetectFaceLandmarksRequest rev3      cascade-fills yaw/pitch/roll head pose
  3. VNDetectFaceCaptureQualityRequest      quality score (filters blurry/glare faces)
  4. VNGenerateImageFeaturePrintRequest     identity distance d per face (when enrolled)
           ↓
  FaceTracker: IoU > 0.3 cross-frame matching → stable trackIDs;
               4 s without micro-motion → flagged as a poster/photo
           ↓
  Identity smoothing: per-track EMA on d (0.55·prev + 0.45·raw); readings frozen while
               |yaw| > 30° or quality < 0.35; owner/stranger verdict hysteresis of
               ±0.10 around the threshold; occlusion spikes held for up to 5 frames
           ↓
  IntruderAssessor (pure function):
     V2: a face with an "owner" verdict is you; every other face is gated
     V1 (no enrollment): the largest face is assumed to be you; the rest pass 5 gates:
         distance ≥ 0.004 normalized area (≈2.5 m)  |  |yaw| ≤ 35°, |pitch| ≤ 30°
         |  quality ≥ 0.10  |  not a static poster  |  missing pose counts as facing
           ↓
  DetectionStateMachine (leaky-bucket hysteresis):
     monitoring →(suspicion score 3, ~0.2–0.3 s)→ alert →(12 clean frames)→ cooldown (4 s) → monitoring
     any intrusion during cooldown re-alerts immediately
```

False-positive countermeasures: posters and photos (micro-motion suppression), distant passers-by (distance gate), people walking past without looking (pose gate), single-frame flicker (leaky-bucket confirmation), and drift in your own appearance (identity deadband + EMA). Known limitation: a moving face on TV can still trigger an alert — semantically, it *is* watching your screen.

**Owner recognition in detail.** Enrollment is Face-ID-style: center your face in the oval guide and hold still for 0.8 s to auto-start, then slowly turn your head in a circle. The app collects 11 feature prints — 3 frontal + 1 per pose sector (8 sectors covering ±35°) — matching the exact pose range used at runtime. Samples are archived with NSSecureCoding and stored in the Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly). Matching takes the nearest-sample `computeDistance`. To tune: open the debug overlay (menu bar → Debug Overlay), watch the live `d=` value and OWNER/STRANGER label on your own face, then set the recognition-strictness slider to roughly *your d + 0.15*.

## Privacy

- Pixel buffers are consumed synchronously in memory — **never written to disk, never retained**
- No network requests, no analytics, no sandbox escapes
- The camera preview is shown only when you explicitly open it
- While the privacy shield is up, the floating panel sits *below* it by design — a peeker never sees the preview
- The system camera indicator is never interfered with; it is the honest signal that monitoring is active

## Installation

### Download a release

Grab `NoPeek.app.zip` from the [latest release](https://github.com/EricYuan2007/nopeek/releases), unzip, and open it. The binary is self-signed, so Gatekeeper will ask once — right-click → **Open**.

### Build from source

Requires macOS 14+ and Command Line Tools (`xcode-select --install`). No Xcode, no dependencies.

```bash
git clone https://github.com/EricYuan2007/nopeek.git
cd nopeek
make cert   # one-time: mint a stable self-signed code-signing identity
make run    # build, package, sign, launch
```

> Why `make cert`: macOS TCC binds permission grants to the code-signing identity. Ad-hoc signatures change on every recompile, so the camera permission would re-prompt after every build. A stable self-signed certificate makes the grant stick. The certificate lives only in your local keychain and is never committed to git.

Useful targets:

```bash
make log                # live structured logs (face count, pose, state transitions)
make test               # NoPeekCore unit tests (68 assertions)
make icon               # regenerate the app icon (scripts/make-icon.swift → AppIcon.icns)
make reset-permissions  # reset camera/notification grants to retest the first-run flow
make clean
```

## Usage

1. Launch via `make run` (or open the installed app). It lives in the menu bar — no Dock icon.
2. Grant camera access when prompted. The icon turns green: monitoring.
3. Open **Settings** from the menu and enroll your face (takes ~15 seconds with the guided ring).
4. Done. Have a friend walk up behind you to see it fire; use the debug overlay to watch the reasoning live.

## Project Structure

```
Makefile                   # no-Xcode build: single-module swiftc + .app assembly + codesign
Resources/Info.plist       # LSUIElement + NSCameraUsageDescription (bundle ID is load-bearing)
Resources/AppIcon.icns     # generated by scripts/make-icon.swift
Sources/
  NoPeekCore/              # pure logic, unit-testable: detection types, 5-gate assessor,
                           # state machine, face tracker, enrollment pose bins
  NoPeek/                  # app shell: camera pipeline, Vision analysis, alerts, menu bar,
                           # floating chip, enrollment UI, settings
Tests/NoPeekCoreTests/     # assertion-based runner (no XCTest under plain CLT)
scripts/make-icon.swift    # programmatic icon generator
```

## Roadmap

- Online adaptation of owner samples: supplement high-confidence samples as lighting/appearance drift, reducing re-enrollment
- Optional swap to a dedicated embedding model (MobileFaceNet-class); the `OwnerMatcher` boundary is isolated, so the pipeline is untouched

## Troubleshooting

| Symptom | Fix |
|---|---|
| Camera permission re-prompts after every build | You skipped `make cert`, or the bundle ID was changed (don't) |
| Hotkeys do nothing | Another app owns `⌥⌘B`/`⌥⌘P`; `make log` prints a registration warning |
| False alerts (TV, posters) | Enable static-face suppression, shorten the detection distance, or enable strict pose mode |
| You yourself trigger alerts | Open the debug overlay, read your live `d=` value, raise the strictness slider accordingly — or re-enroll in better light |
| Nuclear option | `make reset-permissions`, then delete the app |

## License

[MIT](LICENSE) © 2026 EricYuan2007

## Acknowledgments

NoPeek was informed by prior art in the shoulder-surfing-detection space (e.g. EyesOff) and re-implements the idea entirely on Apple's Vision framework with zero third-party code.
