import Foundation

public enum TimeEstimator {
    /// Fixed per-posted-event overhead, seconds.
    public static let perEventOverhead: TimeInterval = 0.00015

    /// Number of drag events the DrawingEngine posts for a stroke: ceil(length / stepSize),
    /// at least 1 for a line, and 2 for a dot (wiggle out and back).
    public static func dragEventCount(_ stroke: ScreenStroke, stepSize: Double) -> Int {
        if stroke.isDot { return 2 }
        let step = stepSize > 0 ? stepSize : 1
        return max(1, Int((stroke.length / step).rounded(.up)))
    }

    /// Estimated wall-clock seconds the DrawingEngine needs for `strokes` at `speed`
    /// (moveDelay + downDelay + ceil(length/stepSize) drag events * eventDelay + endDelay + upDelay per stroke,
    /// plus ~0.15 ms per posted event of overhead).
    public static func estimate(_ strokes: [ScreenStroke], speed: SpeedSettings) -> TimeInterval {
        let fixed = speed.moveDelay + speed.downDelay + speed.endDelay + speed.upDelay
        var total = 0.0
        for s in strokes {
            let drags = dragEventCount(s, stepSize: speed.stepSize)
            // move + down + drags + up
            let events = drags + 3
            total += fixed + Double(drags) * speed.eventDelay + Double(events) * perEventOverhead
        }
        return total
    }

    /// "1 h 4 min", "3 min 20 s", "12 s".
    public static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0.5 else { return "0 s" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 {
            let m = total / 60, s = total % 60
            return s == 0 ? "\(m) min" : "\(m) min \(s) s"
        }
        let totalMinutes = Int((seconds / 60).rounded())
        let h = totalMinutes / 60, m = totalMinutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
