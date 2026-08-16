import CoreGraphics
import Foundation

// MARK: - DetectionStateMachine

private func makeAssessment(intruders: Int) -> Assessment {
    let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    let face = FaceInfo(boundingBox: box)
    return Assessment(owner: face,
                      intruders: Array(repeating: face, count: intruders),
                      faceCount: intruders + 1)
}

/// Heap box so the machine's escaping onTransition closure can record safely.
private final class TransitionLog {
    var states: [DetectionState] = []
}

/// Machine already in `.monitoring`, with transitions recorded into `log`.
private func bootedMachine(_ log: TransitionLog) -> DetectionStateMachine {
    let machine = DetectionStateMachine()
    machine.onTransition = { _, to, _ in log.states.append(to) }
    machine.setEnabled(true)
    machine.notifyCameraRunning()
    return machine
}

private func feed(_ machine: DetectionStateMachine, _ pattern: [Bool], start: TimeInterval = 0) {
    for (i, intruder) in pattern.enumerated() {
        machine.handle(makeAssessment(intruders: intruder ? 1 : 0), at: start + TimeInterval(i) * 0.1)
    }
}

func testMachineBootsToMonitoring() {
    let log = TransitionLog()
    _ = bootedMachine(log)
    expectEqual(log.states, [.starting, .monitoring])
}

func testMachineFlickerNeverAlerts() {
    let log = TransitionLog()
    let machine = bootedMachine(log)
    // Isolated 1–2 frame blips must never reach alert (enterFrames = 3).
    feed(machine, [true, false, true, true, false, true, false, true, true, false])
    expect(!log.states.contains(.alert), "flicker must not alert — got \(log.states.map(\.rawValue))")
    expectEqual(machine.state, .monitoring)
}

func testMachineSustainedIntruderAlerts() {
    let log = TransitionLog()
    let machine = bootedMachine(log)
    feed(machine, [true, true, true])
    expectEqual(machine.state, .alert, "3 consecutive intruder frames → alert (~0.3 s)")
}

func testMachineSlowExitPreventsFlapping() {
    let log = TransitionLog()
    let machine = bootedMachine(log)
    feed(machine, [true, true, true])                             // → alert
    feed(machine, Array(repeating: false, count: 11), start: 0.3) // 11 clean < exitFrames=12
    expectEqual(machine.state, .alert, "brief occlusion must not clear the alert")
    feed(machine, [false], start: 1.4)                            // 12th clean frame
    expectEqual(machine.state, .cooldown)
}

func testMachineCooldownFastRetrigger() {
    let log = TransitionLog()
    let machine = bootedMachine(log)
    feed(machine, [true, true, true])
    feed(machine, Array(repeating: false, count: 12), start: 0.3) // → cooldown at 1.4
    expectEqual(machine.state, .cooldown)
    feed(machine, [true, true], start: 1.5)                       // 2 frames in cooldown
    expectEqual(machine.state, .alert, "cooldown re-triggers fast on re-peek")
}

func testMachineCooldownExpiresToMonitoring() {
    let log = TransitionLog()
    let machine = bootedMachine(log)
    feed(machine, [true, true, true])
    feed(machine, Array(repeating: false, count: 12), start: 0.3) // → cooldown at 1.4
    feed(machine, Array(repeating: false, count: 40), start: 1.5) // 4 s of quiet
    expectEqual(machine.state, .monitoring, "4 s quiet in cooldown → monitoring")
}

func testMachineDisableFromAlert() {
    let log = TransitionLog()
    let machine = bootedMachine(log)
    feed(machine, [true, true, true])
    expectEqual(machine.state, .alert)
    machine.setEnabled(false)
    expectEqual(machine.state, .off)
    machine.setEnabled(true)
    machine.notifyCameraRunning()
    expectEqual(machine.state, .monitoring, "re-enable boots cleanly")
}

func testMachineIgnoresFramesWhenOff() {
    let log = TransitionLog()
    let machine = DetectionStateMachine()
    machine.onTransition = { _, to, _ in log.states.append(to) }
    feed(machine, [true, true, true, true, true])
    expectEqual(machine.state, .off, "disabled machine ignores frames entirely")
    expectEqual(log.states, [])
}
