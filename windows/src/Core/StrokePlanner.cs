using System;
using System.Collections.Generic;
using System.Linq;

namespace DrawBot.Core
{
    public static class StrokePlanner
    {
        /// <summary>A cell of the grid.</summary>
        public struct Cell : IEquatable<Cell>
        {
            public int Col, Row;
            public Cell(int col, int row) { Col = col; Row = row; }
            public bool Equals(Cell o) => Col == o.Col && Row == o.Row;
            public override bool Equals(object obj) => obj is Cell c && Equals(c);
            public override int GetHashCode() => Col * 100003 + Row;
            public static bool operator ==(Cell a, Cell b) => a.Equals(b);
            public static bool operator !=(Cell a, Cell b) => !a.Equals(b);
            public override string ToString() => "(" + Col + "," + Row + ")";
        }

        /// <summary>The longest detour (in cells) the pen travels over cells of the same color without lifting.</summary>
        public const int MaxLink = 24;
        /// <summary>Splits paths after this many cells, so pausing and resuming stays fine-grained.</summary>
        public const int MaxPathCells = 800;

        /// <summary>
        /// Horizontal runs of paletteIndex, rows top→bottom, serpentine: even rows left→right, odd
        /// rows right→left (runs of that row listed right-most first).
        /// </summary>
        public static List<GridRun> Runs(int paletteIndex, QuantizedImage q)
        {
            var result = new List<GridRun>();
            if (paletteIndex < 0 || q.Width <= 0 || q.Height <= 0) return result;
            int w = q.Width;
            int h = Math.Min(q.Height, q.Labels.Length / w);
            var labels = q.Labels;
            var rowRuns = new List<GridRun>();
            for (int row = 0; row < h; row++)
            {
                rowRuns.Clear();
                int b = row * w;
                int col = 0;
                while (col < w)
                {
                    if (labels[b + col] == paletteIndex)
                    {
                        int start = col;
                        while (col + 1 < w && labels[b + col + 1] == paletteIndex) col++;
                        rowRuns.Add(new GridRun(row, start, col));
                    }
                    col++;
                }
                if (row % 2 == 0) result.AddRange(rowRuns);
                else for (int i = rowRuns.Count - 1; i >= 0; i--) result.Add(new GridRun(row, rowRuns[i].EndCol, rowRuns[i].StartCol));
            }
            return result;
        }

        /// <summary>Converts runs to screen strokes (single-cell runs become dots).</summary>
        public static List<ScreenStroke> ScreenStrokes(IEnumerable<GridRun> runs, GridLayout layout)
        {
            var outp = new List<ScreenStroke>();
            int maxCol = layout.Columns - 1;
            foreach (var r in runs)
            {
                if (r.Row < 0 || r.Row >= layout.Rows) continue;
                if (Math.Max(r.StartCol, r.EndCol) < 0 || Math.Min(r.StartCol, r.EndCol) > maxCol) continue;
                int s = Math.Min(Math.Max(r.StartCol, 0), maxCol);
                int e = Math.Min(Math.Max(r.EndCol, 0), maxCol);
                var a = layout.CellCenter(s, r.Row);
                outp.Add(s == e ? new ScreenStroke(a, a) : new ScreenStroke(a, layout.CellCenter(e, r.Row)));
            }
            return outp;
        }

        /// <summary>The strokes that paint paletteIndex: continuous A* paths, or one stroke per row run.</summary>
        public static List<ScreenStroke> Strokes(int paletteIndex, QuantizedImage q, GridLayout layout, StrokeStyle style = StrokeStyle.Paths)
        {
            return style == StrokeStyle.Paths
                ? ScreenStrokes(Paths(paletteIndex, q), layout)
                : ScreenStrokes(Runs(paletteIndex, q), layout);
        }

        struct Run { public int Row, Lo, Hi; }
        struct Candidate { public int Run; public Cell Entry; public int Distance; }

