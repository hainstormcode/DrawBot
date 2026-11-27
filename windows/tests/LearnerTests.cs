using System;
using System.Collections.Generic;
using System.Linq;
using DrawBot.Core;

namespace DrawBot.Tests
{
    /// <summary>Simulated users demonstrating colors on simulated color pickers.</summary>
    public sealed class ColorLearnerTests
    {
        readonly List<RectD> screens = new List<RectD> { new RectD(0, 0, 1512, 982) };
        readonly RectD canvas = new RectD(20, 300, 400, 400);
        readonly RGB a = ColorLearner.DemoColors[0];
        readonly RGB b = ColorLearner.DemoColors[1];

        /// <summary>Photoshop-like: 256-px saturation × brightness square + vertical hue strip on its right.</summary>
        sealed class SquareAndStrip
        {
            public PointD Origin = new PointD(600, 200);
            public double Side = 256, StripX = 880;
            public PointD SquarePoint(RGB c) { var h = ColorMath.Hsb(c); return new PointD(Origin.X + h[1] / 100 * Side, Origin.Y + (1 - h[2] / 100) * Side); }
            public PointD StripPoint(RGB c) => new PointD(StripX, Origin.Y + ColorMath.Hsb(c)[0] / 360 * Side);
            public RGB ColorAt(PointD sq, PointD st)
            {
                double s = (sq.X - Origin.X) / Side * 100, v = (1 - (sq.Y - Origin.Y) / Side) * 100, h = (st.Y - Origin.Y) / Side * 360;
                return ColorMath.RgbFromHsb(h, s, v);
            }
        }

        static List<RecordedInput> Click(PointD p, ref double t, int count = 1)
        {
            var e = new List<RecordedInput> { RecordedInput.Mouse(InputKind.MouseDown, p, t, clickCount: count), RecordedInput.Mouse(InputKind.MouseUp, p, t + 0.08, clickCount: count) };
            t += 0.6;
            return e;
        }

        static List<RecordedInput> Drag(PointD from, PointD to, ref double t)
        {
            var e = new List<RecordedInput> { RecordedInput.Mouse(InputKind.MouseDown, from, t) };
            for (int i = 1; i <= 10; i++)
            {
                double f = i / 10.0;
                e.Add(RecordedInput.Mouse(InputKind.MouseDragged, new PointD(from.X + (to.X - from.X) * f, from.Y + (to.Y - from.Y) * f), t + 0.02 * i));
            }
            e.Add(RecordedInput.Mouse(InputKind.MouseUp, to, t + 0.25));
            t += 0.8;
            return e;
        }

        static List<RecordedInput> Type(string s, ref double t)
        {
            var e = new List<RecordedInput>();
            foreach (var ch in s)
            {
                var k = VirtualKey.Stroke(ch);
                t += 0.1;
                e.Add(RecordedInput.Key(k.KeyCode, ch.ToString(), t, k.Modifiers));
            }
            return e;
        }

        static RecordedInput Key(ushort code, string chars, KeyModifiers mods, ref double t, string paste = null)
        {
            t += 0.15;
            return RecordedInput.Key(code, chars, t, mods, paste);
        }

        ColorPickerProfile Learn(List<ColorDemo> demos, HashSet<string> rejected = null)
        {
            var r = ColorLearner.Learn(demos, canvas, screens, "test", "Test", rejected);
            if (!r.Ok) Assert.Fail(r.Failure);
            return r.Profile;
        }

        /// <summary>Plays actions against a picker: the last click on the square / strip wins.</summary>
        static RGB Simulate(List<ReplayAction> actions, SquareAndStrip picker, RGB start)
        {
            var sq = picker.SquarePoint(start); var st = picker.StripPoint(start);
            var squareRect = new RectD(picker.Origin.X, picker.Origin.Y, picker.Side, picker.Side);
            Action<PointD> land = p =>
            {
                if (squareRect.Inset(-2, -2).Contains(p)) sq = new PointD(Math.Min(Math.Max(p.X, squareRect.MinX), squareRect.MaxX), Math.Min(Math.Max(p.Y, squareRect.MinY), squareRect.MaxY));
                else if (Math.Abs(p.X - picker.StripX) <= 10) st = new PointD(picker.StripX, Math.Min(Math.Max(p.Y, squareRect.MinY), squareRect.MaxY));
            };
            foreach (var x in actions)
            {
                if (x.Kind == ReplayKind.Click) land(x.At);
                else if (x.Kind == ReplayKind.Drag)
                {
                    // The control is chosen at mouse-down; the drag clamps inside it.
                    if (squareRect.Inset(-2, -2).Contains(x.At))
                        sq = new PointD(Math.Min(Math.Max(x.To.X, squareRect.MinX), squareRect.MaxX), Math.Min(Math.Max(x.To.Y, squareRect.MinY), squareRect.MaxY));
                    else { land(x.At); land(x.To); }
                }
            }
            return picker.ColorAt(sq, st);
        }

