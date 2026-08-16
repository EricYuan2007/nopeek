import Foundation

// MARK: - PoseBins (guided enrollment pose coverage)

func testPoseBinsCenter() {
    expectEqual(PoseBins.bin(yaw: 0, pitch: 0), -1, "straight ahead → center")
    expectEqual(PoseBins.bin(yaw: 0.1, pitch: -0.12), -1, "mag 0.156 < 0.18 → center")
    expectEqual(PoseBins.bin(yaw: 0.18, pitch: 0), -1, "boundary inclusive → center")
}

func testPoseBinsSectors() {
    // 8 CCW sectors of 45° in y-up pose space: 0 = +x … 2 = +y … 4 = −x … 6 = −y.
    expectEqual(PoseBins.bin(yaw: 0.3, pitch: 0), 0, "pure +yaw → sector 0")
    expectEqual(PoseBins.bin(yaw: 0, pitch: 0.3), 2, "pure +pitch → sector 2")
    expectEqual(PoseBins.bin(yaw: -0.3, pitch: 0), 4, "pure −yaw → sector 4")
    expectEqual(PoseBins.bin(yaw: 0, pitch: -0.3), 6, "pure −pitch → sector 6")
    expectEqual(PoseBins.bin(yaw: 0.2, pitch: 0.2), 1, "diagonal (mag 0.28, 45°) → sector 1")
    expectEqual(PoseBins.bin(yaw: -0.2, pitch: -0.2), 5, "opposite diagonal → sector 5")
}

func testPoseBinsRejects() {
    expect(PoseBins.bin(yaw: nil, pitch: 0.3) == nil, "missing yaw → unusable")
    expect(PoseBins.bin(yaw: 0.9, pitch: 0) == nil, "turned 51° → too far to be useful")
    expect(PoseBins.bin(yaw: 0.5, pitch: 0.5) == nil, "mag 0.71 > ring ceiling → unusable")
}
