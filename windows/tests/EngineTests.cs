using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using DrawBot.Core;
using DrawBot.Win;

namespace DrawBot.Tests
{
    /// <summary>
    /// A simulated input system: records events instead of posting them, and answers cursor reads
    /// from the recorded events (optionally lagging, rounding, or offset by a simulated user).
    /// </summary>
    sealed class FakeWorld : IMouseEventSink
    {
        readonly object l = new object();
        readonly List<SyntheticMouseEvent> events = new List<SyntheticMouseEvent>();
        int readsSincePost;
        double time = 1000, lastPostTime;
        public readonly PointD InitialCursor;
        public PointD UserOffset;
        public int Lag, LagReads = 1;
        public PointD UserVelocity;
        public int UserVelocityFrom = int.MaxValue;
        public double IgnoreEventsUntil;
        public double? Rounding;
        public bool IgnoreEvents, Trusted = true, EscapeDown;
        public Action<int, SyntheticMouseEvent> OnPost;

        public FakeWorld(PointD? cursor = null) { InitialCursor = cursor ?? new PointD(700, 700); }

        public List<SyntheticMouseEvent> Events { get { lock (l) return events.ToList(); } }

        public bool Post(SyntheticMouseEvent e)
        {
            Action<int, SyntheticMouseEvent> hook;
            int index;
            lock (l)
            {
                events.Add(e);
                index = events.Count - 1;
                readsSincePost = 0;
                lastPostTime = time;
                UserOffset = PointD.Zero;   // our absolute-position event puts the cursor back
                hook = OnPost;
            }
            hook?.Invoke(index, e);
            return true;
        }

        public PointD? CursorLocation()
        {
            lock (l)
            {
                PointD p;
                if (IgnoreEvents || events.Count == 0 || time < IgnoreEventsUntil) p = InitialCursor;
                else if (Lag > 0 && readsSincePost < LagReads) { int i = events.Count - 1 - Lag; p = i >= 0 ? events[i].Point : InitialCursor; }
                else p = events[events.Count - 1].Point;
                readsSincePost++;
                p.X += UserOffset.X; p.Y += UserOffset.Y;
                if (events.Count >= UserVelocityFrom) { p.X += UserVelocity.X * (time - lastPostTime); p.Y += UserVelocity.Y * (time - lastPostTime); }
                if (Rounding.HasValue) { p.X = Num.Round(p.X / Rounding.Value) * Rounding.Value; p.Y = Num.Round(p.Y / Rounding.Value) * Rounding.Value; }
                return p;
            }
        }

        public void SetUserOffset(PointD v) { lock (l) UserOffset = v; }
        public void SetTrusted(bool v) { lock (l) Trusted = v; }
        public void SetEscape(bool v) { lock (l) EscapeDown = v; }

        public DrawingEnvironment Environment => new DrawingEnvironment
        {
            MakeSink = () => this,
            IsTrusted = () => { lock (l) return Trusted; },
            IsEscapeDown = () => { lock (l) return EscapeDown; },
            Sleep = s => { lock (l) time += Math.Max(0, s); },
            Now = () => { lock (l) return time; },
            Deliver = a => a(),
        };
    }

    public sealed class DrawingEngineTests
    {
        static readonly SpeedSettings TestSpeed = new SpeedSettings(4, 0.001, 0.002, 0.002, 0.002);
        static readonly RectD BigRect = new RectD(0, 0, 1000, 1000);
        const SyntheticMouseEventKind M = SyntheticMouseEventKind.Moved, D = SyntheticMouseEventKind.Down, G = SyntheticMouseEventKind.Dragged, U = SyntheticMouseEventKind.Up;

        sealed class RunResult { public DrawingEngine.Outcome Outcome; public List<DrawingEngine.Progress> Progress; public List<SyntheticMouseEvent> Events; }