        static void AssertClose(RGB x, RGB y, int tolerance = 4)
        {
            Assert.True(Math.Abs(x.R - y.R) <= tolerance && Math.Abs(x.G - y.G) <= tolerance && Math.Abs(x.B - y.B) <= tolerance, x.Hex + " vs " + y.Hex);
        }

        static string Typed(IEnumerable<ReplayAction> actions, Func<KeyStroke, bool> filter = null) =>
            string.Concat(actions.Where(x => x.Kind == ReplayKind.Key && (filter == null || filter(x.Stroke))).Select(x => x.Stroke.Characters));

        public void TestDemoColorsDifferInEveryParameter()
        {
            foreach (var p in ColorParams.All) Assert.True(Math.Abs(p.Value(a) - p.Value(b)) > 0.1 * p.Range(), p + " barely differs");
        }

        public void TestLearnsSquareAndHueStrip()
        {
            var picker = new SquareAndStrip();
            var swatch = new PointD(60, 120); var ok = new PointD(800, 520);
            Func<RGB, RGB?, double, ColorDemo> demo = (c, prev, jitter) =>
            {
                double t = 0;
                var e = Click(new PointD(swatch.X + jitter, swatch.Y), ref t);
                e.AddRange(Click(picker.StripPoint(c), ref t));
                e.AddRange(Click(picker.SquarePoint(c), ref t));
                e.AddRange(Click(new PointD(ok.X - jitter, ok.Y + jitter), ref t));
                return new ColorDemo(c, prev, e);
            };
            var profile = Learn(new List<ColorDemo> { demo(a, null, 0), demo(b, a, 3) });
            Assert.Equal(PickerColorSpace.Hsb, profile.Space.Value);
            Assert.False(profile.IsExact);
            Assert.Equal(4, profile.Steps.Count);
            foreach (var test in ColorLearner.TestColors.Concat(new[] { new RGB(0, 0, 0), new RGB(255, 0, 0), new RGB(128, 128, 128) }))
                AssertClose(Simulate(profile.Actions(test, b), picker, b), test);
        }

        public void TestLearnsSquareAndStripWithDragsAndCorrections()
        {
            var picker = new SquareAndStrip();
            Func<RGB, RGB?, PointD, ColorDemo> demo = (c, prev, dab) =>
            {
                double t = 0;
                var e = Click(new PointD(picker.SquarePoint(c).X - 5, picker.SquarePoint(c).Y + 2), ref t);
                e.AddRange(Click(picker.SquarePoint(c), ref t));
                e.AddRange(Drag(new PointD(picker.StripX, 260), picker.StripPoint(c), ref t));
                e.AddRange(Drag(dab, new PointD(dab.X + 30, dab.Y + 5), ref t));   // a test stroke on the canvas
                return new ColorDemo(c, prev, e);
            };
            var profile = Learn(new List<ColorDemo> { demo(a, null, new PointD(200, 500)), demo(b, a, new PointD(120, 420)) });
            Assert.Equal(2, profile.Steps.Count);
            foreach (var test in ColorLearner.TestColors) AssertClose(Simulate(profile.Actions(test, null), picker, b), test);
        }

        public void TestLearnsHexTyping()
        {
            var field = new PointD(1000, 150);
            Func<RGB, double, ColorDemo> demo = (c, dx) =>
            {
                double t = 0;
                var e = Click(new PointD(field.X + dx, field.Y), ref t);
                e.Add(Key(VirtualKey.A, "a", KeyModifiers.Control, ref t));
                e.AddRange(Type("#" + c.HexNoHash.ToLowerInvariant(), ref t));
                e.Add(Key(VirtualKey.Return, "\r", KeyModifiers.None, ref t));
                e.Add(RecordedInput.Key(VirtualKey.Return, "\r", t + 1, KeyModifiers.Control | KeyModifiers.Option | KeyModifiers.Shift));   // DrawBot's hotkey
                return new ColorDemo(c, null, e);
            };
            var profile = Learn(new List<ColorDemo> { demo(a, 0), demo(b, 20) });
            Assert.True(profile.IsExact);
            Assert.True(profile.Summary.Contains("hex"), profile.Summary);
            var actions = profile.Actions(new RGB(0x12, 0xAB, 0xEF), null);
            Assert.Equal("#12abef", Typed(actions, k => !k.IsShortcut && k.KeyCode != VirtualKey.Return));
            Assert.True(actions.Any(x => x.Kind == ReplayKind.Key && x.Stroke.KeyCode == VirtualKey.A && x.Stroke.Modifiers == KeyModifiers.Control));
            Assert.True(actions.Any(x => x.Kind == ReplayKind.Key && x.Stroke.KeyCode == VirtualKey.Return));
            Assert.Equal(1, actions.Count(x => x.Kind == ReplayKind.Click));
        }

