import XCTest
@testable import DrawBotCore

final class StrokePlannerTests: XCTestCase {
    func q(_ rows: [[Int32]]) -> QuantizedImage {
        let h = rows.count, w = rows.first?.count ?? 0
        let labels = rows.flatMap { $0 }
        let maxLabel = Int(labels.max() ?? -1)
        var counts = [Int](repeating: 0, count: max(0, maxLabel + 1))
        for l in labels where l >= 0 { counts[Int(l)] += 1 }
        let palette = (0..<counts.count).map { RGB(r: UInt8($0 * 10), g: 0, b: 0) }
        return QuantizedImage(width: w, height: h, labels: labels, palette: palette, counts: counts)
    }

    func testSerpentineRuns() {
        let img = q([
            [0, 0, 1, 0, 0, 0],
            [0, 1, 0, 0, 1, 0],
            [1, 1, 1, 1, 1, 1],
            [0, 0, 0, 1, 1, 0],
        ])
        XCTAssertEqual(StrokePlanner.runs(for: 0, in: img), [
            GridRun(row: 0, startCol: 0, endCol: 1),
            GridRun(row: 0, startCol: 3, endCol: 5),
            GridRun(row: 1, startCol: 5, endCol: 5),
            GridRun(row: 1, startCol: 3, endCol: 2),
            GridRun(row: 1, startCol: 0, endCol: 0),
            GridRun(row: 3, startCol: 5, endCol: 5),
            GridRun(row: 3, startCol: 2, endCol: 0),
        ])
        XCTAssertEqual(StrokePlanner.runs(for: 1, in: img), [
            GridRun(row: 0, startCol: 2, endCol: 2),
            GridRun(row: 1, startCol: 4, endCol: 4),
            GridRun(row: 1, startCol: 1, endCol: 1),
            GridRun(row: 2, startCol: 0, endCol: 5),
            GridRun(row: 3, startCol: 4, endCol: 3),
        ])
        XCTAssertEqual(StrokePlanner.runs(for: 2, in: img), [])
        XCTAssertEqual(StrokePlanner.runs(for: -1, in: img), [])
    }

    func testRunsCoverEveryCellExactlyOnceProperty() {
        var rng = SplitMix64(seed: 2024)
        for trial in 0..<200 {
            let w = Int(rng.next() % 40) + 1, h = Int(rng.next() % 30) + 1
            let k = Int(rng.next() % 5) + 1
            // Mix of noisy and blocky label fields, with transparency.
            let blocky = trial % 2 == 0
            var labels = [Int32](repeating: -1, count: w * h)
            var current: Int32 = 0
            for i in 0..<(w * h) {
                if !blocky || rng.next() % 6 == 0 { current = Int32(Int(rng.next() % UInt64(k + 1)) - 1) }
                labels[i] = current
            }
            let img = QuantizedImage(width: w, height: h, labels: labels,
                                     palette: (0..<k).map { _ in RGB(r: 0, g: 0, b: 0) },
                                     counts: (0..<k).map { c in labels.filter { $0 == Int32(c) }.count })
            for c in 0..<k {
                var covered = [Int](repeating: 0, count: w * h)
                var lastRow = -1
                var lastMin = Int.max, lastMax = Int.min
                for r in StrokePlanner.runs(for: c, in: img) {
                    XCTAssertTrue(r.row >= 0 && r.row < h)
                    XCTAssertGreaterThanOrEqual(r.row, lastRow, "rows top→bottom")
                    let lo = min(r.startCol, r.endCol), hi = max(r.startCol, r.endCol)
                    XCTAssertTrue(lo >= 0 && hi < w)
                    if r.row % 2 == 0 { XCTAssertLessThanOrEqual(r.startCol, r.endCol) }
                    else { XCTAssertGreaterThanOrEqual(r.startCol, r.endCol) }
                    if r.row == lastRow {
                        if r.row % 2 == 0 { XCTAssertGreaterThan(lo, lastMax + 1, "left→right, maximal runs") }
                        else { XCTAssertLessThan(hi, lastMin - 1, "right-most first, maximal runs") }
                    }
                    for col in lo...hi {
                        XCTAssertEqual(labels[r.row * w + col], Int32(c))
                        covered[r.row * w + col] += 1
                    }
                    lastRow = r.row; lastMin = lo; lastMax = hi
                }
                for i in 0..<(w * h) {
                    XCTAssertEqual(covered[i], labels[i] == Int32(c) ? 1 : 0)
                }
            }
        }
    }

