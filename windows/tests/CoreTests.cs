using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using DrawBot.Core;

namespace DrawBot.Tests
{
    static class Img
    {
        public static RGBAImage Make(int w, int h, Func<int, int, byte[]> px)
        {
            var data = new byte[w * h * 4];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    var p = px(x, y);
                    int i = (y * w + x) * 4;
                    data[i] = p[0]; data[i + 1] = p[1]; data[i + 2] = p[2]; data[i + 3] = p[3];
                }
            return new RGBAImage(w, h, data);
        }

        public static byte[] C(int r, int g, int b, int a = 255) => new[] { (byte)r, (byte)g, (byte)b, (byte)a };

        /// <summary>Photo-like synthetic image: gradients, soft blobs and noise (deterministic).</summary>
        public static RGBAImage PhotoLike(int w, int h, ulong seed = 42)
        {
            var rng = new SplitMix64(seed);
            return Make(w, h, (x, y) =>
            {
                double fx = (double)x / w, fy = (double)y / h;
                double blob = Math.Exp(-((fx - 0.3) * (fx - 0.3) + (fy - 0.6) * (fy - 0.6)) * 12);
                double blob2 = Math.Exp(-((fx - 0.75) * (fx - 0.75) + (fy - 0.25) * (fy - 0.25)) * 20);
                double noise = (double)(rng.Next() % 17) - 8;
                Func<double, int> c = v => (int)Math.Max(0, Math.Min(255, v + noise));
                return C(c(40 + 180 * fx + 30 * blob2), c(60 + 150 * blob + 40 * Math.Sin(fy * 9)), c(200 - 150 * fy + 50 * blob2));
            });
        }

