using System;
using System.Collections.Generic;
using System.Linq;

namespace DrawBot.Core
{
    /// <summary>A fixed swatch in an app's color palette: where to click, and the color it selects.</summary>
    public sealed class PaletteSwatch : IEquatable<PaletteSwatch>
    {
        public PointD Point;
        public RGB Color;
        public int ClickCount;
        public PaletteSwatch(PointD point, RGB color, int clickCount = 1) { Point = point; Color = color; ClickCount = clickCount; }
        public bool Equals(PaletteSwatch o) => o != null && Point == o.Point && Color == o.Color && ClickCount == o.ClickCount;
        public override bool Equals(object obj) => Equals(obj as PaletteSwatch);
        public override int GetHashCode() => Point.GetHashCode() ^ Color.GetHashCode();
    }

    /// <summary>
    /// Learns what color each preset color button holds, from the spot the user clicked on it.
    /// Each button's color is read around the exact clicked point in the screenshot taken before
    /// any click; only if that spot isn't one clear color there is the last screenshot before
    /// that click used instead. Pixels of the 7×7 spot are grouped by color, so a check mark, a
    /// selection ring or the button's edge doesn't pull the color off.
    /// </summary>
    public static class PaletteLearner
    {
        const int Radius = 3;
        const int SameColor = 30;

        /// <summary>frames[i] was captured after clicking clicks[i] (image pixel coordinates).</summary>
        public static RGB[] Analyze(RGBAImage baseline, IList<RGBAImage> frames, IList<PointD> clicks)
        {
            if (clicks.Count == 0) return null;
            var colors = new RGB[clicks.Count];
            for (int i = 0; i < clicks.Count; i++)
            {
                var p = clicks[i];
                var strict = ClickedColor(baseline, p, true);
                if (strict.HasValue) { colors[i] = strict.Value; continue; }
                var before = i > 0 && i - 1 < frames.Count ? frames[i - 1] : baseline;
                colors[i] = ClickedColor(before, p, false) ?? ClickedColor(baseline, p, false) ?? new RGB(0, 0, 0);
            }
            return colors;
        }

        /// <summary>The color around p in image. strict: null unless one color fills at least 40% of the spot.</summary>
        public static RGB? ClickedColor(RGBAImage image, PointD p, bool strict)
        {
            int cx = (int)Math.Floor(p.X), cy = (int)Math.Floor(p.Y);
            int w = image.Width, h = image.Height;
            if (cx < 0 || cy < 0 || cx >= w || cy >= h) return null;
            var pixels = new List<int>();
            for (int dy = -Radius; dy <= Radius; dy++)
                for (int dx = -Radius; dx <= Radius; dx++)
                {
                    int x = cx + dx, y = cy + dy;
                    if (x >= 0 && y >= 0 && x < w && y < h) pixels.Add(y * w + x);
                }
            var d = image.Data;
            Func<int, List<int>> group = q => pixels.Where(px => Diff(d, px, q) <= SameColor).ToList();
            int center = cy * w + cx;
            var best = group(center);
            if (best.Count < 0.4 * pixels.Count)
                foreach (var q in pixels)
                {
                    var g = group(q);
                    if (g.Count > best.Count) best = g;
                }
            if (strict && best.Count < 0.4 * pixels.Count) return null;
            return Median(image, best);
        }

        /// <summary>One swatch per spot (a later click on the same swatch wins).</summary>
        public static List<PaletteSwatch> Swatches(IList<PointD> clicks, IList<RGB> colors, IList<int> clickCounts = null)
        {
            var outp = new List<PaletteSwatch>();
            for (int i = 0; i < clicks.Count && i < colors.Count; i++)
            {
                var p = clicks[i];
                var s = new PaletteSwatch(p, colors[i], clickCounts != null && i < clickCounts.Count ? clickCounts[i] : 1);
                int j = outp.FindIndex(o => PointD.Distance(o.Point, p) <= 6);
                if (j >= 0) outp[j] = s; else outp.Add(s);
            }
            return outp;
        }

        static int Diff(byte[] a, int p, int q)
        {
            int i = p * 4, j = q * 4;
            return Math.Abs(a[i] - a[j]) + Math.Abs(a[i + 1] - a[j + 1]) + Math.Abs(a[i + 2] - a[j + 2]);
        }

        static RGB Median(RGBAImage f, List<int> pixels)
        {
            if (pixels.Count == 0) return new RGB(0, 0, 0);
            Func<int, byte> channel = o =>
            {
                var v = pixels.Select(px => f.Data[px * 4 + o]).OrderBy(x => x).ToArray();
                return v[v.Length / 2];
            };
            return new RGB(channel(0), channel(1), channel(2));
        }
    }
}
