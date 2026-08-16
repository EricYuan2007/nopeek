import CoreGraphics
import Foundation

/// Cross-frame face tracking + static-face (poster/photo) detection.
///
/// Tracking: greedy IoU matching against live tracks; unmatched faces start new tracks.
/// Static detection: real heads always micro-move; printed faces held in view of a
/// laptop-fixed camera do not. A track older than `staticMinAge` whose center and area
/// barely move is flagged `isStaticSuspect` (suppressed from intruder decisions, but
/// never suppresses the owner — handled by IntruderAssessor's caller contract).
public final class FaceTracker {

    private struct Track {
        var id: Int
        var box: CGRect
        var lastSeen: TimeInterval
        var history: [(center: CGPoint, area: CGFloat, t: TimeInterval)]
    }

    public var staticMinAge: TimeInterval = 4
    public var staticCenterSigma: CGFloat = 0.002      // normalized units
    public var staticAreaSigmaFraction: CGFloat = 0.03 // σ(area) / mean(area)

    /// Tracks go stale and are pruned after this long without a match.
    public var maxTrackGap: TimeInterval = 2
    /// Keep at most this much motion history per track.
    public var historyWindow: TimeInterval = 8

    private var tracks: [Track] = []
    private var nextID = 1

    public init() {}

    /// Assigns trackIDs and static flags. `faces` may be in any order.
    public func process(_ faces: [FaceInfo], at timestamp: TimeInterval) -> [FaceInfo] {
        // Greedy matching by IoU, best pairs first.
        var pairs: [(face: Int, track: Int, iou: CGFloat)] = []
        for (fi, face) in faces.enumerated() {
            for (ti, track) in tracks.enumerated() {
                let iou = Self.iou(face.boundingBox, track.box)
                if iou > 0.3 { pairs.append((fi, ti, iou)) }
            }
        }
        pairs.sort { $0.iou > $1.iou }

        var faceToTrack: [Int: Int] = [:]
        var usedTracks = Set<Int>()
        for pair in pairs where faceToTrack[pair.face] == nil && !usedTracks.contains(pair.track) {
            faceToTrack[pair.face] = pair.track
            usedTracks.insert(pair.track)
        }

        var result: [FaceInfo] = []
        result.reserveCapacity(faces.count)

        for (fi, var face) in faces.enumerated() {
            let center = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
            let trackIndex: Int
            if let ti = faceToTrack[fi] {
                trackIndex = ti
            } else {
                tracks.append(Track(id: nextID, box: face.boundingBox, lastSeen: timestamp, history: []))
                nextID += 1
                trackIndex = tracks.count - 1
            }

            // EMA-smooth the box so one-frame detection jitter doesn't poison the
            // static metric (and so boxes don't visually jitter in the debug overlay).
            let α: CGFloat = tracks[trackIndex].history.isEmpty ? 1 : 0.5
            tracks[trackIndex].box = CGRect(
                x: tracks[trackIndex].box.minX * (1 - α) + face.boundingBox.minX * α,
                y: tracks[trackIndex].box.minY * (1 - α) + face.boundingBox.minY * α,
                width: tracks[trackIndex].box.width * (1 - α) + face.boundingBox.width * α,
                height: tracks[trackIndex].box.height * (1 - α) + face.boundingBox.height * α
            )
            tracks[trackIndex].lastSeen = timestamp
            tracks[trackIndex].history.append((center, face.area, timestamp))
            tracks[trackIndex].history.removeAll { timestamp - $0.t > historyWindow }

            face.trackID = tracks[trackIndex].id
            face.isStaticSuspect = isStatic(tracks[trackIndex], at: timestamp)
            result.append(face)
        }

        tracks.removeAll { timestamp - $0.lastSeen > maxTrackGap }
        return result
    }

    private func isStatic(_ track: Track, at now: TimeInterval) -> Bool {
        guard let first = track.history.first, now - first.t >= staticMinAge else { return false }
        let centersX = track.history.map(\.center.x)
        let centersY = track.history.map(\.center.y)
        let areas = track.history.map(\.area)
        guard sigma(centersX) < staticCenterSigma,
              sigma(centersY) < staticCenterSigma else { return false }
        let meanArea = areas.reduce(0, +) / CGFloat(areas.count)
        guard meanArea > 0, sigma(areas) / meanArea < staticAreaSigmaFraction else { return false }
        return true
    }

    private func sigma(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / CGFloat(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(values.count)
        return variance.squareRoot()
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let inter = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - inter
        guard union > 0 else { return 0 }
        return inter / union
    }
}