        static RunResult Run(FakeWorld world, IList<ScreenStroke> strokes, int startingAt = 0, RectD? clampRect = null, SpeedSettings speed = null,
                             Action<DrawingEngine> configure = null)
        {
            var engine = new DrawingEngine(speed ?? TestSpeed, world.Environment);
            configure?.Invoke(engine);
            var progress = new List<DrawingEngine.Progress>();
            var outcomes = new List<DrawingEngine.Outcome>();
            var done = new ManualResetEventSlim();
            engine.Draw(strokes, startingAt, clampRect ?? BigRect, p =>
            {
                lock (outcomes) { Assert.Equal(0, outcomes.Count, "progress after completion"); progress.Add(p); }
            }, o =>
            {
                Assert.False(engine.IsRunning, "IsRunning must be false when the completion runs");
                lock (outcomes) outcomes.Add(o);
                done.Set();
            });
            if (!done.IsSet) Assert.True(engine.IsRunning, "IsRunning must be set synchronously");
            Assert.True(done.Wait(10000), "no completion");
            Thread.Sleep(30);
            Assert.Equal(1, outcomes.Count, "completion must be called exactly once");
            return new RunResult { Outcome = outcomes[0], Progress = progress, Events = world.Events };
        }

        static void AssertWellFormed(List<SyntheticMouseEvent> events, RectD? rect = null)
        {
            var r = rect ?? BigRect;
            bool down = false;
            for (int i = 0; i < events.Count; i++)
            {
                var e = events[i];
                Assert.True(e.Point.X >= r.MinX && e.Point.X <= r.MaxX && e.Point.Y >= r.MinY && e.Point.Y <= r.MaxY, "event " + i + " " + e.Point + " outside clamp rect");
                switch (e.Kind)
                {
                    case M: Assert.False(down, "move while button down at " + i); break;
                    case G: Assert.True(down, "drag while button up at " + i); break;
                    case D: Assert.False(down, "double down at " + i); down = true; break;
                    case U: Assert.True(down, "up without down at " + i); down = false; break;
                }
            }
            Assert.False(down, "button left down");
        }

        static ScreenStroke S(double x0, double y0, double x1, double y1, params PointD[] via) => new ScreenStroke(new PointD(x0, y0), new PointD(x1, y1), via);

        public void TestStrokeSequence()
        {
            var r = Run(new FakeWorld(), new[] { S(10, 10, 30, 10) });
            Assert.Equal(DrawingEngine.OutcomeKind.Completed, r.Outcome.Kind);
            Assert.Seq(new[] { M, D, G, G, G, G, G, U }, r.Events.Select(e => e.Kind));
            Assert.Seq(new double[] { 10, 10, 14, 18, 22, 26, 30, 30 }, r.Events.Select(e => e.Point.X));
            Assert.Equal(4L, r.Events[2].DeltaX);
            Assert.Equal(10L - 700, r.Events[0].DeltaX);
            AssertWellFormed(r.Events);
        }

        public void TestPathStrokeGoesThroughEveryCorner()
        {
            var r = Run(new FakeWorld(), new[] { S(10, 10, 10, 14, new PointD(18, 10), new PointD(18, 14)) });
            Assert.Seq(new[] { M, D, G, G, G, G, G, U }, r.Events.Select(e => e.Kind));
            Assert.Seq(new[] { new PointD(10, 10), new PointD(10, 10), new PointD(14, 10), new PointD(18, 10), new PointD(18, 14), new PointD(14, 14), new PointD(10, 14), new PointD(10, 14) },
                r.Events.Select(e => e.Point));
        }

        public void TestDiagonalStrokeSpacingAndExactEnd()
        {
            var a = new PointD(100.25, 200.5); var b = new PointD(137.75, 171.0);
            var r = Run(new FakeWorld(), new[] { new ScreenStroke(a, b) });
            var drags = r.Events.Where(e => e.Kind == G).Select(e => e.Point).ToList();
            var prev = a;
            foreach (var p in drags) { Assert.LessOrEqual(PointD.Distance(p, prev), 4 + 1e-9); prev = p; }
            Assert.Equal(b, drags.Last());
            Assert.Equal(U, r.Events.Last().Kind);
            Assert.Equal(b, r.Events.Last().Point);
        }

        public void TestDotWigglesOnePixel()
        {
            var p = new PointD(50, 60);
            var r = Run(new FakeWorld(), new[] { new ScreenStroke(p, p) });
            Assert.Seq(new[] { M, D, G, G, U }, r.Events.Select(e => e.Kind));
            Assert.Seq(new[] { p, p, new PointD(51, 60), p, p }, r.Events.Select(e => e.Point));
            var edge = new RectD(0, 0, 100, 100);
            var q = new PointD(100, 50);
            var r2 = Run(new FakeWorld(), new[] { new ScreenStroke(q, q) }, clampRect: edge);
            Assert.Seq(new[] { q, q, new PointD(99, 50), q, q }, r2.Events.Select(e => e.Point));
        }