        /// <summary>
        /// Paths that paint every cell of paletteIndex while the pen stays on that color. The pen
        /// paints a run, then heads for the nearest unpainted run along the shortest same-color way
        /// (A*); only when there is none short enough does it lift. Each path is a list of corner
        /// cells; one cell is a dot.
        /// </summary>
        public static List<List<Cell>> Paths(int paletteIndex, QuantizedImage q)
        {
            var paths = new List<List<Cell>>();
            if (paletteIndex < 0 || q.Width <= 0 || q.Height <= 0) return paths;
            int w = q.Width;
            int h = Math.Min(q.Height, q.Labels.Length / w);
            if (h <= 0) return paths;
            var mask = new bool[w * h];
            for (int i = 0; i < w * h; i++) mask[i] = q.Labels[i] == paletteIndex;

            var runs = new List<Run>();
            var runsInRow = new List<int>[h];
            for (int row = 0; row < h; row++)
            {
                runsInRow[row] = new List<int>();
                int col = 0;
                while (col < w)
                {
                    if (mask[row * w + col])
                    {
                        int lo = col;
                        while (col + 1 < w && mask[row * w + col + 1]) col++;
                        runsInRow[row].Add(runs.Count);
                        runs.Add(new Run { Row = row, Lo = lo, Hi = col });
                    }
                    col++;
                }
            }
            if (runs.Count == 0) return paths;
            var done = new bool[runs.Count];
            int remaining = runs.Count;
            int firstOpenRow = 0;

            Func<Cell, int, List<Candidate>> nearest = (p, limit) =>
            {
                var found = new List<Candidate>();
                int worst = int.MaxValue;
                int d = 0;
                while (true)
                {
                    var rows = d == 0 ? new[] { p.Row } : new[] { p.Row - d, p.Row + d };
                    foreach (var r in rows)
                    {
                        if (r < 0 || r >= h) continue;
                        foreach (var i in runsInRow[r])
                        {
                            if (done[i]) continue;
                            var run = runs[i];
                            var a = new Cell(run.Lo, r); var b = new Cell(run.Hi, r);
                            int da = Math.Abs(a.Col - p.Col) + d, db = Math.Abs(b.Col - p.Col) + d;
                            found.Add(da <= db ? new Candidate { Run = i, Entry = a, Distance = da } : new Candidate { Run = i, Entry = b, Distance = db });
                        }
                    }
                    if (found.Count >= limit)
                    {
                        found = StableSortByDistance(found);
                        found.RemoveRange(limit, found.Count - limit);
                        worst = found[found.Count - 1].Distance;
                    }
                    d++;
                    if (p.Row - d < 0 && p.Row + d >= h) break;
                    if (d > worst) break;
                }
                return StableSortByDistance(found);
            };

            var current = new List<Cell>();
            Cell? position = null;

            Action<int, Cell> paint = (i, entry) =>
            {
                done[i] = true;
                remaining--;
                var run = runs[i];
                var exit = new Cell(entry.Col == run.Lo ? run.Hi : run.Lo, run.Row);
                int step = exit.Col >= entry.Col ? 1 : -1;
                int c = entry.Col;
                while (true)
                {
                    var cell = new Cell(c, run.Row);
                    if (current.Count == 0 || current[current.Count - 1] != cell) current.Add(cell);
                    if (c == exit.Col) break;
                    c += step;
                }
                position = exit;
            };

            Action finishPath = () =>
            {
                if (current.Count > 0) paths.Add(Corners(current));
                current = new List<Cell>();
            };

            while (remaining > 0)
            {
                if (position.HasValue)
                {
                    var p = position.Value;
                    int bestRun = -1; Cell bestEntry = default(Cell); List<Cell> bestWay = null;
                    foreach (var cand in nearest(p, 4))
                    {
                        if (cand.Distance > MaxLink) continue;
                        if (bestWay != null && cand.Distance >= bestWay.Count - 1) break;
                        var way = AStar(p, cand.Entry, mask, w, h, Math.Min(MaxLink, bestWay != null ? bestWay.Count - 2 : MaxLink));
                        if (way != null) { bestRun = cand.Run; bestEntry = cand.Entry; bestWay = way; }
                    }
                    if (bestWay != null && current.Count + bestWay.Count <= MaxPathCells)
                    {
                        for (int i = 1; i < bestWay.Count; i++) current.Add(bestWay[i]);
                        paint(bestRun, bestEntry);
                        continue;
                    }
                    finishPath();
                    var next = nearest(p, 1);
                    if (next.Count > 0) { paint(next[0].Run, next[0].Entry); continue; }
                }
                while (firstOpenRow < h && runsInRow[firstOpenRow].All(x => done[x])) firstOpenRow++;
                if (firstOpenRow >= h) break;
                int open = runsInRow[firstOpenRow].First(x => !done[x]);
                finishPath();
                paint(open, new Cell(runs[open].Lo, firstOpenRow));
            }
            finishPath();
            return paths;
        }

