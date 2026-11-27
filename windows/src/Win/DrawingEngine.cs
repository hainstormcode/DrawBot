using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using DrawBot.Core;

namespace DrawBot.Win
{
    /// <summary>
    /// Plays strokes as synthetic press-drag-release gestures on a dedicated worker thread.
    ///
    /// Call Draw from the UI thread. Speed and the movement settings are snapshotted when Draw is
    /// called. RequestStop / RequestPause may be called from any thread. Progress callbacks
    /// (≤ 30 Hz) and the completion (exactly once) run on the thread that created the engine
    /// (its SynchronizationContext).
    ///
    /// User-movement detection: every posted event carries an absolute position, so all we ever
    /// see of the physical mouse is how far it moved the cursor since our LAST post. Before every
    /// event the real cursor is compared with the last few points WE posted. A clear deviation,
    /// repeated small ones, or steady slow movement trigger a confirmation: the cursor is re-read
    /// every 30 ms with nothing posted. Lag resolves to one of our recent points; only a cursor
    /// that is off all of them (or moving backwards along them) pauses the run, releasing the
    /// button where the user's cursor is. If the cursor never once reached a point we posted and
    /// stays where it was before the run, Windows is dropping our input: that stops the run.
    /// </summary>
    public sealed class DrawingEngine
    {
        public enum OutcomeKind { Completed, Stopped, Paused }

        public sealed class Outcome : IEquatable<Outcome>
        {
            public OutcomeKind Kind;
            public int ResumeIndex;
            public string Reason;
            public static Outcome Completed() => new Outcome { Kind = OutcomeKind.Completed };
            public static Outcome Stopped(string reason) => new Outcome { Kind = OutcomeKind.Stopped, Reason = reason };
            public static Outcome Paused(int resumeIndex, string reason) => new Outcome { Kind = OutcomeKind.Paused, ResumeIndex = resumeIndex, Reason = reason };
            public bool Equals(Outcome o) => o != null && Kind == o.Kind && ResumeIndex == o.ResumeIndex && Reason == o.Reason;
            public override bool Equals(object obj) => Equals(obj as Outcome);
            public override int GetHashCode() => (int)Kind;
            public override string ToString() => Kind + (Kind == OutcomeKind.Paused ? "(" + ResumeIndex + ", " + Reason + ")" : Kind == OutcomeKind.Stopped ? "(" + Reason + ")" : "");
        }

        public struct Progress
        {
            public int StrokesDone, StrokesTotal;
            public double Fraction => StrokesTotal == 0 ? 1 : (double)StrokesDone / StrokesTotal;
        }

        public static class Reason
        {
            public const string Escape = "Escape pressed";
            public const string MouseMoved = "Mouse moved";
            public const string InputBlocked = "Windows refused DrawBot's mouse input (the screen is locked, or an administrator prompt is open)";
            public const string EventsIgnored = "Windows ignored DrawBot's mouse events. If the drawing app runs as administrator, run DrawBot as administrator too.";
            public const string InvalidCanvas = "Invalid canvas rectangle";
            public const string PermissionMissing = "The Windows desktop is locked or disconnected, so DrawBot can't move the mouse. Unlock it (or reconnect to it), then try again";
            public const string PermissionLost = "The Windows desktop was locked or disconnected";
        }

        public SpeedSettings Speed;
        public bool PauseOnUserMouseMove = true;
        /// <summary>Distance in pixels between expected and actual cursor that counts as user movement.</summary>
        public double UserMoveThreshold = 12;
        public bool IsRunning { get; private set; }

        internal readonly DrawingEnvironment Environment;
        readonly object controlLock = new object();
        RunControl currentControl;

        public DrawingEngine(SpeedSettings speed) : this(speed, DrawingEnvironment.Live()) { }

        internal DrawingEngine(SpeedSettings speed, DrawingEnvironment environment)
        {
            Speed = speed;
            Environment = environment;
        }