        public void TestClamping()
        {
            var rect = new RectD(10, 20, 100, 50);
            var r = Run(new FakeWorld(), new[] { S(-50, 40, 500, 40), S(60, -10, 60, 900), S(9999, 9999, 9999, 9999) }, clampRect: rect);
            Assert.Equal(DrawingEngine.OutcomeKind.Completed, r.Outcome.Kind);
            AssertWellFormed(r.Events, rect);
            Assert.Equal(new PointD(10, 40), r.Events[0].Point);
            Assert.True(r.Events.Any(e => e.Kind == U && e.Point == new PointD(110, 40)));
            Assert.True(r.Events.Any(e => e.Kind == U && e.Point == new PointD(60, 70)));
            Assert.Equal(new PointD(110, 70), r.Events.Last().Point);
        }

        public void TestResumeStartsAtIndex()
        {
            var strokes = Enumerable.Range(0, 5).Select(i => S(10, 10 + 4 * i, 40, 10 + 4 * i)).ToList();
            var r = Run(new FakeWorld(), strokes, 3);
            Assert.Equal(strokes[3].Start, r.Events[0].Point);
            Assert.Equal(2, r.Events.Count(e => e.Kind == D));
            Assert.Equal(3, r.Progress.First().StrokesDone);
            Assert.Equal(5, r.Progress.Last().StrokesDone);
            var empty = Run(new FakeWorld(), new[] { S(1, 1, 5, 1) }, 7);
            Assert.Equal(0, empty.Events.Count);
        }

        public void TestRequestStopReleasesButton()
        {
            var world = new FakeWorld();
            DrawingEngine engine = null;
            world.OnPost = (i, _) => { if (i == 4) engine.RequestStop("User stop"); };
            var r = Run(world, new[] { S(10, 10, 90, 10), S(10, 20, 90, 20) }, configure: e => engine = e);
            Assert.Equal(DrawingEngine.Outcome.Stopped("User stop"), r.Outcome);
            AssertWellFormed(r.Events);
            Assert.Equal(6, r.Events.Count);
            Assert.Equal(r.Events[4].Point, r.Events.Last().Point);
            Assert.Equal(0, r.Progress.Last().StrokesDone);
        }

        public void TestStopWinsOverPause()
        {
            var world = new FakeWorld();
            DrawingEngine engine = null;
            world.OnPost = (i, _) => { if (i == 3) { engine.RequestStop("S"); engine.RequestPause("P"); } };
            var r = Run(world, new[] { S(10, 10, 90, 10) }, configure: e => engine = e);
            Assert.Equal(DrawingEngine.Outcome.Stopped("S"), r.Outcome);
        }

        public void TestRequestPauseGivesCurrentStroke()
        {
            var world = new FakeWorld();
            DrawingEngine engine = null;
            world.OnPost = (i, _) => { if (i == 25) engine.RequestPause(); };
            var r = Run(world, Enumerable.Range(0, 4).Select(i => S(10, 10 + 4 * i, 40, 10 + 4 * i)).ToList(), configure: e => engine = e);
            Assert.Equal(DrawingEngine.Outcome.Paused(2, "Paused"), r.Outcome);
            AssertWellFormed(r.Events);
        }

        public void TestEscapeStops()
        {
            var world = new FakeWorld();
            world.OnPost = (i, _) => { if (i == 3) world.SetEscape(true); };
            var r = Run(world, new[] { S(10, 10, 90, 10) });
            Assert.Equal(DrawingEngine.Outcome.Stopped(DrawingEngine.Reason.Escape), r.Outcome);
            Assert.Equal(5, r.Events.Count);
            AssertWellFormed(r.Events);
        }

        public void TestInvalidClampRect()
        {
            var r = Run(new FakeWorld(), new[] { S(1, 1, 2, 1) }, clampRect: RectD.Null);
            Assert.Equal(DrawingEngine.Outcome.Stopped(DrawingEngine.Reason.InvalidCanvas), r.Outcome);
            Assert.Equal(0, r.Events.Count);
        }

