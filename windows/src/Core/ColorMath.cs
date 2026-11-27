using System;
using System.Collections.Generic;
using System.Linq;

namespace DrawBot.Core
{
    public static class Geometry
    {
        /// <summary>Rect spanned by two drag corners (any order), rounded outward to whole pixels.</summary>
        public static RectD RectFrom(PointD a, PointD b)
        {
            double minX = Math.Floor(Math.Min(a.X, b.X)), minY = Math.Floor(Math.Min(a.Y, b.Y));
            double maxX = Math.Ceiling(Math.Max(a.X, b.X)), maxY = Math.Ceiling(Math.Max(a.Y, b.Y));
            return new RectD(minX, minY, maxX - minX, maxY - minY);
        }

        /// <summary>Clamp a point into a rect (inclusive of max edges).</summary>
        public static PointD Clamp(PointD p, RectD r)
        {
            var s = r.Standardized;
            return new PointD(Math.Min(Math.Max(p.X, s.X), s.X + s.Width), Math.Min(Math.Max(p.Y, s.Y), s.Y + s.Height));
        }
    }

    public struct LabColor : IEquatable<LabColor>
    {
        public double L, A, B;
        public LabColor(double l, double a, double b) { L = l; A = a; B = b; }
        public bool Equals(LabColor o) => L == o.L && A == o.A && B == o.B;
        public override bool Equals(object obj) => obj is LabColor c && Equals(c);
        public override int GetHashCode() => L.GetHashCode() ^ A.GetHashCode() ^ B.GetHashCode();
    }

    public static class ColorMath
    {
        const double WhiteX = 0.95047, WhiteY = 1.0, WhiteZ = 1.08883;

        static readonly double[] SrgbToLinearTable = Enumerable.Range(0, 256).Select(i =>
        {
            double c = i / 255.0;
            return c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
        }).ToArray();

        static double Cbrt(double t) => t < 0 ? -Math.Pow(-t, 1.0 / 3) : Math.Pow(t, 1.0 / 3);
        static double LabF(double t) => t > 216.0 / 24389.0 ? Cbrt(t) : (t * (24389.0 / 27.0) + 16) / 116;
        static double LabFInverse(double t) => t > 6.0 / 29.0 ? t * t * t : (116 * t - 16) * (27.0 / 24389.0);
        static double LinearToSRGB(double c) => c <= 0.0031308 ? 12.92 * c : 1.055 * Math.Pow(c, 1 / 2.4) - 0.055;

        /// <summary>sRGB 8-bit components → Lab (fast path used by the quantizer).</summary>
        public static void Lab(byte r, byte g, byte b, out double L, out double A, out double B)
        {
            double rl = SrgbToLinearTable[r], gl = SrgbToLinearTable[g], bl = SrgbToLinearTable[b];
            double x = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / WhiteX;
            double y = (0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl) / WhiteY;
            double z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / WhiteZ;
            double fx = LabF(x), fy = LabF(y), fz = LabF(z);
            L = 116 * fy - 16; A = 500 * (fx - fy); B = 200 * (fy - fz);
        }

        /// <summary>sRGB (D65) → CIELAB.</summary>
        public static LabColor Lab(RGB c)
        {
            double l, a, b;
            Lab(c.R, c.G, c.B, out l, out a, out b);
            return new LabColor(l, a, b);
        }

        /// <summary>CIELAB → sRGB, clamped.</summary>
        public static RGB Rgb(LabColor lab)
        {
            double fy = (lab.L + 16) / 116, fx = fy + lab.A / 500, fz = fy - lab.B / 200;
            double x = LabFInverse(fx) * WhiteX, y = LabFInverse(fy) * WhiteY, z = LabFInverse(fz) * WhiteZ;
            double rl = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
            double gl = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
            double bl = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;
            Func<double, byte> to8 = v => Num.ClampByte(LinearToSRGB(Math.Min(1, Math.Max(0, v))) * 255);
            return new RGB(to8(rl), to8(gl), to8(bl));
        }

