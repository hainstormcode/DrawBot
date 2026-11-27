using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

// Shared value types: the C# counterpart of Sources/DrawBotCore/Types.swift.
//
// Coordinates: Windows virtual-screen coordinates in PHYSICAL pixels (DrawBot runs per-monitor
// DPI aware), origin at the top-left of the primary monitor, y grows DOWN. That is the space
// SendInput, GetCursorPos, window rectangles and low-level hooks all use, so nothing here
// needs converting.

namespace DrawBot.Core
{
    /// <summary>Rounding as Swift's <c>.rounded()</c> does it: halves away from zero.</summary>
    public static class Num
    {
        public static double Round(double v) => Math.Round(v, MidpointRounding.AwayFromZero);
        public static float Round(float v) => (float)Math.Round(v, MidpointRounding.AwayFromZero);
        public static byte ClampByte(double v) => (byte)Math.Min(255, Math.Max(0, Round(v)));
        public static string F(double v, int decimals) => v.ToString("F" + decimals, CultureInfo.InvariantCulture);
        public static string Inv(double v) => v.ToString("R", CultureInfo.InvariantCulture);
    }

    public struct PointD : IEquatable<PointD>
    {
        public double X;
        public double Y;
        public PointD(double x, double y) { X = x; Y = y; }
        public static readonly PointD Zero = new PointD(0, 0);
        public bool Equals(PointD o) => X == o.X && Y == o.Y;
        public override bool Equals(object obj) => obj is PointD p && Equals(p);
        public override int GetHashCode() => X.GetHashCode() * 397 ^ Y.GetHashCode();
        public static bool operator ==(PointD a, PointD b) => a.Equals(b);
        public static bool operator !=(PointD a, PointD b) => !a.Equals(b);
        public static double Distance(PointD a, PointD b) => Hypot(a.X - b.X, a.Y - b.Y);
        public static double Hypot(double x, double y) => Math.Sqrt(x * x + y * y);
        public override string ToString() => "(" + Num.F(X, 1) + ", " + Num.F(Y, 1) + ")";
    }

    /// <summary>A rectangle like CGRect: Contains is inclusive of the min edges, exclusive of the max edges.</summary>
    public struct RectD : IEquatable<RectD>
    {
        public double X, Y, Width, Height;
        public RectD(double x, double y, double w, double h) { X = x; Y = y; Width = w; Height = h; }
        public static RectD FromPoints(PointD a, PointD b) =>
            new RectD(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));
        public static RectD At(PointD p) => new RectD(p.X, p.Y, 0, 0);
        public static readonly RectD Null = new RectD(double.PositiveInfinity, double.PositiveInfinity, 0, 0);

        public bool IsNull => double.IsInfinity(X) || double.IsInfinity(Y);
        public RectD Standardized
        {
            get
            {
                if (IsNull) return this;
                double x = X, y = Y, w = Width, h = Height;
                if (w < 0) { x += w; w = -w; }
                if (h < 0) { y += h; h = -h; }
                return new RectD(x, y, w, h);
            }
        }
        public double MinX => Standardized.X;
        public double MinY => Standardized.Y;
        public double MaxX { get { var s = Standardized; return s.X + s.Width; } }
        public double MaxY { get { var s = Standardized; return s.Y + s.Height; } }
        public double MidX { get { var s = Standardized; return s.X + s.Width / 2; } }
        public double MidY { get { var s = Standardized; return s.Y + s.Height / 2; } }
        public PointD Center => new PointD(MidX, MidY);
        public bool IsFinite => !double.IsNaN(X) && !double.IsInfinity(X) && !double.IsNaN(Y) && !double.IsInfinity(Y)
                                && !double.IsNaN(Width) && !double.IsInfinity(Width) && !double.IsNaN(Height) && !double.IsInfinity(Height);