        public void TestPauseOnUserMovement()
        {
            var world = new FakeWorld();
            world.OnPost = (i, _) => { if (i == 16) world.SetUserOffset(new PointD(0, 40)); };
            var r = Run(world, Enumerable.Range(0, 3).Select(i => S(100, 100 + 4 * i, 140, 100 + 4 * i)).ToList());
            Assert.Equal(DrawingEngine.Outcome.Paused(1, DrawingEngine.Reason.MouseMoved), r.Outcome);
            AssertWellFormed(r.Events);
            Assert.Equal(19, r.Events.Count);
            Assert.Equal(new PointD(r.Events[16].Point.X, r.Events[16].Point.Y + 40), r.Events.Last().Point);
        }

        public void TestRepeatedSmallNudgesPauseButOneDoesNot()
        {
            var world = new FakeWorld();
            world.OnPost = (i, _) => { if (i >= 10 && i <= 12) world.SetUserOffset(new PointD(0, 6)); };
            Assert.Equal(DrawingEngine.OutcomeKind.Paused, Run(world, new[] { S(100, 100, 300, 100) }).Outcome.Kind);
            var once = new FakeWorld();
            once.OnPost = (i, _) => { if (i == 10) once.SetUserOffset(new PointD(0, 6)); };
            Assert.Equal(DrawingEngine.OutcomeKind.Completed, Run(once, new[] { S(100, 100, 300, 100) }).Outcome.Kind);
        }

        public void TestPauseDisabledIgnoresMovement()
        {
            var world = new FakeWorld();
            world.OnPost = (i, _) => { if (i == 5) world.SetUserOffset(new PointD(0, 50)); };
            Assert.Equal(DrawingEngine.OutcomeKind.Completed, Run(world, new[] { S(100, 100, 200, 100) }, configure: e => e.PauseOnUserMouseMove = false).Outcome.Kind);
        }

        static List<ScreenStroke> ManyStrokes()
        {
            var s = new List<ScreenStroke>();
            for (int row = 0; row < 40; row++)
            {
                double y = 50 + row * 4.0, x0 = 30.0 + (row * 37) % 50, x1 = 600.0 - (row * 53) % 200;
                s.Add(row % 2 == 0 ? S(x0, y, x1, y) : S(x1, y, x0, y));
                if (row % 5 == 0) s.Add(S(900, 900 - y, 900, 900 - y));
            }
            return s;
        }

        public void TestNoFalsePauseFromOwnMotionWithLag()
        {
            foreach (var lag in new[] { 0, 1, 2, 3, 8, 20 })
            {
                var world = new FakeWorld { Lag = lag };
                var r = Run(world, ManyStrokes(), speed: SpeedSettings.Ludicrous);
                Assert.Equal(DrawingEngine.OutcomeKind.Completed, r.Outcome.Kind, "lag " + lag + ": " + r.Outcome);
                AssertWellFormed(r.Events);
            }
            foreach (var lag in new[] { 6, 8, 12 })
            {
                var world = new FakeWorld { Lag = lag, LagReads = 2 };
                Assert.Equal(DrawingEngine.OutcomeKind.Completed, Run(world, ManyStrokes(), speed: SpeedSettings.Normal).Outcome.Kind, "lag " + lag);
            }
            foreach (var rounding in new[] { 0.5, 1.0 })
                Assert.Equal(DrawingEngine.OutcomeKind.Completed, Run(new FakeWorld { Rounding = rounding, Lag = 1 }, ManyStrokes(), speed: SpeedSettings.Normal).Outcome.Kind);
        }

        public void TestDroppedEventsAreReported()
        {
            var r = Run(new FakeWorld(new PointD(900, 50)) { IgnoreEvents = true }, ManyStrokes());
            Assert.Equal(DrawingEngine.Outcome.Stopped(DrawingEngine.Reason.EventsIgnored), r.Outcome);
            AssertWellFormed(r.Events);
            var strokes = ManyStrokes();
            Assert.Equal(DrawingEngine.Outcome.Stopped(DrawingEngine.Reason.EventsIgnored), Run(new FakeWorld(strokes[0].Start) { IgnoreEvents = true }, strokes).Outcome);
            Assert.Equal(DrawingEngine.Outcome.Stopped(DrawingEngine.Reason.EventsIgnored),
                Run(new FakeWorld(new PointD(900, 50)) { IgnoreEvents = true }, ManyStrokes(), configure: e => e.PauseOnUserMouseMove = false).Outcome);
        }

