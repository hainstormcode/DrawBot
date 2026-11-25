import CoreGraphics
import Foundation

public enum StrokePlanner {
    /// Horizontal runs of `paletteIndex` in `q`, rows top→bottom, serpentine: even rows
    /// (0,2,4…) left→right (startCol <= endCol), odd rows right→left (startCol >= endCol, and the
    /// runs of that row listed right-most first). Every cell with that label is covered exactly once.
    public static func runs(for paletteIndex: Int, in q: QuantizedImage) -> [GridRun] {
        guard paletteIndex >= 0, paletteIndex <= Int(Int32.max), q.width > 0, q.height > 0 else { return [] }
        let target = Int32(paletteIndex)
        let w = q.width
        // Tolerate a malformed labels array: only scan complete rows that exist.
        let h = min(q.height, q.labels.count / w)
        var result: [GridRun] = []
        var rowRuns: [GridRun] = []
        q.labels.withUnsafeBufferPointer { labels in
            for row in 0..<h {
                rowRuns.removeAll(keepingCapacity: true)
                let base = row * w
                var col = 0
                while col < w {
                    if labels[base + col] == target {
                        let start = col
                        while col + 1 < w && labels[base + col + 1] == target { col += 1 }
                        rowRuns.append(GridRun(row: row, startCol: start, endCol: col))
                    }
                    col += 1
                }
                if row % 2 == 0 {
                    result.append(contentsOf: rowRuns)
                } else {
                    for r in rowRuns.reversed() {
                        result.append(GridRun(row: row, startCol: r.endCol, endCol: r.startCol))
                    }
                }
            }
        }
        return result
    }

    /// Converts runs to screen strokes from the center of startCol to the center of endCol.
    /// Single-cell runs become dots (start == end). `layout.columns/rows` must equal `q`'s size.
    /// (Defensive: runs whose row is outside the layout, or that lie entirely outside its
    /// columns, are dropped; partially outside runs are clamped to the layout's columns.)
    public static func screenStrokes(for runs: [GridRun], layout: GridLayout) -> [ScreenStroke] {
        var out: [ScreenStroke] = []
        out.reserveCapacity(runs.count)
        let maxCol = layout.columns - 1
        for r in runs {
            guard r.row >= 0, r.row < layout.rows else { continue }
            guard max(r.startCol, r.endCol) >= 0, min(r.startCol, r.endCol) <= maxCol else { continue }
            let s = min(max(r.startCol, 0), maxCol)
            let e = min(max(r.endCol, 0), maxCol)
            let a = layout.cellCenter(col: s, row: r.row)
            if s == e {
                out.append(ScreenStroke(start: a, end: a))
            } else {
                out.append(ScreenStroke(start: a, end: layout.cellCenter(col: e, row: r.row)))
            }
        }
        return out
    }

    /// Convenience: runs + screenStrokes.
    public static func strokes(for paletteIndex: Int, in q: QuantizedImage, layout: GridLayout) -> [ScreenStroke] {
        screenStrokes(for: runs(for: paletteIndex, in: q), layout: layout)
    }
}