        /// <summary>Draws strokes[startingAt...]. Every posted point is clamped into clampRect.</summary>
        public void Draw(IList<ScreenStroke> strokes, int startingAt, RectD clampRect, Action<Progress> progress, Action<Outcome> completion)
        {
            if (IsRunning) return;
            IsRunning = true;
            var control = new RunControl();
            lock (controlLock) currentControl = control;
            var config = new RunConfig
            {
                Strokes = strokes.ToArray(),
                StartIndex = Math.Min(Math.Max(0, startingAt), strokes.Count),
                ClampRect = clampRect,
                Speed = Sanitized(Speed),
                PauseOnUserMouseMove = PauseOnUserMouseMove,
                UserMoveThreshold = !double.IsNaN(UserMoveThreshold) && !double.IsInfinity(UserMoveThreshold) ? Math.Max(2, UserMoveThreshold) : 12,
            };
            var env = Environment;
            Action<Outcome> finish = outcome => env.Deliver(() =>
            {
                lock (controlLock) if (currentControl == control) currentControl = null;
                IsRunning = false;
                completion(outcome);
            });
            var thread = new Thread(() =>
            {
                using (env.HighResolution())
                {
                    var worker = new DrawingWorker(config, control, env, progress);
                    finish(worker.Run());
                }
            });
            thread.Name = "DrawBot.DrawingEngine";
            thread.IsBackground = true;
            thread.Priority = ThreadPriority.Highest;
            thread.Start();
        }

        public void RequestStop(string reason = "Stopped")
        {
            RunControl c; lock (controlLock) c = currentControl;
            c?.Request(RunControl.Req.Stop(reason));
        }

        public void RequestPause(string reason = "Paused")
        {
            RunControl c; lock (controlLock) c = currentControl;
            c?.Request(RunControl.Req.Pause(reason));
        }

        internal static SpeedSettings Sanitized(SpeedSettings s)
        {
            Func<double, double> delay = d => !double.IsNaN(d) && !double.IsInfinity(d) ? Math.Min(Math.Max(0, d), 1) : 0;
            double step = !double.IsNaN(s.StepSize) && !double.IsInfinity(s.StepSize) && s.StepSize > 0 ? Math.Max(0.5, s.StepSize) : 4;
            return new SpeedSettings(step, delay(s.EventDelay), delay(s.DownDelay), delay(s.UpDelay), delay(s.MoveDelay), delay(s.EndDelay));
        }
    }

    /// <summary>Environment seam: tests inject fakes so no real events are posted.</summary>
    internal sealed class DrawingEnvironment
    {
        public Func<IMouseEventSink> MakeSink;
        public Func<bool> IsTrusted;
        public Func<bool> IsEscapeDown;
        public Action<double> Sleep;
        public Func<double> Now;
        public Action<Action> Deliver;
        public Func<IDisposable> HighResolution = () => null;

        public static DrawingEnvironment Live()
        {
            var ctx = SynchronizationContext.Current;
            return new DrawingEnvironment
            {
                MakeSink = () => InputOverrides.Mouse != null ? InputOverrides.Mouse() : new SendInputSink(),
                IsTrusted = InputDesktop.IsAvailable,
                IsEscapeDown = () => (Native.GetAsyncKeyState(Native.VK_ESCAPE) & 0x8000) != 0,
                Sleep = PreciseClock.Sleep,
                Now = PreciseClock.Now,
                Deliver = ctx != null ? (Action<Action>)(a => ctx.Post(_ => a(), null)) : (a => a()),
                HighResolution = () => new PreciseClock.HighResolution(),
            };
        }
    }

    /// <summary>
    /// Whether this process can deliver input right now: Windows only accepts synthetic input on
    /// the interactive desktop, so a locked screen, a disconnected remote session or an
    /// administrator prompt (secure desktop) all make input go nowhere. The Windows counterpart
    /// of the macOS Accessibility check.
    /// </summary>
    public static class InputDesktop
    {
        public static bool IsAvailable()
        {
            if (InputOverrides.DesktopAvailable != null) return InputOverrides.DesktopAvailable();
            var d = Native.OpenInputDesktop(0, false, Native.DESKTOP_READOBJECTS);
            if (d == IntPtr.Zero) return false;
            Native.CloseDesktop(d);
            return true;
        }
    }