        public static byte[] Pixel(RGBAImage img, int x, int y)
        {
            int i = (y * img.Width + x) * 4;
            return new[] { img.Data[i], img.Data[i + 1], img.Data[i + 2], img.Data[i + 3] };
        }
    }

    public sealed class GeometryTests
    {
        public void TestGridLayoutCentersTheGrid()
        {
            var l = new GridLayout(new RectD(100, 50, 403, 301), 4);
            Assert.Equal(100, l.Columns);
            Assert.Equal(75, l.Rows);
            Assert.Near(101.5, l.Origin.X, 1e-9);
            Assert.Near(50.5, l.Origin.Y, 1e-9);
            var c = l.CellCenter(0, 0);
            Assert.Near(103.5, c.X, 1e-9);
            Assert.Near(52.5, c.Y, 1e-9);
            Assert.Near(103.5 + 99 * 4, l.CellCenter(99, 74).X, 1e-9);
        }

        public void TestGridLayoutAtLeastOneCellAndStandardizes()
        {
            var l = new GridLayout(new RectD(10, 10, -2, -3), 4);
            Assert.Equal(1, l.Columns);
            Assert.Equal(1, l.Rows);
            Assert.Equal(new RectD(8, 7, 2, 3), l.Canvas);
            Assert.Equal(0.5, new GridLayout(new RectD(0, 0, 10, 10), 0).PenSize);
        }

        public void TestRectFromRoundsOutward()
        {
            Assert.Equal(new RectD(10, 20, 31, 11), Geometry.RectFrom(new PointD(40.2, 20.7), new PointD(10.9, 30.1)));
        }

        public void TestClampAndContains()
        {
            var r = new RectD(0, 0, 10, 10);
            Assert.Equal(new PointD(10, 0), Geometry.Clamp(new PointD(15, -3), r));
            Assert.True(r.Contains(new PointD(0, 0)));
            Assert.False(r.Contains(new PointD(10, 5)), "max edge is exclusive");
            Assert.True(r.Intersection(new RectD(20, 20, 5, 5)).IsNull);
            Assert.Equal(new RectD(0, 0, 25, 25), r.Union(new RectD(20, 20, 5, 5)));
        }
    }

    public sealed class ColorMathTests
    {
        public void TestLabOfWhiteAndBlack()
        {
            var w = ColorMath.Lab(new RGB(255, 255, 255));
            Assert.Near(100, w.L, 0.01); Assert.Near(0, w.A, 0.01); Assert.Near(0, w.B, 0.01);
            Assert.Near(0, ColorMath.Lab(new RGB(0, 0, 0)).L, 0.01);
        }

        public void TestLabRoundTrip()
        {
            var rng = new SplitMix64(7);
            for (int i = 0; i < 500; i++)
            {
                var c = new RGB((byte)(rng.Next() % 256), (byte)(rng.Next() % 256), (byte)(rng.Next() % 256));
                Assert.Equal(c, ColorMath.Rgb(ColorMath.Lab(c)));
            }
        }

        public void TestKnownLabValue()
        {
            var red = ColorMath.Lab(new RGB(255, 0, 0));
            Assert.Near(53.24, red.L, 0.05); Assert.Near(80.09, red.A, 0.1); Assert.Near(67.20, red.B, 0.1);
        }

        public void TestNearWhite()
        {
            Assert.True(ColorMath.IsNearWhite(new RGB(250, 250, 248)));
            Assert.False(ColorMath.IsNearWhite(new RGB(255, 240, 150)));
            Assert.False(ColorMath.IsNearWhite(new RGB(200, 200, 200)));
        }

        public void TestHsbAndBack()
        {
            var c = ColorMath.RgbFromHsb(30, 80, 90);
            Assert.Equal(new RGB(230, 138, 46), c);
            var hsb = ColorMath.Hsb(c);
            Assert.Near(30, hsb[0], 0.5); Assert.Near(80, hsb[1], 0.5); Assert.Near(90, hsb[2], 0.5);
            Assert.Equal(new RGB(255, 0, 0), ColorMath.RgbFromHsb(360, 100, 100));
            Assert.Equal(new RGB(0, 0, 255), ColorMath.RgbFromHsb(-120, 100, 100));
            var hsl = ColorMath.Hsl(new RGB(255, 0, 0));
            Assert.Near(100, hsl[1], 1e-9); Assert.Near(50, hsl[2], 1e-9);
        }

        public void TestApproximateNames()
        {
            Assert.Equal("black", ColorMath.ApproximateName(new RGB(5, 5, 5)));
            Assert.Equal("white", ColorMath.ApproximateName(new RGB(255, 255, 255)));
            Assert.Equal("red", ColorMath.ApproximateName(new RGB(230, 20, 20)));
            Assert.Equal("dark blue", ColorMath.ApproximateName(new RGB(20, 30, 120)));
            Assert.Equal("brown", ColorMath.ApproximateName(new RGB(150, 90, 40)));
            Assert.Equal("gray", ColorMath.ApproximateName(new RGB(128, 128, 128)));
        }

        public void TestOrder()
        {
            var q = new QuantizedImage(3, 1, new[] { 0, 1, 2 }, new[] { new RGB(0, 0, 0), new RGB(255, 255, 255), new RGB(128, 128, 128) }, new[] { 5, 1, 3 });
            Assert.Seq(new[] { 1, 2, 0 }, ColorMath.Order(q, ColorOrder.LightToDark));
            Assert.Seq(new[] { 0, 2, 1 }, ColorMath.Order(q, ColorOrder.DarkToLight));
            Assert.Seq(new[] { 0, 2, 1 }, ColorMath.Order(q, ColorOrder.MostPixelsFirst));
            Assert.Seq(new[] { 1, 2, 0 }, ColorMath.Order(q, ColorOrder.FewestPixelsFirst));
        }
    }

    public sealed class TimeEstimatorTests
    {
        public void TestDragEventCount()
        {
            Assert.Equal(2, TimeEstimator.DragEventCount(new ScreenStroke(new PointD(1, 1), new PointD(1, 1)), 4));
            Assert.Equal(5, TimeEstimator.DragEventCount(new ScreenStroke(new PointD(0, 0), new PointD(20, 0)), 4));
            Assert.Equal(6, TimeEstimator.DragEventCount(new ScreenStroke(new PointD(0, 0), new PointD(21, 0)), 4));
            Assert.Equal(5, TimeEstimator.DragEventCount(new ScreenStroke(new PointD(0, 0), new PointD(0, 4), new[] { new PointD(8, 0), new PointD(8, 4) }), 4));
        }

        public void TestEstimateMatchesFormula()
        {
            var s = SpeedSettings.Normal;
            var strokes = new[] { new ScreenStroke(new PointD(0, 0), new PointD(40, 0)), new ScreenStroke(new PointD(5, 5), new PointD(5, 5)) };
            double fixedT = s.MoveDelay + s.DownDelay + s.EndDelay + s.UpDelay;
            double expected = fixedT + 10 * s.EventDelay + 13 * TimeEstimator.PerEventOverhead + fixedT + 2 * s.EventDelay + 5 * TimeEstimator.PerEventOverhead;
            Assert.Near(expected, TimeEstimator.Estimate(strokes, s), 1e-12);
        }

        public void TestFormat()
        {
            Assert.Equal("0 s", TimeEstimator.Format(0.2));
            Assert.Equal("12 s", TimeEstimator.Format(12.4));
            Assert.Equal("1 min", TimeEstimator.Format(60));
            Assert.Equal("3 min 20 s", TimeEstimator.Format(200));
            Assert.Equal("1 h 4 min", TimeEstimator.Format(3840));
            Assert.Equal("2 h", TimeEstimator.Format(7200));
        }

        public void TestAdaptedEndDelay()
        {
            Assert.Near(1.15 / 60, SpeedSettings.Normal.Adapted(60).EndDelay, 1e-12);
            Assert.Near(0.012, SpeedSettings.Normal.Adapted(144).EndDelay, 1e-12);
            Assert.Near(0.012, SpeedSettings.Normal.Adapted(0).EndDelay, 1e-12);
        }
    }

    public sealed class QuantizerTests
    {
        public void TestExactColorsKeptInOrderOfAppearance()
        {
            var img = Img.Make(4, 2, (x, y) => x < 2 ? Img.C(200, 10, 10) : y == 0 ? Img.C(10, 10, 200) : Img.C(10, 200, 10));
            var q = Quantizer.Quantize(img, new QuantizeOptions(8, 0));
            Assert.Seq(new[] { new RGB(200, 10, 10), new RGB(10, 10, 200), new RGB(10, 200, 10) }, q.Palette);
            Assert.Seq(new[] { 0, 0, 1, 1, 0, 0, 2, 2 }, q.Labels);
            Assert.Seq(new[] { 4, 2, 2 }, q.Counts);
        }

        public void TestTransparentPixelsAreMinusOne()
        {
            var img = Img.Make(3, 1, (x, y) => x == 1 ? Img.C(0, 0, 0, 10) : Img.C(255, 0, 0));
            var q = Quantizer.Quantize(img, new QuantizeOptions(4));
            Assert.Seq(new[] { 0, -1, 0 }, q.Labels);
            var empty = Quantizer.Quantize(Img.Make(2, 2, (x, y) => Img.C(0, 0, 0, 0)), new QuantizeOptions(4));
            Assert.Equal(0, empty.Palette.Length);
            Assert.True(empty.Labels.All(l => l == -1));
        }

        public void TestKMeansRespectsMaxColorsAndIsDeterministic()
        {
            var img = Img.PhotoLike(120, 80);
            var a = Quantizer.Quantize(img, new QuantizeOptions(6, 0));
            var b = Quantizer.Quantize(img, new QuantizeOptions(6, 0));
            Assert.True(a.Palette.Length <= 6 && a.Palette.Length >= 4, "palette size " + a.Palette.Length);
            Assert.True(a.Equals(b), "same input, same output");
            Assert.Equal(img.Width * img.Height, a.Counts.Sum());
            Assert.True(a.Counts.All(c => c > 0));
            Assert.True(a.Labels.All(l => l >= 0 && l < a.Palette.Length));
        }

        public void TestMergeCombinesNearDuplicates()
        {
            var img = Img.Make(4, 1, (x, y) => x < 2 ? Img.C(100, 100, 100) : Img.C(102, 101, 100));
            Assert.Equal(2, Quantizer.Quantize(img, new QuantizeOptions(8, 0)).Palette.Length);
            var merged = Quantizer.Quantize(img, new QuantizeOptions(8, 6));
            Assert.Equal(1, merged.Palette.Length);
            Assert.Equal(new RGB(101, 101, 100), merged.Palette[0]);
        }

        public void TestOneColorIsADoodleOfTheDarkInk()
        {
            var img = Img.Make(10, 1, (x, y) => x < 3 ? Img.C(20, 20, 30) : Img.C(240, 240, 235));
            var q = Quantizer.Quantize(img, new QuantizeOptions(1));
            Assert.Equal(1, q.Palette.Length);
            Assert.Equal(new RGB(20, 20, 30), q.Palette[0]);
            Assert.Seq(new[] { 0, 0, 0, -1, -1, -1, -1, -1, -1, -1 }, q.Labels);
            var solid = Quantizer.Quantize(Img.Make(3, 1, (x, y) => Img.C(9, 9, 9)), new QuantizeOptions(1));
            Assert.Equal(1, solid.Palette.Length);
        }

        public void TestRemovingAndPreview()
        {
            var q = new QuantizedImage(3, 1, new[] { 0, 1, -1 }, new[] { new RGB(1, 2, 3), new RGB(4, 5, 6) }, new[] { 1, 1 });
            var r = Quantizer.Removing(new HashSet<int> { 1 }, q);
            Assert.Seq(new[] { 0, -1, -1 }, r.Labels);
            Assert.Seq(new[] { 1, 0 }, r.Counts);
            var p = Quantizer.PreviewImage(q);
            Assert.Seq(new byte[] { 1, 2, 3, 255, 4, 5, 6, 255, 0, 0, 0, 0 }, p.Data);
        }

        public void TestSnapMovesColorsToSwatchesAndMerges()
        {
            var q = new QuantizedImage(3, 1, new[] { 0, 1, 2 }, new[] { new RGB(250, 10, 10), new RGB(230, 30, 20), new RGB(10, 10, 240) }, new[] { 1, 1, 1 });
            var s = Quantizer.Snap(q, new[] { new RGB(0, 0, 255), new RGB(255, 0, 0) });
            Assert.Seq(new[] { new RGB(255, 0, 0), new RGB(0, 0, 255) }, s.Palette);
            Assert.Seq(new[] { 0, 0, 1 }, s.Labels);
            Assert.Seq(new[] { 2, 1 }, s.Counts);
        }
    }

    public sealed class ImageLoaderTests
    {
        public void TestRasterizeFitsAndCentersWithTransparentLetterbox()
        {
            var img = Img.Make(20, 10, (x, y) => Img.C(255, 0, 0));
            var r = ImageLoader.Rasterize(img, 10, 10);
            Assert.Equal(0, Img.Pixel(r, 5, 0)[3]);
            Assert.Equal(0, Img.Pixel(r, 5, 9)[3]);
            Assert.Seq(new byte[] { 255, 0, 0, 255 }, Img.Pixel(r, 5, 5));
            Assert.Seq(new byte[] { 255, 0, 0, 255 }, Img.Pixel(r, 0, 3));
        }

        public void TestBoxDownsampleKeepsThinLines()
        {
            // A 1 px black line every 10 px on white; reduced 10× it must still darken its cells.
            var img = Img.Make(200, 200, (x, y) => x % 10 == 0 ? Img.C(0, 0, 0) : Img.C(255, 255, 255));
            var r = ImageLoader.Rasterize(img, 20, 20);
            var p = Img.Pixel(r, 3, 3);
            Assert.Near(255 * 0.9, p[0], 2);
        }

        public void TestPixelArtUpscaleStaysCrisp()
        {
            var img = Img.Make(2, 2, (x, y) => (x + y) % 2 == 0 ? Img.C(0, 0, 0) : Img.C(255, 255, 255));
            var r = ImageLoader.Rasterize(img, 20, 20);
            var colors = new HashSet<string>();
            for (int i = 0; i < r.Data.Length; i += 4) colors.Add(r.Data[i] + "," + r.Data[i + 1] + "," + r.Data[i + 2]);
            Assert.Equal(2, colors.Count);
        }

        public void TestStraightAlphaOutput()
        {
            var img = Img.Make(4, 4, (x, y) => Img.C(200, 100, 50, 128));
            var r = ImageLoader.Rasterize(img, 4, 4);
            var p = Img.Pixel(r, 1, 1);
            Assert.Near(200, p[0], 1); Assert.Near(100, p[1], 1); Assert.Near(50, p[2], 1); Assert.Near(128, p[3], 1);
        }

        public void TestLoadsPngAndAppliesNothingWeird()
        {
            var path = Path.Combine(Path.GetTempPath(), "drawbot-test-" + Guid.NewGuid().ToString("N") + ".png");
            using (var bmp = new Bitmap(3, 2, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
            {
                bmp.SetPixel(0, 0, Color.FromArgb(255, 10, 20, 30));
                bmp.SetPixel(2, 1, Color.FromArgb(0, 0, 0, 0));
                bmp.Save(path, ImageFormat.Png);
            }
            try
            {
                var img = ImageLoader.Load(path);
                Assert.Equal(3, img.Width); Assert.Equal(2, img.Height);
                Assert.Seq(new byte[] { 10, 20, 30, 255 }, Img.Pixel(img, 0, 0));
                Assert.Equal(0, Img.Pixel(img, 2, 1)[3]);
            }
            finally { File.Delete(path); }
            try { ImageLoader.Load(path); Assert.Fail("expected an error for a missing file"); } catch (ImageLoaderException) { }
            Assert.True(ImageLoader.Load(new byte[] { 1, 2, 3 }) == null);
        }
    }

    public sealed class StrokePlannerTests
    {
        static QuantizedImage Grid(params string[] rows)
        {
            int w = rows[0].Length, h = rows.Length;
            var labels = new int[w * h];
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) labels[y * w + x] = rows[y][x] == '.' ? -1 : rows[y][x] - '0';
            int n = labels.Max() + 1;
            var palette = Enumerable.Range(0, n).Select(i => new RGB((byte)(i * 40), 0, 0)).ToArray();
            var counts = Enumerable.Range(0, n).Select(i => labels.Count(l => l == i)).ToArray();
            return new QuantizedImage(w, h, labels, palette, counts);
        }

        public void TestRunsAreSerpentine()
        {
            var q = Grid("00.0", "0000", ".00.");
            var runs = StrokePlanner.Runs(0, q);
            Assert.Seq(new[] { new GridRun(0, 0, 1), new GridRun(0, 3, 3), new GridRun(1, 3, 0), new GridRun(2, 1, 2) }, runs);
        }

        /// <summary>Every cell of the color is on some path; consecutive corners share a row or column and stay on the color.</summary>
        static void CheckPaths(QuantizedImage q, int color)
        {
            var paths = StrokePlanner.Paths(color, q);
            var covered = new HashSet<StrokePlanner.Cell>();
            foreach (var path in paths)
            {
                if (path.Count == 1) covered.Add(path[0]);
                for (int i = 1; i < path.Count; i++)
                {
                    var a = path[i - 1]; var b = path[i];
                    Assert.True(a.Col == b.Col || a.Row == b.Row, "diagonal segment " + a + "→" + b);
                    int steps = Math.Abs(a.Col - b.Col) + Math.Abs(a.Row - b.Row);
                    for (int k = 0; k <= steps; k++)
                    {
                        var c = new StrokePlanner.Cell(a.Col + Math.Sign(b.Col - a.Col) * k, a.Row + Math.Sign(b.Row - a.Row) * k);
                        Assert.Equal(color, q.Labels[c.Row * q.Width + c.Col], "path leaves the color at " + c);
                        covered.Add(c);
                    }
                }
            }
            for (int i = 0; i < q.Labels.Length; i++)
                if (q.Labels[i] == color) Assert.True(covered.Contains(new StrokePlanner.Cell(i % q.Width, i / q.Width)), "cell " + i + " not painted");
        }

        public void TestSolidBlobIsOneStroke()
        {
            var rows = Enumerable.Range(0, 20).Select(_ => new string('0', 30)).ToArray();
            var q = Grid(rows);
            Assert.Equal(1, StrokePlanner.Paths(0, q).Count);
            CheckPaths(q, 0);
        }

        public void TestPathsCoverAndAvoidOtherColors()
        {
            var q = Grid("0001110000", "0101010110", "0111011100", "0000010000", "1111111111", "0.0.0.0.0.");
            CheckPaths(q, 0);
            CheckPaths(q, 1);
            var noisy = Img.PhotoLike(60, 40);
            var nq = Quantizer.Quantize(noisy, new QuantizeOptions(6, 0));
            for (int c = 0; c < nq.Palette.Length; c++) CheckPaths(nq, c);
        }

        public void TestThinLinesNeedFewStrokes()
        {
            var q = Grid("0000000000", "1111111111", "0000000000", "1111111111", "0000000000", "1111111111");
            Assert.True(StrokePlanner.Paths(1, q).Count <= 3);
            Assert.Equal(3, StrokePlanner.Runs(1, q).Count);
        }

        public void TestDotsAndScreenStrokes()
        {
            var q = Grid("0..", "...", "..0");
            var layout = new GridLayout(new RectD(0, 0, 12, 12), 4);
            var strokes = StrokePlanner.Strokes(0, q, layout);
            Assert.Equal(2, strokes.Count);
            Assert.True(strokes.All(s => s.IsDot));
            Assert.Equal(new PointD(2, 2), strokes[0].Start);
            Assert.Equal(new PointD(10, 10), strokes[1].Start);
            var rows = StrokePlanner.Strokes(0, Grid("000"), new GridLayout(new RectD(0, 0, 12, 4), 4), StrokeStyle.Rows);
            Assert.Equal(new ScreenStroke(new PointD(2, 2), new PointD(10, 2)), rows[0]);
        }

        public void TestAStar()
        {
            var mask = new[] { true, true, true, false, true, true, true, true, true };   // 3×3, (0,1) blocked
            var way = StrokePlanner.AStar(new StrokePlanner.Cell(0, 0), new StrokePlanner.Cell(0, 2), mask, 3, 3, 10);
            Assert.Equal(5, way.Count);
            Assert.True(StrokePlanner.AStar(new StrokePlanner.Cell(0, 0), new StrokePlanner.Cell(0, 2), mask, 3, 3, 3) == null);
        }
    }

    public sealed class PaletteLearnerTests
    {
        public void TestReadsClickedSwatchDespiteCheckMark()
        {
            // Three 20×20 swatches; the middle one has a white check mark across its center.
            var colors = new[] { Img.C(200, 30, 30), Img.C(30, 160, 60), Img.C(40, 60, 200) };
            var img = Img.Make(80, 30, (x, y) =>
            {
                int i = x / 25;
                if (i > 2 || x % 25 >= 20 || y < 5 || y >= 25) return Img.C(240, 240, 240);
                if (i == 1 && Math.Abs((x - 25) - (y - 5)) <= 1) return Img.C(255, 255, 255);
                return colors[i];
            });
            var clicks = new List<PointD> { new PointD(10, 15), new PointD(35, 15), new PointD(60, 15) };
            var found = PaletteLearner.Analyze(img, new List<RGBAImage> { img, img, img }, clicks);
            Assert.Seq(new[] { new RGB(200, 30, 30), new RGB(30, 160, 60), new RGB(40, 60, 200) }, found);
        }

        public void TestSwatchesDeduplicateBySpot()
        {
            var s = PaletteLearner.Swatches(new[] { new PointD(10, 10), new PointD(50, 10), new PointD(12, 11) },
                new[] { new RGB(1, 1, 1), new RGB(2, 2, 2), new RGB(3, 3, 3) }, new[] { 1, 1, 2 });
            Assert.Equal(2, s.Count);
            Assert.Equal(new RGB(3, 3, 3), s[0].Color);
            Assert.Equal(2, s[0].ClickCount);
        }
    }

    public sealed class JsonTests
    {
        public void TestRoundTrip()
        {
            var d = new Dictionary<string, object> { { "a", 1.5 }, { "b", "x\"y\n" }, { "c", new List<object> { true, null, 3.0 } }, { "d", new Dictionary<string, object>() } };
            var back = Json.Obj(Json.Parse(Json.Write(d)));
            Assert.Equal(1.5, (double)back["a"]);
            Assert.Equal("x\"y\n", (string)back["b"]);
            Assert.Equal(3, Json.Arr(back["c"]).Count);
            Assert.True(Json.Arr(back["c"])[1] == null);
        }

        public void TestBrokenProfilesFileLosesNothingElse()
        {
            var json = "{\"good\": {\"appKey\": \"good\", \"appName\": \"Good\", \"steps\": [], \"summary\": \"s\", \"isExact\": true}, \"bad\": {\"steps\": [{\"weird\": 1}]}}";
            var p = LearnJson.Profiles(json);
            Assert.Equal(1, p.Count);
            Assert.Equal("Good", p["good"].AppName);
            Assert.Equal(0, LearnJson.Profiles("not json").Count);
        }
    }
}
