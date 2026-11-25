import XCTest
@testable import DrawBotCore

final class TimeEstimatorTests: XCTestCase {
    func testFormat() {
        XCTAssertEqual(TimeEstimator.format(0), "0 s")
        XCTAssertEqual(TimeEstimator.format(0.4), "0 s")
        XCTAssertEqual(TimeEstimator.format(-3), "0 s")
        XCTAssertEqual(TimeEstimator.format(.nan), "0 s")
        XCTAssertEqual(TimeEstimator.format(0.6), "1 s")
        XCTAssertEqual(TimeEstimator.format(12), "12 s")
        XCTAssertEqual(TimeEstimator.format(59.4), "59 s")
        XCTAssertEqual(TimeEstimator.format(59.6), "1 min")
        XCTAssertEqual(TimeEstimator.format(200), "3 min 20 s")
        XCTAssertEqual(TimeEstimator.format(3599), "59 min 59 s")
        XCTAssertEqual(TimeEstimator.format(3600), "1 h")
        XCTAssertEqual(TimeEstimator.format(3840), "1 h 4 min")
        XCTAssertEqual(TimeEstimator.format(3870), "1 h 5 min")  // 64.5 min rounds up
        XCTAssertEqual(TimeEstimator.format(2 * 3600 + 59 * 60 + 50), "3 h")
    }

    func testEstimate() {
        let speed = SpeedSettings(stepSize: 4, eventDelay: 0.003, downDelay: 0.015, upDelay: 0.015, moveDelay: 0.010)
        XCTAssertEqual(TimeEstimator.estimate([], speed: speed), 0)
        // 10-pt line → ceil(10/4)=3 drags, 6 events.
        let line = ScreenStroke(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0))
        let expectedLine = 0.010 + 0.015 + 3 * 0.003 + 0.015 + 6 * 0.00015
        XCTAssertEqual(TimeEstimator.estimate([line], speed: speed), expectedLine, accuracy: 1e-12)
        // Exact multiple: 8 pt → 2 drags.
        let line8 = ScreenStroke(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 8))
        XCTAssertEqual(TimeEstimator.dragEventCount(line8, stepSize: 4), 2)
        // Dot → 2 drag events (wiggle), 5 events.
        let dot = ScreenStroke(start: CGPoint(x: 3, y: 3), end: CGPoint(x: 3, y: 3))
        let expectedDot = 0.010 + 0.015 + 2 * 0.003 + 0.015 + 5 * 0.00015
        XCTAssertEqual(TimeEstimator.estimate([dot], speed: speed), expectedDot, accuracy: 1e-12)
        XCTAssertEqual(TimeEstimator.estimate([line, dot, line], speed: speed), 2 * expectedLine + expectedDot, accuracy: 1e-12)
        // Faster presets are faster.
        let strokes = (0..<100).map { ScreenStroke(start: CGPoint(x: 0, y: $0), end: CGPoint(x: 200, y: $0)) }
        let c = TimeEstimator.estimate(strokes, speed: .careful)
        let n = TimeEstimator.estimate(strokes, speed: .normal)
        let f = TimeEstimator.estimate(strokes, speed: .fast)
        let l = TimeEstimator.estimate(strokes, speed: .ludicrous)
        XCTAssertGreaterThan(c, n); XCTAssertGreaterThan(n, f); XCTAssertGreaterThan(f, l)
    }

    func testEndDelayAdaptsToTheScreensRefreshRate() {
        // Never shorter than one refresh (plus margin), never shorter than the preset's minimum.
        XCTAssertEqual(SpeedSettings.ludicrous.adapted(toRefreshRate: 60).endDelay, 1.15 / 60, accuracy: 1e-9)
        XCTAssertEqual(SpeedSettings.ludicrous.adapted(toRefreshRate: 120).endDelay, 1.15 / 120, accuracy: 1e-9)
        XCTAssertEqual(SpeedSettings.careful.adapted(toRefreshRate: 120).endDelay, 0.025, accuracy: 1e-9)
        XCTAssertEqual(SpeedSettings.normal.adapted(toRefreshRate: 0).endDelay, SpeedSettings.normal.endDelay)
        for preset in SpeedPreset.allCases { XCTAssertGreaterThanOrEqual(preset.settings.endDelay, 0.009) }
    }

    func testEstimateIncludesTheEndDelay() {
        let dot = [ScreenStroke(start: .zero, end: .zero)]
        let without = SpeedSettings(stepSize: 4, eventDelay: 0, downDelay: 0, upDelay: 0, moveDelay: 0)
        var with = without
        with.endDelay = 0.02
        XCTAssertEqual(TimeEstimator.estimate(dot, speed: with) - TimeEstimator.estimate(dot, speed: without), 0.02, accuracy: 1e-9)
    }
}