    /// <summary>Test seams: the virtual self test delivers input as window messages instead of SendInput.</summary>
    internal static class InputOverrides
    {
        public static Func<IMouseEventSink> Mouse;
        public static Func<IReplayEventSink> Replay;
        public static Func<bool> DesktopAvailable;
    }

    internal sealed class RunConfig
    {
        public ScreenStroke[] Strokes;
        public int StartIndex;
        public RectD ClampRect;
        public SpeedSettings Speed;
        public bool PauseOnUserMouseMove;
        public double UserMoveThreshold;
    }

    /// <summary>Stop/pause flags shared between the UI thread and the worker. Stop wins over pause.</summary>
    internal sealed class RunControl
    {
        public sealed class Req
        {
            public bool IsStop; public string Reason;
            public static Req Stop(string r) => new Req { IsStop = true, Reason = r };
            public static Req Pause(string r) => new Req { IsStop = false, Reason = r };
        }

        readonly object l = new object();
        Req pending;

        public void Request(Req r)
        {
            lock (l)
            {
                if (pending != null && pending.IsStop) return;   // a stop is final
                pending = r;
            }
        }

        public Req Current() { lock (l) return pending; }
    }

    internal sealed class Interrupt : Exception
    {
        public enum K { Stop, Pause, UserMoved, EventsIgnored, Refused }
        public K Kind; public string Reason; public PointD At;
        public Interrupt(K kind, string reason = null, PointD at = default(PointD)) { Kind = kind; Reason = reason; At = at; }
    }

    /// <summary>Runs on the worker thread only.</summary>
    internal sealed class DrawingWorker
    {
        readonly RunConfig config;
        readonly RunControl control;
        readonly DrawingEnvironment env;
        readonly Action<DrawingEngine.Progress> progressHandler;
        readonly MouseDriver driver;
        readonly IMouseEventSink sink;

        readonly List<PointD> history = new List<PointD>();
        const int HistoryLength = 32;
        const int RecentLength = 6;
        const double NoiseFloor = 1.5;
        const double AccumulationWindow = 0.3;
        const double ConfirmInterval = 0.03;
        const int ConfirmChecks = 4;
        const double EventsIgnoredAfter = 0.25;
        PointD? initialCursor;
        bool sawOwnEvent;
        readonly List<double> minorHits = new List<double>();
        readonly List<KeyValuePair<double, double>> excess = new List<KeyValuePair<double, double>>();
        double lastPermissionCheck;
        double lastProgress = double.NegativeInfinity;

        public DrawingWorker(RunConfig config, RunControl control, DrawingEnvironment env, Action<DrawingEngine.Progress> progress)
        {
            this.config = config; this.control = control; this.env = env; progressHandler = progress;
            sink = env.MakeSink();
            driver = new MouseDriver(config.Speed, sink);
        }

        public DrawingEngine.Outcome Run()
        {
            int total = config.Strokes.Length;
            int index = config.StartIndex;
            DrawingEngine.Outcome outcome;
            var rect = config.ClampRect.Standardized;
            if (rect.IsNull || !rect.IsFinite)
                outcome = DrawingEngine.Outcome.Stopped(DrawingEngine.Reason.InvalidCanvas);
            else if (!env.IsTrusted())
                outcome = DrawingEngine.Outcome.Stopped(DrawingEngine.Reason.PermissionMissing);
            else
            {
                driver.ClampRect = rect;
                lastPermissionCheck = env.Now();
                initialCursor = sink.CursorLocation();
                if (initialCursor.HasValue) history.Add(initialCursor.Value);
                Report(index, false);
                try
                {
                    while (index < total)
                    {
                        DrawStroke(config.Strokes[index]);
                        index++;
                        Report(index, false);
                    }
                    outcome = DrawingEngine.Outcome.Completed();
                }
                catch (Interrupt i)
                {
                    switch (i.Kind)
                    {
                        case Interrupt.K.Stop:
                            driver.ReleaseIfNeeded();
                            outcome = DrawingEngine.Outcome.Stopped(i.Reason);
                            break;
                        case Interrupt.K.Pause:
                            driver.ReleaseIfNeeded();
                            outcome = DrawingEngine.Outcome.Paused(index, i.Reason);
                            break;
                        case Interrupt.K.UserMoved:
                            // Release where the user's cursor is, so the app doesn't get a drag back.
                            if (driver.IsButtonDown) driver.MouseUp(i.At);
                            outcome = DrawingEngine.Outcome.Paused(index, DrawingEngine.Reason.MouseMoved);
                            break;
                        case Interrupt.K.Refused:
                            driver.ReleaseIfNeeded();
                            outcome = DrawingEngine.Outcome.Stopped(DrawingEngine.Reason.InputBlocked);
                            break;
                        default:
                            driver.ReleaseIfNeeded();
                            outcome = DrawingEngine.Outcome.Stopped(DrawingEngine.Reason.EventsIgnored);
                            break;
                    }
                }
                catch (Exception e)
                {
                    driver.ReleaseIfNeeded();
                    outcome = DrawingEngine.Outcome.Stopped(e.Message);
                }
            }
            driver.ReleaseIfNeeded();   // belt and braces: never leave the button down
            Report(index, true);
            return outcome;
        }