        public void TestLearnsRGBFieldsWithTabsAndABackspacedTypo()
        {
            Func<RGB, ColorDemo> demo = c =>
            {
                double t = 0;
                var e = Click(new PointD(900, 400), ref t, 2);
                e.AddRange(Type(c.R.ToString(), ref t));
                e.Add(Key(VirtualKey.Tab, "\t", KeyModifiers.None, ref t));
                e.AddRange(Type(c.G + "9", ref t));
                e.Add(Key(VirtualKey.Delete, "\b", KeyModifiers.None, ref t));
                e.Add(Key(VirtualKey.Tab, "\t", KeyModifiers.None, ref t));
                e.AddRange(Type(c.B.ToString(), ref t));
                e.Add(Key(VirtualKey.Return, "\r", KeyModifiers.None, ref t));
                return new ColorDemo(c, null, e);
            };
            var profile = Learn(new List<ColorDemo> { demo(a), demo(b) });
            Assert.True(profile.IsExact);
            Assert.Equal("7\t200\t99\r", Typed(profile.Actions(new RGB(7, 200, 99), null)));
        }

        public void TestLearnsPasteAsTyping()
        {
            Func<RGB, ColorDemo> demo = c =>
            {
                double t = 0;
                var e = Click(new PointD(1000, 150), ref t, 3);
                e.Add(Key(VirtualKey.V, "v", KeyModifiers.Control, ref t, c.HexNoHash));
                e.Add(Key(VirtualKey.Return, "\r", KeyModifiers.None, ref t));
                return new ColorDemo(c, null, e);
            };
            var profile = Learn(new List<ColorDemo> { demo(a), demo(b) });
            var actions = profile.Actions(new RGB(1, 2, 3), null);
            Assert.False(actions.Any(x => x.Kind == ReplayKind.SetClipboard));
            Assert.Equal("010203\r", Typed(actions));
            Assert.True(actions.Contains(ReplayAction.Click(new PointD(1000, 150), PointerButton.Left, 3, KeyModifiers.None)));
            Assert.True(profile.IsExact);
        }

        public void TestLearnsRGBSliders()
        {
            Func<byte, int, PointD> pt = (v, row) => new PointD(1000 + v, 600 + row * 30);
            Func<RGB, ColorDemo> demo = c =>
            {
                double t = 0;
                var e = Click(pt(c.R, 0), ref t);
                e.AddRange(Click(pt(c.G, 1), ref t));
                e.AddRange(Click(pt(c.B, 2), ref t));
                return new ColorDemo(c, null, e);
            };
            var profile = Learn(new List<ColorDemo> { demo(a), demo(b) });
            Assert.Equal(PickerColorSpace.Rgb, profile.Space.Value);
            var ends = profile.Actions(new RGB(10, 128, 250), null).Where(x => x.Kind == ReplayKind.Drag).Select(x => x.To).ToList();
            Assert.Equal(3, ends.Count);
            Assert.Near(1010, ends[0].X, 0.5);
            Assert.Near(1128, ends[1].X, 0.5);
            Assert.Near(1250, ends[2].X, 0.5);
        }

        public void TestWheelIsLearnedOnceAThirdDemoRulesOutTheSquare()
        {
            var center = new PointD(1100, 300);
            Func<RGB, PointD> wheel = c =>
            {
                var h = ColorMath.Hsb(c);
                double ang = h[0] * Math.PI / 180;
                return new PointD(center.X + 100 * h[1] / 100 * Math.Cos(ang), center.Y - 100 * h[1] / 100 * Math.Sin(ang));
            };
            Func<RGB, PointD> slider = c => new PointD(1000 + 200 * ColorMath.Hsb(c)[2] / 100, 450);
            Func<RGB, ColorDemo> demo = c =>
            {
                double t = 0;
                var e = Click(wheel(c), ref t);
                e.AddRange(Click(slider(c), ref t));
                return new ColorDemo(c, null, e);
            };
            var demos = new List<ColorDemo> { demo(a), demo(b) };
            var rejected = new HashSet<string>();
            var profile = Learn(demos);
            foreach (var test in ColorLearner.TestColors.Take(3))
            {
                var first = profile.Actions(test, null).Where(x => x.Kind == ReplayKind.Drag).Select(x => x.To).ToList();
                if (first.Count > 0 && PointD.Distance(first[0], wheel(test)) < 2) break;
                rejected.Add(profile.HypothesisKey);
                demos.Add(demo(test));
                profile = Learn(demos, rejected);
            }
            Assert.LessOrEqual(demos.Count, 4);
            var t2 = ColorMath.RgbFromHsb(250, 40, 50);
            var ends = profile.Actions(t2, null).Where(x => x.Kind == ReplayKind.Drag).Select(x => x.To).ToList();
            Assert.Equal(2, ends.Count);
            Assert.Near(wheel(t2).X, ends[0].X, 1.5);
            Assert.Near(wheel(t2).Y, ends[0].Y, 1.5);
            Assert.Near(slider(t2).X, ends[1].X, 1.5);
        }