        public void TestSlowStartIsNotReportedAsDroppedEvents()
        {
            foreach (var speed in new[] { SpeedSettings.Normal, SpeedSettings.Ludicrous })
                Assert.Equal(DrawingEngine.OutcomeKind.Completed, Run(new FakeWorld(new PointD(900, 50)) { IgnoreEventsUntil = 1000.1 }, ManyStrokes(), speed: speed).Outcome.Kind);
        }

        public void TestSteadyUserMotionPauses()
        {
            var world = new FakeWorld { UserVelocity = new PointD(0, 700), UserVelocityFrom = 20 };
            var r = Run(world, new[] { S(100, 100, 900, 100) }, speed: SpeedSettings.Normal);
            Assert.Equal(DrawingEngine.Outcome.Paused(0, DrawingEngine.Reason.MouseMoved), r.Outcome);
            Assert.Less(r.Events.Count, 40);
            var back = new FakeWorld { UserVelocity = new PointD(-600, 0), UserVelocityFrom = 30 };
            var r2 = Run(back, new[] { S(100, 100, 900, 100) }, speed: SpeedSettings.Normal);
            Assert.Equal(DrawingEngine.Outcome.Paused(0, DrawingEngine.Reason.MouseMoved), r2.Outcome);
            Assert.Less(r2.Events.Count, 60);
        }

        public void TestProgressThrottledAndFinal()
        {
            var strokes = ManyStrokes();
            var r = Run(new FakeWorld(), strokes, speed: new SpeedSettings(16, 0.0001, 0.0001, 0.0001, 0.0001));
            Assert.Equal(strokes.Count, r.Progress.Last().StrokesDone);
            Assert.Less(r.Progress.Count, strokes.Count / 2);
            var done = r.Progress.Select(p => p.StrokesDone).ToList();
            Assert.Seq(done.OrderBy(x => x), done);
        }
    }

    public sealed class MouseDriverTests
    {
        public void TestReleaseIfNeededAndDragWhileUp()
        {
            var world = new FakeWorld();
            var d = new MouseDriver(SpeedSettings.Normal, world);
            d.Drag(new PointD(5, 5));
            d.MouseDown(new PointD(10, 10));
            d.ReleaseIfNeeded();
            d.ReleaseIfNeeded();
            Assert.Seq(new[] { SyntheticMouseEventKind.Moved, SyntheticMouseEventKind.Moved, SyntheticMouseEventKind.Down, SyntheticMouseEventKind.Up }, world.Events.Select(e => e.Kind));
        }

        public void TestClampHandlesNonFinite()
        {
            var r = new RectD(0, 0, 10, 20);
            Assert.Equal(new PointD(5, 20), MouseDriver.Clamp(new PointD(double.NaN, 30), r));
            Assert.Equal(new PointD(3, 10), MouseDriver.Clamp(new PointD(3, double.NegativeInfinity), r));
            Assert.Equal(new PointD(10, 0), MouseDriver.Clamp(new PointD(50, -4), r));
        }

        public void TestAbsoluteCoordinatesLandOnTheRightPixel()
        {
            foreach (var size in new[] { 1, 2, 3, 1080, 1728, 1920, 2560, 3840, 7680, 5119 })
                for (int p = 0; p < size; p += Math.Max(1, size / 997))
                {
                    int n = ScreenSpace.Normalize(p, 0, size);
                    Assert.True(n >= 0 && n <= 65535, "out of range");
                    Assert.Equal(p, (int)((long)n * size / 65536), "size " + size);
                }
            Assert.Equal(ScreenSpace.Normalize(0, 0, 1920), ScreenSpace.Normalize(-1920 + 0, -1920, 1920));
        }
    }

    sealed class FakeReplaySink : IReplayEventSink
    {
        public readonly List<string> Log = new List<string>();
        public double Time;
        public PointD? Cursor;
        public bool Escape;
        public Func<PointD?> CursorOverride;
        public void PostMouse(ReplayMouse type, PointD p, PointerButton button, int clickState, KeyModifiers modifiers) { Log.Add(type + "@" + p.X + "," + p.Y + (clickState > 1 ? "#" + clickState : "")); Cursor = p; }
        public void PostKey(KeyStroke stroke, bool down) => Log.Add((down ? "kd " : "ku ") + stroke.Characters);
        public void SetClipboard(string s) => Log.Add("clip " + s);
        public PointD? CursorLocation() => CursorOverride != null ? CursorOverride() : Cursor;
        public bool EscapePressed() => Escape;
        public bool IsTrusted() => true;
        public void Sleep(double seconds) => Time += seconds;
    }