    func testScreenStrokesAndDots() {
        let layout = GridLayout(canvas: CGRect(x: 100, y: 50, width: 40, height: 20), penSize: 10)  // 4×2
        let img = q([[0, 0, 1, 0], [1, 0, 0, 0]])
        let runs = StrokePlanner.runs(for: 0, in: img)
        XCTAssertEqual(runs, [GridRun(row: 0, startCol: 0, endCol: 1), GridRun(row: 0, startCol: 3, endCol: 3),
                              GridRun(row: 1, startCol: 3, endCol: 1)])
        let strokes = StrokePlanner.screenStrokes(for: runs, layout: layout)
        XCTAssertEqual(strokes, [
            ScreenStroke(start: CGPoint(x: 105, y: 55), end: CGPoint(x: 115, y: 55)),
            ScreenStroke(start: CGPoint(x: 135, y: 55), end: CGPoint(x: 135, y: 55)),
            ScreenStroke(start: CGPoint(x: 135, y: 65), end: CGPoint(x: 115, y: 65)),
        ])
        XCTAssertFalse(strokes[0].isDot)
        XCTAssertTrue(strokes[1].isDot)
        XCTAssertEqual(strokes[2].length, 20, accuracy: 1e-9)
        XCTAssertEqual(StrokePlanner.strokes(for: 0, in: img, layout: layout), strokes)
        // Dots for single cells of label 1.
        let dots = StrokePlanner.strokes(for: 1, in: img, layout: layout)
        XCTAssertEqual(dots.count, 2)
        XCTAssertTrue(dots.allSatisfy { $0.isDot })
        XCTAssertEqual(dots[0].start, CGPoint(x: 125, y: 55))
        XCTAssertEqual(dots[1].start, CGPoint(x: 105, y: 65))
    }

    func testScreenStrokesNegativeCoordinates() {
        let layout = GridLayout(canvas: CGRect(x: -1000, y: -520, width: 20, height: 8), penSize: 4)  // 5×2
        let s = StrokePlanner.screenStrokes(for: [GridRun(row: 1, startCol: 4, endCol: 0)], layout: layout)
        XCTAssertEqual(s, [ScreenStroke(start: CGPoint(x: -982, y: -514), end: CGPoint(x: -998, y: -514))])
    }

    func testMismatchedLayoutDoesNotCrash() {
        let layout = GridLayout(canvas: CGRect(x: 0, y: 0, width: 20, height: 10), penSize: 10)  // 2×1
        let runs = [GridRun(row: 0, startCol: 0, endCol: 5), GridRun(row: 3, startCol: 0, endCol: 1),
                    GridRun(row: 0, startCol: 7, endCol: 9), GridRun(row: -1, startCol: 0, endCol: 0)]
        let s = StrokePlanner.screenStrokes(for: runs, layout: layout)
        XCTAssertEqual(s, [ScreenStroke(start: CGPoint(x: 5, y: 5), end: CGPoint(x: 15, y: 5))])
        // Malformed QuantizedImage (labels shorter than width*height) doesn't crash.
        let bad = QuantizedImage(width: 4, height: 3, labels: [0, 0, 0, 0, 0], palette: [RGB(r: 0, g: 0, b: 0)], counts: [5])
        XCTAssertEqual(StrokePlanner.runs(for: 0, in: bad), [GridRun(row: 0, startCol: 0, endCol: 3)])
        let empty = QuantizedImage(width: 0, height: 0, labels: [], palette: [], counts: [])
        XCTAssertEqual(StrokePlanner.runs(for: 0, in: empty), [])
    }
}
