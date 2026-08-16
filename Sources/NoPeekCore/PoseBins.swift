import Foundation

/// Pose-space binning for guided enrollment ("turn your head in a circle" flow).
///
/// The (yaw, pitch) plane is divided into a near-frontal CENTER bin plus 8 ring
/// sectors (45° wedges by heading angle). Enrollment collects a few center samples
/// plus one per ring sector, so the enrolled set covers the whole pose range the
/// runtime matcher actually sees (identity reads freeze beyond ±30° yaw).
public enum PoseBins {

    public static let sectorCount = 8
    public static let centerTarget = 3
    /// Total samples a full enrollment collects.
    public static var totalTarget: Int { sectorCount + centerTarget }

    /// Near-frontal ceiling ≈ 10°.
    public static let centerMaxMagnitude = 0.18
    /// Ring ceiling ≈ 35° — beyond this the pose estimate (and feature print) is too
    /// unreliable to be a useful sample.
    public static let ringMaxMagnitude = 0.62

    /// Bin for a pose read.
    /// - Returns: -1 for the center bin, 0..<sectorCount for a ring sector,
    ///   nil when the read is unusable (missing pose, or turned too far).
    public static func bin(yaw: Double?, pitch: Double?) -> Int? {
        guard let yaw, let pitch else { return nil }
        let magnitude = (yaw * yaw + pitch * pitch).squareRoot()
        if magnitude <= centerMaxMagnitude { return -1 }
        guard magnitude <= ringMaxMagnitude else { return nil }
        // Heading of the pose vector in y-up space → CCW sectors from the +x axis.
        let angle = atan2(pitch, yaw) // -π...π
        let normalized = (angle + 2 * Double.pi).truncatingRemainder(dividingBy: 2 * .pi)
        return Int(normalized / (.pi / 4)) % sectorCount
    }
}