        public bool Contains(PointD p)
        {
            if (IsNull) return false;
            var s = Standardized;
            return p.X >= s.X && p.X < s.X + s.Width && p.Y >= s.Y && p.Y < s.Y + s.Height;
        }

        /// <summary>True if <paramref name="r"/> lies entirely inside this rect.</summary>
        public bool Contains(RectD r)
        {
            if (IsNull || r.IsNull) return false;
            var s = Standardized; var o = r.Standardized;
            return o.X >= s.X && o.Y >= s.Y && o.X + o.Width <= s.X + s.Width && o.Y + o.Height <= s.Y + s.Height;
        }

        public bool Intersects(RectD r) => !Intersection(r).IsNull;

        public RectD Union(RectD r)
        {
            if (IsNull) return r;
            if (r.IsNull) return this;
            var a = Standardized; var b = r.Standardized;
            double x0 = Math.Min(a.X, b.X), y0 = Math.Min(a.Y, b.Y);
            double x1 = Math.Max(a.X + a.Width, b.X + b.Width), y1 = Math.Max(a.Y + a.Height, b.Y + b.Height);
            return new RectD(x0, y0, x1 - x0, y1 - y0);
        }

        public RectD Intersection(RectD r)
        {
            if (IsNull || r.IsNull) return Null;
            var a = Standardized; var b = r.Standardized;
            double x0 = Math.Max(a.X, b.X), y0 = Math.Max(a.Y, b.Y);
            double x1 = Math.Min(a.X + a.Width, b.X + b.Width), y1 = Math.Min(a.Y + a.Height, b.Y + b.Height);
            if (x1 < x0 || y1 < y0) return Null;
            return new RectD(x0, y0, x1 - x0, y1 - y0);
        }

        public RectD Inset(double dx, double dy)
        {
            if (IsNull) return this;
            var s = Standardized;
            var w = s.Width - 2 * dx; var h = s.Height - 2 * dy;
            if (w < 0 || h < 0) return Null;
            return new RectD(s.X + dx, s.Y + dy, w, h);
        }

        public RectD Offset(double dx, double dy) => new RectD(X + dx, Y + dy, Width, Height);

        /// <summary>Smallest rect with whole-number edges containing this one.</summary>
        public RectD Integral
        {
            get
            {
                if (IsNull) return this;
                var s = Standardized;
                double x0 = Math.Floor(s.X), y0 = Math.Floor(s.Y), x1 = Math.Ceiling(s.X + s.Width), y1 = Math.Ceiling(s.Y + s.Height);
                return new RectD(x0, y0, x1 - x0, y1 - y0);
            }
        }