        static List<Candidate> StableSortByDistance(List<Candidate> list) => list.OrderBy(c => c.Distance).ToList();

        /// <summary>Shortest 4-connected way from a to b through mask cells (both ends included), or null if none within maxCost steps.</summary>
        public static List<Cell> AStar(Cell a, Cell b, bool[] mask, int w, int h, int maxCost)
        {
            if (a == b) return new List<Cell> { a };
            Func<Cell, int> manhattan = c => Math.Abs(c.Col - b.Col) + Math.Abs(c.Row - b.Row);
            if (manhattan(a) > maxCost) return null;
            var g = new Dictionary<Cell, int> { { a, 0 } };
            var parent = new Dictionary<Cell, Cell>();
            var buckets = new List<Cell>[maxCost + 1];
            for (int i = 0; i <= maxCost; i++) buckets[i] = new List<Cell>();
            buckets[manhattan(a)].Add(a);
            int f = manhattan(a);
            var dirs = new[] { new[] { 1, 0 }, new[] { -1, 0 }, new[] { 0, 1 }, new[] { 0, -1 } };
            while (f <= maxCost)
            {
                var bucket = buckets[f];
                if (bucket.Count == 0) { f++; continue; }
                var c = bucket[bucket.Count - 1];
                bucket.RemoveAt(bucket.Count - 1);
                int gc = g[c];
                if (gc + manhattan(c) != f) continue;
                if (c == b)
                {
                    var way = new List<Cell> { b };
                    var cur = b;
                    Cell pp;
                    while (parent.TryGetValue(cur, out pp)) { way.Add(pp); cur = pp; }
                    way.Reverse();
                    return way;
                }
                foreach (var d in dirs)
                {
                    var n = new Cell(c.Col + d[0], c.Row + d[1]);
                    if (n.Col < 0 || n.Row < 0 || n.Col >= w || n.Row >= h || !mask[n.Row * w + n.Col]) continue;
                    int gn = gc + 1, fn = gn + manhattan(n);
                    int old;
                    if (fn > maxCost || gn >= (g.TryGetValue(n, out old) ? old : int.MaxValue)) continue;
                    g[n] = gn;
                    parent[n] = c;
                    buckets[fn].Add(n);
                    if (fn < f) f = fn;
                }
            }
            return null;
        }

        /// <summary>Drops the cells in the middle of straight stretches, keeping start, corners and end.</summary>
        public static List<Cell> Corners(List<Cell> cells)
        {
            if (cells.Count <= 2) return new List<Cell>(cells);
            var outp = new List<Cell> { cells[0] };
            for (int i = 1; i < cells.Count - 1; i++)
            {
                Cell a = cells[i - 1], b = cells[i], c = cells[i + 1];
                bool same = b.Col - a.Col == c.Col - b.Col && b.Row - a.Row == c.Row - b.Row;
                if (!same) outp.Add(b);
            }
            outp.Add(cells[cells.Count - 1]);
            return outp;
        }

        /// <summary>Converts paths to screen strokes through the cells' centers.</summary>
        public static List<ScreenStroke> ScreenStrokes(IEnumerable<List<Cell>> paths, GridLayout layout)
        {
            var outp = new List<ScreenStroke>();
            foreach (var path in paths)
            {
                if (path.Count == 0) continue;
                var pts = path.Select(c => layout.CellCenter(c.Col, c.Row)).ToArray();
                outp.Add(new ScreenStroke(pts[0], pts[pts.Length - 1], pts.Skip(1).Take(Math.Max(0, pts.Length - 2)).ToArray()));
            }
            return outp;
        }
    }
}