        void DrawStroke(ScreenStroke stroke)
        {
            var rect = config.ClampRect.Standardized;
            var path = stroke.Points.Select(p => MouseDriver.Clamp(p, rect)).ToArray();
            var a = path[0];
            var b = path[path.Length - 1];
            var s = config.Speed;

            Checkpoint();
            driver.Move(a);
            Posted();
            env.Sleep(s.MoveDelay);

            Checkpoint();
            driver.MouseDown(a);
            Posted();
            env.Sleep(s.DownDelay);

            if (stroke.IsDot || path.All(p => p == a))
            {
                // Many apps ignore a down/up with no motion: wiggle one pixel and come back (input
                // lands on whole pixels, so anything less might not move the cursor at all).
                var q = MouseDriver.Clamp(new PointD(a.X + 1, a.Y), rect);
                if (q == a) q = MouseDriver.Clamp(new PointD(a.X - 1, a.Y), rect);
                foreach (var p in new[] { q, a })
                {
                    Checkpoint();
                    driver.Drag(p);
                    Posted();
                    env.Sleep(s.EventDelay);
                }
            }
            else
            {
                for (int i = 1; i < path.Length; i++)
                {
                    PointD from = path[i - 1], to = path[i];
                    double length = PointD.Distance(from, to);
                    if (!(length > 0)) continue;
                    int n = Math.Max(1, (int)Math.Ceiling(length / s.StepSize));
                    for (int k = 1; k <= n; k++)
                    {
                        PointD p;
                        if (k == n) p = to;
                        else
                        {
                            double t = (double)k / n;
                            p = new PointD(from.X + (to.X - from.X) * t, from.Y + (to.Y - from.Y) * t);
                        }
                        Checkpoint();
                        driver.Drag(p);
                        Posted();
                        env.Sleep(s.EventDelay);
                    }
                    // Hold each corner for a frame, or a fast pen cuts the corner.
                    if (i < path.Length - 1) env.Sleep(s.EndDelay);
                }
            }

            env.Sleep(s.EndDelay);
            Checkpoint();
            driver.MouseUp(b);
            Posted();
            env.Sleep(s.UpDelay);
        }

        void Checkpoint()
        {
            var req = control.Current();
            if (req != null) throw new Interrupt(req.IsStop ? Interrupt.K.Stop : Interrupt.K.Pause, req.Reason);
            if (driver.Refused) throw new Interrupt(Interrupt.K.Refused);
            if (env.IsEscapeDown()) throw new Interrupt(Interrupt.K.Stop, DrawingEngine.Reason.Escape);
            double t = env.Now();
            if (t - lastPermissionCheck >= 2)
            {
                lastPermissionCheck = t;
                if (!env.IsTrusted()) throw new Interrupt(Interrupt.K.Stop, DrawingEngine.Reason.PermissionLost);
            }
            if (config.PauseOnUserMouseMove || !sawOwnEvent) CheckUserMovement(t);
        }

        void Posted()
        {
            if (!driver.LastPostedLocation.HasValue) return;
            history.Add(driver.LastPostedLocation.Value);
            if (history.Count > HistoryLength) history.RemoveRange(0, history.Count - HistoryLength);
        }