    public sealed class InputReplayerTests
    {
        static InputReplayer.Outcome Play(FakeReplaySink sink, IList<ReplayAction> actions, bool detectMove = true) =>
            new ReplayWorker(sink, detectMove, 1, () => null) { Clock = () => sink.Time }.Run(actions);

        public void TestClickAndDoubleClick()
        {
            var sink = new FakeReplaySink();
            var o = Play(sink, new[] { ReplayAction.Click(new PointD(10, 20), PointerButton.Left, 2, KeyModifiers.None) });
            Assert.Equal(InputReplayer.OutcomeKind.Completed, o.Kind);
            Assert.Seq(new[] { "Move@10,20", "LeftDown@10,20", "LeftUp@10,20", "LeftDown@10,20#2", "LeftUp@10,20#2" }, sink.Log);
        }

        public void TestDragEndsOnTargetWithFineSteps()
        {
            var sink = new FakeReplaySink();
            Play(sink, new[] { ReplayAction.Drag(new PointD(0, 0), new PointD(30, 0), PointerButton.Left, KeyModifiers.None) });
            Assert.Equal("Move@0,0", sink.Log[0]);
            Assert.Equal("LeftDown@0,0", sink.Log[1]);
            Assert.Equal("LeftUp@30,0", sink.Log.Last());
            Assert.Seq(new double[] { 3, 6, 9, 12, 15, 18, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30 }, ReplayWorker.DragDistances(30));
        }

        public void TestTypingAndWaits()
        {
            var sink = new FakeReplaySink();
            Play(sink, new[] { ReplayAction.Key(VirtualKey.Stroke('a')), ReplayAction.Wait(0.5) });
            Assert.Seq(new[] { "kd a", "ku a" }, sink.Log);
            Assert.Near(0.012 + 0.03 + 0.5, sink.Time, 1e-6);
        }

        public void TestEscapeStopsAndReleases()
        {
            var sink = new FakeReplaySink();
            var actions = new List<ReplayAction> { ReplayAction.Drag(new PointD(0, 0), new PointD(300, 0), PointerButton.Left, KeyModifiers.None), ReplayAction.Wait(1),
                ReplayAction.Click(new PointD(5, 5), PointerButton.Left, 1, KeyModifiers.None) };
            var worker = new ReplayWorker(sink, true, 1, () => sink.Time > 0.5 ? "Escape pressed" : null) { Clock = () => sink.Time };
            var o = worker.Run(actions);
            Assert.Equal(InputReplayer.OutcomeKind.Stopped, o.Kind);
            Assert.False(sink.Log.Any(s => s.StartsWith("LeftDown@5")));
        }

        public void TestUserMovementStops()
        {
            var sink = new FakeReplaySink { CursorOverride = () => new PointD(500, 500) };
            var o = Play(sink, new[] { ReplayAction.Click(new PointD(10, 10), PointerButton.Left, 1, KeyModifiers.None), ReplayAction.Click(new PointD(20, 20), PointerButton.Left, 1, KeyModifiers.None) });
            Assert.Equal(InputReplayer.Outcome.Stopped(DrawingEngine.Reason.MouseMoved).Reason, o.Reason);
        }

        public void TestEstimatedDurationAddsPauses()
        {
            var actions = new[] { ReplayAction.Wait(0.3), ReplayAction.Click(new PointD(0, 0), PointerButton.Left, 1, KeyModifiers.None) };
            Assert.Near(0.3 + 0.04 + 0.025 + 0.03, InputReplayer.EstimatedDuration(actions), 1e-6);
            Assert.Near((0.3 + 0.04 + 0.025 + 0.03) * 0.5, InputReplayer.EstimatedDuration(actions, 0.5), 1e-6);
        }
    }

    public sealed class WindowInspectorTests
    {
        static OnScreenWindow W(int id, int pid, string owner, RectD r, int layer = 0, double alpha = 1, bool clickThrough = false, string cls = "x")
            => new OnScreenWindow { Handle = new IntPtr(id), Pid = pid, OwnerName = owner, Bounds = r, Layer = layer, Alpha = alpha, ClickThrough = clickThrough, ClassName = cls };