        public bool Equals(RectD o) => X == o.X && Y == o.Y && Width == o.Width && Height == o.Height;
        public override bool Equals(object obj) => obj is RectD r && Equals(r);
        public override int GetHashCode() => (X.GetHashCode() * 397 ^ Y.GetHashCode()) * 397 ^ (Width.GetHashCode() * 31 + Height.GetHashCode());
        public static bool operator ==(RectD a, RectD b) => a.Equals(b);
        public static bool operator !=(RectD a, RectD b) => !a.Equals(b);
        public override string ToString() => "(" + Num.F(X, 0) + ", " + Num.F(Y, 0) + ", " + Num.F(Width, 0) + " × " + Num.F(Height, 0) + ")";
    }

    /// <summary>An opaque 8-bit sRGB color.</summary>
    public struct RGB : IEquatable<RGB>
    {
        public byte R, G, B;
        public RGB(int r, int g, int b) { R = (byte)r; G = (byte)g; B = (byte)b; }

        /// <summary>"#RRGGBB", uppercase.</summary>
        public string Hex => "#" + HexNoHash;
        /// <summary>Hex without the leading "#" (what most color pickers' hex fields want).</summary>
        public string HexNoHash => R.ToString("X2") + G.ToString("X2") + B.ToString("X2");

        public static bool TryParseHex(string s, out RGB c)
        {
            c = default(RGB);
            if (s == null) return false;
            s = s.Trim().Replace("#", "");
            if (s.Length != 6) return false;
            int v;
            if (!int.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v)) return false;
            c = new RGB((byte)((v >> 16) & 255), (byte)((v >> 8) & 255), (byte)(v & 255));
            return true;
        }

        public bool Equals(RGB o) => R == o.R && G == o.G && B == o.B;
        public override bool Equals(object obj) => obj is RGB c && Equals(c);
        public override int GetHashCode() => (R << 16) | (G << 8) | B;
        public static bool operator ==(RGB a, RGB b) => a.Equals(b);
        public static bool operator !=(RGB a, RGB b) => !a.Equals(b);
        public override string ToString() => Hex;
    }

    /// <summary>A raster at grid resolution. Row 0 is the TOP row. RGBA, 8 bits each, straight alpha.</summary>
    public sealed class RGBAImage : IEquatable<RGBAImage>
    {
        public readonly int Width;
        public readonly int Height;
        public byte[] Data;

        public RGBAImage(int width, int height, byte[] data)
        {
            if (data.Length != width * height * 4) throw new ArgumentException("RGBAImage data size mismatch");
            Width = width; Height = height; Data = data;
        }

        public RGBAImage(int width, int height) : this(width, height, new byte[width * height * 4]) { }

        public bool Equals(RGBAImage o) => o != null && Width == o.Width && Height == o.Height && Data.SequenceEqual(o.Data);
        public override bool Equals(object obj) => Equals(obj as RGBAImage);
        public override int GetHashCode() => Width * 31 + Height;
    }

    /// <summary>Result of color quantization. Labels[row * width + col] is a palette index, or -1 for transparent.</summary>
    public sealed class QuantizedImage : IEquatable<QuantizedImage>
    {
        public readonly int Width;
        public readonly int Height;
        public readonly int[] Labels;
        /// <summary>Palette index == label value. Every palette entry has count &gt; 0.</summary>
        public readonly RGB[] Palette;
        /// <summary>Number of pixels carrying each palette index.</summary>
        public readonly int[] Counts;

        public QuantizedImage(int width, int height, int[] labels, RGB[] palette, int[] counts)
        {
            Width = width; Height = height; Labels = labels; Palette = palette; Counts = counts;
        }

        public bool Equals(QuantizedImage o) => o != null && Width == o.Width && Height == o.Height
            && Labels.SequenceEqual(o.Labels) && Palette.SequenceEqual(o.Palette) && Counts.SequenceEqual(o.Counts);
        public override bool Equals(object obj) => Equals(obj as QuantizedImage);
        public override int GetHashCode() => Width * 31 + Height;
    }

    public sealed class QuantizeOptions : IEquatable<QuantizeOptions>
    {
        /// <summary>Upper bound on palette size, clamped to 1...64.</summary>
        public int MaxColors = 8;
        /// <summary>Pixels with alpha below this are transparent (label -1).</summary>
        public byte AlphaThreshold = 128;
        /// <summary>Clusters whose centers are closer than this CIE76 ΔE are merged.</summary>
        public double MergeDistance = 6.0;
        /// <summary>Deterministic seed.</summary>
        public ulong Seed = 0x5EED;

        public QuantizeOptions() { }
        public QuantizeOptions(int maxColors, double mergeDistance = 6.0, byte alphaThreshold = 128, ulong seed = 0x5EED)
        {
            MaxColors = maxColors; MergeDistance = mergeDistance; AlphaThreshold = alphaThreshold; Seed = seed;
        }
        public QuantizeOptions Copy() => new QuantizeOptions(MaxColors, MergeDistance, AlphaThreshold, Seed);
        public bool Equals(QuantizeOptions o) => o != null && MaxColors == o.MaxColors && AlphaThreshold == o.AlphaThreshold
            && MergeDistance == o.MergeDistance && Seed == o.Seed;
        public override bool Equals(object obj) => Equals(obj as QuantizeOptions);
        public override int GetHashCode() => MaxColors * 31 + MergeDistance.GetHashCode();
    }

    /// <summary>Maps grid cells onto the screen (virtual-screen pixels, y down).</summary>
    public sealed class GridLayout : IEquatable<GridLayout>
    {
        public readonly RectD Canvas;
        /// <summary>Distance in pixels between neighboring cell centers (≈ brush diameter).</summary>
        public readonly double PenSize;
        public readonly int Columns;
        public readonly int Rows;
        /// <summary>Top-left corner of cell (0,0). The grid is centered in Canvas.</summary>
        public readonly PointD Origin;

        public GridLayout(RectD canvas, double penSize)
        {
            double pen = Math.Max(0.5, penSize);
            canvas = canvas.Standardized;
            Canvas = canvas;
            PenSize = pen;
            Columns = Math.Max(1, (int)Math.Floor(canvas.Width / pen));
            Rows = Math.Max(1, (int)Math.Floor(canvas.Height / pen));
            double gridW = Columns * pen, gridH = Rows * pen;
            Origin = new PointD(canvas.X + (canvas.Width - gridW) / 2, canvas.Y + (canvas.Height - gridH) / 2);
        }

        public PointD CellCenter(int col, int row) => new PointD(Origin.X + (col + 0.5) * PenSize, Origin.Y + (row + 0.5) * PenSize);

        public bool Equals(GridLayout o) => o != null && Canvas == o.Canvas && PenSize == o.PenSize && Columns == o.Columns && Rows == o.Rows;
        public override bool Equals(object obj) => Equals(obj as GridLayout);
        public override int GetHashCode() => Canvas.GetHashCode() * 31 + PenSize.GetHashCode();
    }

    /// <summary>A horizontal run of same-colored cells in one grid row. Both ends inclusive.</summary>
    public struct GridRun : IEquatable<GridRun>
    {
        public readonly int Row, StartCol, EndCol;
        public GridRun(int row, int startCol, int endCol) { Row = row; StartCol = startCol; EndCol = endCol; }
        public int Length => Math.Abs(EndCol - StartCol) + 1;
        public bool Equals(GridRun o) => Row == o.Row && StartCol == o.StartCol && EndCol == o.EndCol;
        public override bool Equals(object obj) => obj is GridRun r && Equals(r);
        public override int GetHashCode() => (Row * 397 ^ StartCol) * 397 ^ EndCol;
        public override string ToString() => "row " + Row + ": " + StartCol + "→" + EndCol;
    }

    /// <summary>One press-drag-release gesture: from Start through every Via point to End.</summary>
    public sealed class ScreenStroke : IEquatable<ScreenStroke>
    {
        public readonly PointD Start;
        public readonly PointD End;
        public readonly PointD[] Via;

        public ScreenStroke(PointD start, PointD end, PointD[] via = null)
        {
            Start = start; End = end; Via = via ?? new PointD[0];
        }

        /// <summary>Every corner of the path: start, via…, end.</summary>
        public PointD[] Points
        {
            get
            {
                var p = new PointD[Via.Length + 2];
                p[0] = Start;
                Array.Copy(Via, 0, p, 1, Via.Length);
                p[p.Length - 1] = End;
                return p;
            }
        }

        public bool IsDot => Start == End && Via.All(v => v == Start);

        public double Length
        {
            get
            {
                double total = 0; var prev = Start;
                foreach (var p in Via.Concat(new[] { End })) { total += PointD.Distance(p, prev); prev = p; }
                return total;
            }
        }

        public bool Equals(ScreenStroke o) => o != null && Start == o.Start && End == o.End && Via.SequenceEqual(o.Via);
        public override bool Equals(object obj) => Equals(obj as ScreenStroke);
        public override int GetHashCode() => Start.GetHashCode() * 31 + End.GetHashCode();
    }

    public enum StrokeStyle { Paths, Rows }
    public enum ColorOrder { LightToDark, DarkToLight, MostPixelsFirst, FewestPixelsFirst }
    public enum SpeedPreset { Careful, Normal, Fast, Ludicrous }

    public static class EnumNames
    {
        public static string DisplayName(this StrokeStyle s) => s == StrokeStyle.Paths ? "A* paths" : "Top to bottom";

        public static string DisplayName(this ColorOrder o)
        {
            switch (o)
            {
                case ColorOrder.LightToDark: return "Light → dark";
                case ColorOrder.DarkToLight: return "Dark → light";
                case ColorOrder.MostPixelsFirst: return "Most area first";
                default: return "Least area first";
            }
        }

        public static string DisplayName(this SpeedPreset p)
        {
            switch (p)
            {
                case SpeedPreset.Careful: return "Careful (very laggy apps)";
                case SpeedPreset.Normal: return "Normal";
                case SpeedPreset.Fast: return "Fast";
                default: return "Ludicrous";
            }
        }

        public static SpeedSettings Settings(this SpeedPreset p)
        {
            switch (p)
            {
                case SpeedPreset.Careful: return SpeedSettings.Careful;
                case SpeedPreset.Normal: return SpeedSettings.Normal;
                case SpeedPreset.Fast: return SpeedSettings.Fast;
                default: return SpeedSettings.Ludicrous;
            }
        }

        public static T[] All<T>() where T : struct => (T[])Enum.GetValues(typeof(T));
    }

    /// <summary>Timing of synthetic mouse events (seconds; step size in pixels).</summary>
    public sealed class SpeedSettings : IEquatable<SpeedSettings>
    {
        public double StepSize, EventDelay, DownDelay, UpDelay, MoveDelay, EndDelay;

        public SpeedSettings(double stepSize, double eventDelay, double downDelay, double upDelay, double moveDelay, double endDelay = 0)
        {
            StepSize = stepSize; EventDelay = eventDelay; DownDelay = downDelay; UpDelay = upDelay; MoveDelay = moveDelay; EndDelay = endDelay;
        }

        // endDelay: apps (browsers especially) handle input once per screen refresh. If the button is
        // released in the same refresh as the stroke's last movement, the stroke is often never drawn.
        // These are minimums: Adapted(fps) raises EndDelay to 1.15 refreshes of the actual screen.
        public static SpeedSettings Careful => new SpeedSettings(2, 0.006, 0.030, 0.030, 0.020, 0.025);
        public static SpeedSettings Normal => new SpeedSettings(4, 0.003, 0.015, 0.015, 0.010, 0.012);
        public static SpeedSettings Fast => new SpeedSettings(8, 0.0015, 0.008, 0.008, 0.005, 0.010);
        public static SpeedSettings Ludicrous => new SpeedSettings(16, 0.0008, 0.004, 0.004, 0.003, 0.009);

        public SpeedSettings Copy() => new SpeedSettings(StepSize, EventDelay, DownDelay, UpDelay, MoveDelay, EndDelay);

        /// <summary>The pause before mouse-up at least 1.15 frames of a screen refreshing fps times per second.</summary>
        public SpeedSettings Adapted(int fps)
        {
            var s = Copy();
            if (fps > 0) s.EndDelay = Math.Max(EndDelay, 1.15 / fps);
            return s;
        }

        public bool Equals(SpeedSettings o) => o != null && StepSize == o.StepSize && EventDelay == o.EventDelay && DownDelay == o.DownDelay
            && UpDelay == o.UpDelay && MoveDelay == o.MoveDelay && EndDelay == o.EndDelay;
        public override bool Equals(object obj) => Equals(obj as SpeedSettings);
        public override int GetHashCode() => StepSize.GetHashCode() * 31 + EventDelay.GetHashCode();
    }
}