        /// <summary>CIE76 ΔE.</summary>
        public static double DeltaE(LabColor x, LabColor y)
        {
            double dL = x.L - y.L, da = x.A - y.A, db = x.B - y.B;
            return Math.Sqrt(dL * dL + da * da + db * db);
        }

        public static double DeltaE(RGB x, RGB y) => DeltaE(Lab(x), Lab(y));

        public static double Chroma(RGB c) { var l = Lab(c); return Math.Sqrt(l.A * l.A + l.B * l.B); }

        /// <summary>L* ≥ 92 and chroma &lt; 8 — a color that is effectively the white paper.</summary>
        public static bool IsNearWhite(RGB c) { var l = Lab(c); return l.L >= 92 && Math.Sqrt(l.A * l.A + l.B * l.B) < 8; }

        /// <summary>Hue 0..&lt;360, saturation 0...100, brightness 0...100.</summary>
        public static void Hsb(RGB c, out double h, out double s, out double v)
        {
            double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
            double mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b)), d = mx - mn;
            h = 0;
            if (d > 0)
            {
                if (mx == r) h = 60 * ((g - b) / d);
                else if (mx == g) h = 60 * ((b - r) / d + 2);
                else h = 60 * ((r - g) / d + 4);
                if (h < 0) h += 360;
                if (h >= 360) h -= 360;
            }
            s = mx > 0 ? d / mx * 100 : 0;
            v = mx * 100;
        }

        public static double[] Hsb(RGB c) { double h, s, v; Hsb(c, out h, out s, out v); return new[] { h, s, v }; }

        /// <summary>Hue 0..&lt;360, saturation 0...100, lightness 0...100 (HSL, as in CSS and Windows pickers).</summary>
        public static double[] Hsl(RGB c)
        {
            double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
            double mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b)), d = mx - mn;
            double l = (mx + mn) / 2;
            double denom = 1 - Math.Abs(2 * l - 1);
            double s = d == 0 || denom <= 0 ? 0 : Math.Min(1, d / denom);
            return new[] { Hsb(c)[0], s * 100, l * 100 };
        }

        /// <summary>HSB (hue in degrees, saturation and brightness 0...100) → sRGB.</summary>
        public static RGB RgbFromHsb(double hue, double saturation, double brightness)
        {
            double h = hue % 360;
            if (h < 0) h += 360;
            h /= 60;
            double s = Math.Min(Math.Max(saturation / 100, 0), 1), v = Math.Min(Math.Max(brightness / 100, 0), 1);
            double c = v * s;
            double x = c * (1 - Math.Abs(h % 2 - 1));
            double m = v - c;
            double r1, g1, b1;
            switch ((int)h)
            {
                case 0: r1 = c; g1 = x; b1 = 0; break;
                case 1: r1 = x; g1 = c; b1 = 0; break;
                case 2: r1 = 0; g1 = c; b1 = x; break;
                case 3: r1 = 0; g1 = x; b1 = c; break;
                case 4: r1 = x; g1 = 0; b1 = c; break;
                default: r1 = c; g1 = 0; b1 = x; break;
            }
            Func<double, byte> to8 = u => Num.ClampByte((u + m) * 255);
            return new RGB(to8(r1), to8(g1), to8(b1));
        }

        /// <summary>A short human name, e.g. "dark red", "light gray", "black".</summary>
        public static string ApproximateName(RGB c)
        {
            double h, s, v;
            Hsb(c, out h, out s, out v);
            double L = Lab(c).L;
            if (v < 10) return "black";
            if (s < 12 || (v < 25 && s < 30))
            {
                if (L >= 95) return "white";
                if (L < 12) return "black";
                if (L >= 80) return "light gray";
                if (L < 35) return "dark gray";
                return "gray";
            }
            if (h >= 15 && h < 50 && v < 70)
            {
                if (v < 40) return "dark brown";
                if (s < 45) return "light brown";
                return "brown";
            }
            string family;
            if (h < 12) family = "red";
            else if (h < 40) family = "orange";
            else if (h < 65) family = "yellow";
            else if (h < 85) family = "lime";
            else if (h < 150) family = "green";
            else if (h < 172) family = "teal";
            else if (h < 190) family = "cyan";
            else if (h < 255) family = "blue";
            else if (h < 285) family = "purple";
            else if (h < 320) family = "magenta";
            else if (h < 345) family = "pink";
            else family = "red";
            if (family == "red" && s < 60 && v > 80) return s < 35 ? "pale pink" : "pink";
            if (v < 55) return "dark " + family;
            if (s < 35 && v > 80) return "pale " + family;
            if (s < 65 && v > 80) return "light " + family;
            return family;
        }

        /// <summary>Palette indices with count &gt; 0, in the requested drawing order. Ties broken by index.</summary>
        public static int[] Order(QuantizedImage q, ColorOrder order)
        {
            int n = Math.Min(q.Palette.Length, q.Counts.Length);
            var live = Enumerable.Range(0, n).Where(i => q.Counts[i] > 0).ToList();
            switch (order)
            {
                case ColorOrder.LightToDark:
                case ColorOrder.DarkToLight:
                    {
                        var L = live.ToDictionary(i => i, i => Lab(q.Palette[i]).L);
                        live.Sort((i, j) =>
                        {
                            if (L[i] != L[j]) return order == ColorOrder.LightToDark ? L[j].CompareTo(L[i]) : L[i].CompareTo(L[j]);
                            return i.CompareTo(j);
                        });
                        return live.ToArray();
                    }
                case ColorOrder.MostPixelsFirst:
                    live.Sort((i, j) => q.Counts[i] != q.Counts[j] ? q.Counts[j].CompareTo(q.Counts[i]) : i.CompareTo(j));
                    return live.ToArray();
                default:
                    live.Sort((i, j) => q.Counts[i] != q.Counts[j] ? q.Counts[i].CompareTo(q.Counts[j]) : i.CompareTo(j));
                    return live.ToArray();
            }
        }
    }

    public static class TimeEstimator
    {
        /// <summary>Fixed per-posted-event overhead, seconds.</summary>
        public const double PerEventOverhead = 0.00015;

        /// <summary>Drag events the DrawingEngine posts for a stroke (2 for a dot).</summary>
        public static int DragEventCount(ScreenStroke stroke, double stepSize)
        {
            if (stroke.IsDot) return 2;
            double step = stepSize > 0 ? stepSize : 1;
            var pts = stroke.Points;
            int n = 0;
            for (int i = 1; i < pts.Length; i++)
            {
                double d = PointD.Distance(pts[i], pts[i - 1]);
                if (d > 0) n += Math.Max(1, (int)Math.Ceiling(d / step));
            }
            return Math.Max(1, n);
        }

        /// <summary>Estimated wall-clock seconds the DrawingEngine needs for these strokes.</summary>
        public static double Estimate(IEnumerable<ScreenStroke> strokes, SpeedSettings speed)
        {
            double fixedTime = speed.MoveDelay + speed.DownDelay + speed.EndDelay + speed.UpDelay;
            double total = 0;
            foreach (var s in strokes)
            {
                int drags = DragEventCount(s, speed.StepSize);
                int events = drags + 3;
                int corners = s.IsDot ? 0 : s.Via.Length;
                total += fixedTime + drags * speed.EventDelay + events * PerEventOverhead + corners * speed.EndDelay;
            }
            return total;
        }

        /// <summary>"1 h 4 min", "3 min 20 s", "12 s".</summary>
        public static string Format(double seconds)
        {
            if (double.IsNaN(seconds) || double.IsInfinity(seconds) || seconds < 0.5) return "0 s";
            int total = (int)Num.Round(seconds);
            if (total < 60) return total + " s";
            if (total < 3600)
            {
                int m = total / 60, s = total % 60;
                return s == 0 ? m + " min" : m + " min " + s + " s";
            }
            int totalMinutes = (int)Num.Round(seconds / 60);
            int h = totalMinutes / 60, mm = totalMinutes % 60;
            return mm == 0 ? h + " h" : h + " h " + mm + " min";
        }
    }
}