        public void TestFilterEligible()
        {
            var list = new List<OnScreenWindow>
            {
                W(1, 10, "A", new RectD(0, 0, 100, 100)), W(2, 10, "A", new RectD(0, 0, 100, 100), alpha: 0.01),
                W(3, 11, "B", new RectD(0, 0, 3, 100)), W(4, 12, "Shell", new RectD(0, 0, 2000, 2000), cls: "Progman"),
                W(5, 13, "HUD", new RectD(0, 0, 50, 50), clickThrough: true),
            };
            Assert.Seq(new[] { 1 }, WindowInspector.FilterEligible(list).Select(w => (int)w.Handle));
        }

        public void TestSamplePointsInsideCanvas()
        {
            var pts = WindowInspector.SamplePoints(new RectD(100, 100, 200, 100));
            Assert.Equal(49, pts.Count);
            Assert.True(pts.All(p => p.X >= 102 && p.X <= 298 && p.Y >= 102 && p.Y <= 198));
        }

        public void TestObstructions()
        {
            var canvas = new RectD(100, 100, 400, 300);
            var windows = new List<OnScreenWindow>
            {
                W(1, 20, "Notes", new RectD(450, 350, 200, 200)),        // covers the bottom-right corner
                W(2, 10, "Paint", new RectD(0, 0, 1000, 800)),           // the target
                W(3, 30, "Other", new RectD(0, 0, 2000, 2000)),          // behind: irrelevant
            };
            var o = WindowInspector.Obstructions(windows, canvas, 10);
            Assert.Seq(new[] { 1 }, o.Select(w => (int)w.Handle));
            Assert.Equal(0, WindowInspector.Obstructions(windows.Skip(1).ToList(), canvas, 10).Count);
        }

        public void TestTargetFloatingPaletteOverCanvasIsAnObstruction()
        {
            var canvas = new RectD(100, 100, 400, 300);
            var windows = new List<OnScreenWindow> { W(1, 10, "Paint", new RectD(120, 120, 80, 80), layer: 3), W(2, 10, "Paint", new RectD(0, 0, 1000, 800)) };
            Assert.Seq(new[] { 1 }, WindowInspector.Obstructions(windows, canvas, 10).Select(w => (int)w.Handle));
            // A floating window that IS the canvas (nothing of the app's below it) is fine.
            var floating = new List<OnScreenWindow> { W(1, 10, "Paint", new RectD(0, 0, 1000, 800), layer: 3) };
            Assert.Equal(0, WindowInspector.Obstructions(floating, canvas, 10).Count);
        }

        public void TestTargetWindowPrefersNormalWindowsAndSkipsOwnPanels()
        {
            var canvas = new RectD(100, 100, 400, 300);
            var windows = new List<OnScreenWindow>
            {
                W(1, 99, "DrawBot", new RectD(0, 0, 1000, 1000), layer: 3),   // our own floating panel
                W(2, 20, "Tooltip", new RectD(250, 200, 100, 100), layer: 3),
                W(3, 10, "Paint", new RectD(0, 0, 1000, 800)),
            };
            Assert.Equal(3, (int)WindowInspector.TargetWindow(windows, canvas, 99).Handle);
            Assert.Equal(2, (int)WindowInspector.TargetWindow(windows.Take(2).ToList(), canvas, 99).Handle);
        }
    }

    public sealed class SiteDetectorTests
    {
        public void TestHostFromUrl()
        {
            Assert.Equal("paint.sumo.app", SiteDetector.HostFromUrl("https://www.paint.sumo.app/x?y"));
            Assert.Equal("paintz.app", SiteDetector.HostFromUrl("http://paintz.app"));
            Assert.True(SiteDetector.HostFromUrl("file:///C:/a.png") == null);
            Assert.True(SiteDetector.HostFromUrl("not a url") == null);
        }

        public void TestSiteNameFromTitle()
        {
            Assert.Equal("PaintZ", SiteDetector.SiteName("untitled.png - PaintZ - Google Chrome", "Google Chrome"));
            Assert.Equal("Sumo Paint", SiteDetector.SiteName("Sumo Paint — Mozilla Firefox", "Firefox"));
            Assert.Equal("Paint", SiteDetector.SiteName("Paint", "Microsoft Edge"));
        }
    }
}