        public void TestNothingChangedFails()
        {
            double t = 0;
            var same = Click(new PointD(900, 100), ref t);
            var r = ColorLearner.Learn(new List<ColorDemo> { new ColorDemo(a, null, same), new ColorDemo(b, null, same) }, canvas, screens, "k", "K");
            Assert.False(r.Ok);
            Assert.True(r.Failure.Contains("Nothing changed"), r.Failure);
        }

        public void TestCanvasOnlyDemoFails()
        {
            double t = 0;
            var inCanvas = Click(new PointD(100, 400), ref t);
            Assert.False(ColorLearner.Learn(new List<ColorDemo> { new ColorDemo(a, null, inCanvas), new ColorDemo(b, null, inCanvas) }, canvas, screens, "k", "K").Ok);
        }

        public void TestPickerLeftOpenOverTheCanvasIsReported()
        {
            // A popup picker over the canvas: opened by a toolbar button, but never closed again.
            var picker = new SquareAndStrip { Origin = new PointD(100, 350), StripX = 380 };
            Func<RGB, ColorDemo> demo = c =>
            {
                double t = 0;
                var e = Click(new PointD(600, 100), ref t);
                e.AddRange(Click(picker.StripPoint(c), ref t));
                e.AddRange(Click(picker.SquarePoint(c), ref t));
                return new ColorDemo(c, null, e);
            };
            var r = ColorLearner.Learn(new List<ColorDemo> { demo(a), demo(b) }, canvas, screens, "k", "K");
            Assert.False(r.Ok);
            Assert.True(r.Failure.Contains("still open"), r.Failure);
        }

        public void TestProfileJsonRoundTrip()
        {
            var picker = new SquareAndStrip();
            Func<RGB, ColorDemo> demo = c =>
            {
                double t = 0;
                var e = Click(picker.SquarePoint(c), ref t);
                e.AddRange(Click(picker.StripPoint(c), ref t));
                return new ColorDemo(c, null, e);
            };
            var profile = Learn(new List<ColorDemo> { demo(a), demo(b) });
            var back = LearnJson.Profile(Json.Parse(Json.Write(LearnJson.Profile(profile))));
            Assert.Equal(profile.HypothesisKey, back.HypothesisKey);
            Assert.Equal(profile.Summary, back.Summary);
            foreach (var test in ColorLearner.TestColors) Assert.Seq(profile.Actions(test, a), back.Actions(test, a));
            var typed = new ColorPickerProfile { AppKey = "x", Steps = new List<PickerStep> { PickerStep.Of(new TypingStep { Pieces = new List<TypingPiece> {
                TypingPiece.KeyPiece(new KeyStroke(VirtualKey.A, "a", KeyModifiers.Control)),
                TypingPiece.TextPiece(new TextTemplate(new[] { TextPart.Lit("#"), TextPart.Of(ValueSlot.Hex(false)) })) } }) },
                Swatches = new List<PaletteSwatch> { new PaletteSwatch(new PointD(1, 2), new RGB(3, 4, 5), 2) } };
            var tb = LearnJson.Profile(Json.Parse(Json.Write(LearnJson.Profile(typed))));
            Assert.Equal(new RGB(3, 4, 5), tb.Swatches[0].Color);
            typed.Swatches = null; tb.Swatches = null;
            Assert.Seq(typed.Actions(new RGB(1, 2, 3), null), tb.Actions(new RGB(1, 2, 3), null));
        }

        public void TestCandidatesAndTemplates()
        {
            var c = new RGB(230, 138, 46);
            Assert.True(ColorLearner.Candidates("e68a2e", c).Contains(ValueSlot.Hex(false)));
            Assert.True(ColorLearner.Candidates("230", c).Contains(ValueSlot.Number(ColorParam.Red, 255, 0)));
            Assert.True(ColorLearner.Candidates("0.90", c).Contains(ValueSlot.Number(ColorParam.HsbBrightness, 1, 2)));
            List<string> bad;
            var t = ColorLearner.BuildTemplate(new List<string> { "rgb(230, 138, 46)", "rgb(75, 95, 115)" }, new List<RGB> { c, ColorLearner.DemoColors[1] }, out bad);
            Assert.Equal(0, bad.Count);
            Assert.Equal("rgb(1, 2, 3)", t.Format(new RGB(1, 2, 3)));
        }
    }
}