        void CheckUserMovement(double t)
        {
            if (!driver.LastPostedLocation.HasValue) return;
            var actualN = sink.CursorLocation();
            if (!actualN.HasValue) return;
            var actual = actualN.Value;
            NoteOwnEvent(actual);
            double deviation = DistanceToNearest(actual, history.Skip(Math.Max(0, history.Count - RecentLength)));
            double threshold = config.UserMoveThreshold;
            double minor = Math.Max(3, threshold / 3);
            if (deviation > threshold) { ConfirmUserMovement(); return; }
            if (deviation > minor)
            {
                minorHits.Add(t);
                minorHits.RemoveAll(x => t - x > 0.5);
                if (minorHits.Count >= 3) { ConfirmUserMovement(); return; }
            }
            if (deviation > NoiseFloor)
            {
                excess.Add(new KeyValuePair<double, double>(t, deviation));
                excess.RemoveAll(x => t - x.Key > AccumulationWindow);
                if (excess.Sum(x => x.Value) > threshold) ConfirmUserMovement();
            }
        }

        void NoteOwnEvent(PointD p)
        {
            if (sawOwnEvent || DistanceToNearest(p, history) > 1.5) return;
            if (initialCursor.HasValue && PointD.Distance(p, initialCursor.Value) <= 1.5) return;
            sawOwnEvent = true;
        }

        void ClearHits() { minorHits.Clear(); excess.Clear(); }

        void ConfirmUserMovement()
        {
            double waited = 0;
            int checks = 0;
            int lastMatch = -1;
            while (true)
            {
                env.Sleep(ConfirmInterval);
                waited += ConfirmInterval;
                checks++;
                var lastN = driver.LastPostedLocation;
                var againN = sink.CursorLocation();
                if (!lastN.HasValue || !againN.HasValue) return;
                var last = lastN.Value; var again = againN.Value;
                var prev = history.Count >= 2 ? history[history.Count - 2] : last;
                if (DistanceToSegment(again, prev, last) <= 2)
                {
                    NoteOwnEvent(again);
                    ClearHits();
                    return;   // just lag
                }
                if (!sawOwnEvent && initialCursor.HasValue && PointD.Distance(again, initialCursor.Value) <= 1)
                {
                    if (waited >= EventsIgnoredAfter - 1e-9) throw new Interrupt(Interrupt.K.EventsIgnored);
                    continue;
                }
                int i = LatestIndex(again, history, 2);
                if (i >= 0 && i >= lastMatch)
                {
                    lastMatch = i;
                    NoteOwnEvent(again);
                    if (checks >= ConfirmChecks) break;   // persistent lag, not the user
                    continue;
                }
                if (config.PauseOnUserMouseMove) throw new Interrupt(Interrupt.K.UserMoved, null, again);
                break;
            }
            ClearHits();
        }

        void Report(int done, bool force)
        {
            double t = env.Now();
            if (!force && t - lastProgress < 1.0 / 30.0) return;
            lastProgress = t;
            var p = new DrawingEngine.Progress { StrokesDone = done, StrokesTotal = config.Strokes.Length };
            var h = progressHandler;
            env.Deliver(() => h?.Invoke(p));
        }

        internal static double DistanceToSegment(PointD p, PointD a, PointD b)
        {
            double dx = b.X - a.X, dy = b.Y - a.Y;
            double len2 = dx * dx + dy * dy;
            if (!(len2 > 0)) return PointD.Distance(p, a);
            double t = Math.Min(1, Math.Max(0, ((p.X - a.X) * dx + (p.Y - a.Y) * dy) / len2));
            return PointD.Distance(p, new PointD(a.X + t * dx, a.Y + t * dy));
        }

        internal static double DistanceToNearest(PointD p, IEnumerable<PointD> pts)
        {
            double best = double.PositiveInfinity; bool any = false;
            foreach (var q in pts) { any = true; best = Math.Min(best, PointD.Distance(p, q)); }
            return any ? best : 0;
        }

        internal static int LatestIndex(PointD p, List<PointD> pts, double tolerance)
        {
            for (int i = pts.Count - 1; i >= 0; i--) if (PointD.Distance(p, pts[i]) <= tolerance) return i;
            return -1;
        }
    }
}
