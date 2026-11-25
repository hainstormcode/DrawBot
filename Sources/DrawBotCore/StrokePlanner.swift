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

    /// The strokes that paint `paletteIndex`: continuous A* paths (see `paths`), or one stroke
    /// per row run, top to bottom (see `runs`).
    public static func strokes(for paletteIndex: Int, in q: QuantizedImage, layout: GridLayout,
                               style: StrokeStyle = .paths) -> [ScreenStroke] {
        switch style {
        case .paths: return screenStrokes(for: paths(for: paletteIndex, in: q), layout: layout)
        case .rows: return screenStrokes(for: runs(for: paletteIndex, in: q), layout: layout)
        }
    }

    // MARK: Continuous paths (A*)

    /// A cell of the grid.
    public struct Cell: Hashable, Sendable {
        public var col: Int
        public var row: Int
        public init(col: Int, row: Int) { self.col = col; self.row = row }
    }

    /// The longest detour (in cells) the pen travels down over cells of the same color to reach
    /// the next run without lifting. Longer detours lift the pen instead.
    public static let maxLink = 24
    /// Splits paths after this many cells, so pausing and resuming stays fine-grained.
    public static let maxPathCells = 800

    /// Paths that paint every cell of `paletteIndex` while the pen stays on that color.
    ///
    /// The color's cells are cut into horizontal runs. Starting top-left, the pen paints a run,
    /// then heads for the nearest unpainted run: A* (4-connected, Manhattan heuristic) finds the
    /// shortest way there through cells of this color only, so the pen can stay down without
    /// painting over other colors. Only when no such way is short enough does the pen lift. A
    /// solid area becomes one zigzag stroke instead of one stroke per row, and every stroke saved
    /// saves a press, a release and their pauses.
    ///
    /// Each path is a list of corner cells (consecutive corners share a row or a column); one
    /// cell is a dot. Every cell of the color is on some path, and no path touches another color.
    public static func paths(for paletteIndex: Int, in q: QuantizedImage) -> [[Cell]] {
        guard paletteIndex >= 0, paletteIndex <= Int(Int32.max), q.width > 0, q.height > 0 else { return [] }
        let target = Int32(paletteIndex)
        let w = q.width
        let h = min(q.height, q.labels.count / w)
        guard h > 0 else { return [] }
        let mask = (0..<(w * h)).map { q.labels[$0] == target }

        // Runs, per row.
        struct Run { let row: Int; let lo: Int; let hi: Int }
        var runs: [Run] = []
        var runsInRow = [[Int]](repeating: [], count: h)
        for row in 0..<h {
            var col = 0
            while col < w {
                if mask[row * w + col] {
                    let lo = col
                    while col + 1 < w && mask[row * w + col + 1] { col += 1 }
                    runsInRow[row].append(runs.count)
                    runs.append(Run(row: row, lo: lo, hi: col))
                }
                col += 1
            }
        }
        guard !runs.isEmpty else { return [] }
        var done = [Bool](repeating: false, count: runs.count)
        var remaining = runs.count
        var firstOpenRow = 0

        /// Unpainted runs nearest to `p` (Manhattan distance to their nearer end), closest first.
        func nearest(to p: Cell, limit: Int) -> [(run: Int, entry: Cell, distance: Int)] {
            var found: [(run: Int, entry: Cell, distance: Int)] = []
            var worst = Int.max
            var d = 0
            while true {
                let rows = d == 0 ? [p.row] : [p.row - d, p.row + d]
                for r in rows where r >= 0 && r < h {
                    for i in runsInRow[r] where !done[i] {
                        let run = runs[i]
                        let a = Cell(col: run.lo, row: r), b = Cell(col: run.hi, row: r)
                        let da = abs(a.col - p.col) + d, db = abs(b.col - p.col) + d
                        found.append(da <= db ? (i, a, da) : (i, b, db))
                    }
                }
                if found.count >= limit {
                    found.sort { $0.distance < $1.distance }
                    found.removeLast(found.count - limit)
                    worst = found.last!.distance
                }
                d += 1
                if p.row - d < 0 && p.row + d >= h { break }
                if d > worst { break }
            }
            return found.sorted { $0.distance < $1.distance }
        }

        var paths: [[Cell]] = []
        var current: [Cell] = []   // every cell of the path being built, in order
        var position: Cell?

        func paint(_ i: Int, from entry: Cell) {
            done[i] = true
            remaining -= 1
            let run = runs[i]
            let exit = Cell(col: entry.col == run.lo ? run.hi : run.lo, row: run.row)
            let step = exit.col >= entry.col ? 1 : -1
            var c = entry.col
            while true {
                let cell = Cell(col: c, row: run.row)
                if current.last != cell { current.append(cell) }
                if c == exit.col { break }
                c += step
            }
            position = exit
        }

        func finishPath() {
            if !current.isEmpty { paths.append(corners(of: current)) }
            current = []
        }

        while remaining > 0 {
            if let p = position {
                // Try the closest few runs; take the one with the shortest same-color way there.
                var best: (run: Int, entry: Cell, way: [Cell])?
                for cand in nearest(to: p, limit: 4) where cand.distance <= maxLink {
                    if let b = best, cand.distance >= b.way.count - 1 { break }
                    if let way = aStar(from: p, to: cand.entry, mask: mask, width: w, height: h,
                                       maxCost: min(maxLink, best.map { $0.way.count - 2 } ?? maxLink)) {
                        best = (cand.run, cand.entry, way)
                    }
                }
                if let b = best, current.count + b.way.count <= maxPathCells {
                    for cell in b.way.dropFirst() { current.append(cell) }
                    paint(b.run, from: b.entry)
                    continue
                }
                finishPath()
                // Lift and go to the nearest unpainted run.
                if let next = nearest(to: p, limit: 1).first {
                    paint(next.run, from: next.entry)
                    continue
                }
            }
            // Start (or no run near): the top-left unpainted run, from its left end.
            while firstOpenRow < h && runsInRow[firstOpenRow].allSatisfy({ done[$0] }) { firstOpenRow += 1 }
            guard firstOpenRow < h, let i = runsInRow[firstOpenRow].first(where: { !done[$0] }) else { break }
            finishPath()
            paint(i, from: Cell(col: runs[i].lo, row: firstOpenRow))
        }
        finishPath()
        return paths
    }

    /// Shortest 4-connected way from `a` to `b` through `mask` cells (both ends included), or nil
    /// if there is none of at most `maxCost` steps. A* with the Manhattan distance as heuristic.
    static func aStar(from a: Cell, to b: Cell, mask: [Bool], width w: Int, height h: Int, maxCost: Int) -> [Cell]? {
        if a == b { return [a] }
        let manhattan = { (c: Cell) in abs(c.col - b.col) + abs(c.row - b.row) }
        guard manhattan(a) <= maxCost else { return nil }
        var g: [Cell: Int] = [a: 0]
        var parent: [Cell: Cell] = [:]
        // Open set as buckets by f (costs are small integers); ties go to the larger g (deeper first).
        var buckets: [[Cell]] = Array(repeating: [], count: maxCost + 1)
        buckets[manhattan(a)].append(a)
        var f = manhattan(a)
        while f <= maxCost {
            guard let c = buckets[f].popLast() else { f += 1; continue }
            let gc = g[c]!
            if gc + manhattan(c) != f { continue }   // stale entry
            if c == b {
                var way = [b]
                var cur = b
                while let p = parent[cur] { way.append(p); cur = p }
                return way.reversed()
            }
            for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let n = Cell(col: c.col + dc, row: c.row + dr)
                guard n.col >= 0, n.row >= 0, n.col < w, n.row < h, mask[n.row * w + n.col] else { continue }
                let gn = gc + 1
                let fn = gn + manhattan(n)
                guard fn <= maxCost, gn < (g[n] ?? .max) else { continue }
                g[n] = gn
                parent[n] = c
                buckets[fn].append(n)
                if fn < f { f = fn }
            }
        }
        return nil
    }

    /// Drops the cells in the middle of straight stretches, keeping start, corners and end.
    static func corners(of cells: [Cell]) -> [Cell] {
        guard cells.count > 2 else { return cells }
        var out = [cells[0]]
        for i in 1..<(cells.count - 1) {
            // Keep b unless the pen goes on in the same direction (a U-turn is a corner too).
            let a = cells[i - 1], b = cells[i], c = cells[i + 1]
            let same = b.col - a.col == c.col - b.col && b.row - a.row == c.row - b.row
            if !same { out.append(b) }
        }
        out.append(cells.last!)
        return out
    }

    /// Converts paths to screen strokes through the cells' centers.
    public static func screenStrokes(for paths: [[Cell]], layout: GridLayout) -> [ScreenStroke] {
        paths.compactMap { path in
            guard let first = path.first, let last = path.last else { return nil }
            let pts = path.map { layout.cellCenter(col: $0.col, row: $0.row) }
            return ScreenStroke(start: layout.cellCenter(col: first.col, row: first.row),
                                end: layout.cellCenter(col: last.col, row: last.row),
                                via: Array(pts.dropFirst().dropLast()))
        }
    }
}
