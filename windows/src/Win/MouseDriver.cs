using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using DrawBot.Core;

namespace DrawBot.Win
{
    internal enum SyntheticMouseEventKind { Moved, Down, Dragged, Up }

    /// <summary>One synthetic event, as handed to an IMouseEventSink.</summary>
    internal struct SyntheticMouseEvent : IEquatable<SyntheticMouseEvent>
    {
        public SyntheticMouseEventKind Kind;
        /// <summary>Virtual-screen pixels (already clamped by the driver, if it has a clamp rect).</summary>
        public PointD Point;
        public long DeltaX, DeltaY;
        public bool Equals(SyntheticMouseEvent o) => Kind == o.Kind && Point == o.Point && DeltaX == o.DeltaX && DeltaY == o.DeltaY;
        public override bool Equals(object obj) => obj is SyntheticMouseEvent e && Equals(e);
        public override int GetHashCode() => (int)Kind ^ Point.GetHashCode();
        public override string ToString() => Kind + "@" + Point;
    }

    /// <summary>Where a MouseDriver's events go. The live implementation uses SendInput; tests record them.</summary>
    internal interface IMouseEventSink
    {
        /// <summary>False when Windows refused the event (secure desktop, locked session…).</summary>
        bool Post(SyntheticMouseEvent e);
        /// <summary>Current cursor position, or null if it can't be read right now.</summary>
        PointD? CursorLocation();
    }

    /// <summary>Converts virtual-screen pixels to SendInput's absolute 0…65535 coordinates.</summary>
    internal static class ScreenSpace
    {
        public static RectD VirtualScreen => new RectD(Native.GetSystemMetrics(Native.SM_XVIRTUALSCREEN), Native.GetSystemMetrics(Native.SM_YVIRTUALSCREEN),
            Native.GetSystemMetrics(Native.SM_CXVIRTUALSCREEN), Native.GetSystemMetrics(Native.SM_CYVIRTUALSCREEN));

        /// <summary>
        /// Windows maps an absolute coordinate n to pixel floor(n × size / 65536). The smallest n
        /// that lands on pixel p is ceil(p × 65536 / size), which also stays below the next pixel.
        /// </summary>
        public static int Normalize(int pixel, int origin, int size)
        {
            if (size <= 1) return 0;
            long p = Math.Min(Math.Max(pixel - origin, 0), size - 1);
            return (int)((p * 65536 + size - 1) / size);
        }

        public static void Absolute(PointD p, out int nx, out int ny)
        {
            int x = Native.GetSystemMetrics(Native.SM_XVIRTUALSCREEN), y = Native.GetSystemMetrics(Native.SM_YVIRTUALSCREEN);
            int w = Native.GetSystemMetrics(Native.SM_CXVIRTUALSCREEN), h = Native.GetSystemMetrics(Native.SM_CYVIRTUALSCREEN);
            nx = Normalize((int)Num.Round(p.X), x, w);
            ny = Normalize((int)Num.Round(p.Y), y, h);
        }

        public static PointD? Cursor()
        {
            Native.POINT pt;
            return Native.GetCursorPos(out pt) ? new PointD(pt.X, pt.Y) : (PointD?)null;
        }
    }

    /// <summary>Posts real mouse input with SendInput (absolute virtual-desktop coordinates).</summary>
    internal sealed class SendInputSink : IMouseEventSink
    {
        static readonly int InputSize = Marshal.SizeOf(typeof(Native.INPUT));

        public bool Post(SyntheticMouseEvent e)
        {
            int nx, ny;
            ScreenSpace.Absolute(e.Point, out nx, out ny);
            uint flags = Native.MOUSEEVENTF_MOVE | Native.MOUSEEVENTF_ABSOLUTE | Native.MOUSEEVENTF_VIRTUALDESK;
            if (e.Kind == SyntheticMouseEventKind.Down) flags |= Native.MOUSEEVENTF_LEFTDOWN;
            if (e.Kind == SyntheticMouseEventKind.Up) flags |= Native.MOUSEEVENTF_LEFTUP;
            var input = new Native.INPUT { type = Native.INPUT_MOUSE };
            input.u.mi = new Native.MOUSEINPUT { dx = nx, dy = ny, dwFlags = flags, dwExtraInfo = Native.DrawBotSignature };
            return Native.SendInput(1, new[] { input }, InputSize) == 1;
        }

        public PointD? CursorLocation() => ScreenSpace.Cursor();
    }

    /// <summary>Posts synthetic left-button mouse events. Not thread-safe; used from one worker thread.</summary>
    public sealed class MouseDriver
    {
        public SpeedSettings Speed;
        public bool IsButtonDown { get; private set; }
        /// <summary>The last point this driver posted an event at (after clamping), or null before the first event.</summary>
        public PointD? LastPostedLocation { get; private set; }
        /// <summary>When set, every posted point is clamped into this rect (max edges inclusive).</summary>
        public RectD? ClampRect;
        /// <summary>Set when Windows refused an event.</summary>
        public bool Refused { get; private set; }

        internal readonly IMouseEventSink Sink;

        public MouseDriver(SpeedSettings speed) : this(speed, new SendInputSink()) { }
        internal MouseDriver(SpeedSettings speed, IMouseEventSink sink) { Speed = speed; Sink = sink; }

        public PointD CurrentCursorLocation() => Sink.CursorLocation() ?? LastPostedLocation ?? PointD.Zero;

        /// <summary>Hover move (a drag if the button is down).</summary>
        public void Move(PointD p) => Post(IsButtonDown ? SyntheticMouseEventKind.Dragged : SyntheticMouseEventKind.Moved, p);

        public void MouseDown(PointD p)
        {
            if (IsButtonDown) MouseUp(LastPostedLocation ?? p);
            // A down at a new spot is preceded by a hover move so apps see the cursor arrive first.
            if (LastPostedLocation.HasValue && LastPostedLocation.Value != Constrain(p)) Post(SyntheticMouseEventKind.Moved, p);
            Post(SyntheticMouseEventKind.Down, p);
            IsButtonDown = true;
        }

        public void Drag(PointD p) => Move(p);

        /// <summary>Always posts a release (a redundant one is harmless; a missing one is not).</summary>
        public void MouseUp(PointD p)
        {
            if (IsButtonDown && LastPostedLocation.HasValue && LastPostedLocation.Value != Constrain(p)) Post(SyntheticMouseEventKind.Dragged, p);
            Post(SyntheticMouseEventKind.Up, p);
            IsButtonDown = false;
        }

        public void ReleaseIfNeeded()
        {
            if (!IsButtonDown) return;
            MouseUp(LastPostedLocation ?? CurrentCursorLocation());
        }

        PointD Constrain(PointD p)
        {
            if (!ClampRect.HasValue)
            {
                var fb = LastPostedLocation ?? PointD.Zero;
                return new PointD(IsFinite(p.X) ? p.X : fb.X, IsFinite(p.Y) ? p.Y : fb.Y);
            }
            return Clamp(p, ClampRect.Value);
        }

        static bool IsFinite(double v) => !double.IsNaN(v) && !double.IsInfinity(v);

        void Post(SyntheticMouseEventKind kind, PointD raw)
        {
            var p = Constrain(raw);
            long dx = 0, dy = 0;
            if (kind == SyntheticMouseEventKind.Moved || kind == SyntheticMouseEventKind.Dragged)
            {
                var prev = LastPostedLocation ?? Sink.CursorLocation() ?? p;
                dx = (long)(Num.Round(p.X) - Num.Round(prev.X));
                dy = (long)(Num.Round(p.Y) - Num.Round(prev.Y));
            }
            if (!Sink.Post(new SyntheticMouseEvent { Kind = kind, Point = p, DeltaX = dx, DeltaY = dy })) Refused = true;
            LastPostedLocation = p;
        }

        /// <summary>Clamps p into r (max edges inclusive). Non-finite coordinates map to the rect's center.</summary>
        public static PointD Clamp(PointD p, RectD r)
        {
            r = r.Standardized;
            if (r.IsNull || !r.IsFinite) return new PointD(IsFinite(p.X) ? p.X : 0, IsFinite(p.Y) ? p.Y : 0);
            double x = IsFinite(p.X) ? Math.Min(Math.Max(p.X, r.MinX), r.MaxX) : r.MidX;
            double y = IsFinite(p.Y) ? Math.Min(Math.Max(p.Y, r.MinY), r.MaxY) : r.MidY;
            return new PointD(x, y);
        }
    }

    /// <summary>Monotonic clock and precise sleeps (Windows timers are 1 ms at best, so the last stretch spins).</summary>
    public static class PreciseClock
    {
        static readonly double TickSeconds = 1.0 / Stopwatch.Frequency;

        public static double Now() => Stopwatch.GetTimestamp() * TickSeconds;

        public static void Sleep(double seconds)
        {
            if (!(seconds > 0) || double.IsInfinity(seconds)) return;
            long end = Stopwatch.GetTimestamp() + (long)(seconds * Stopwatch.Frequency);
            while (true)
            {
                long left = end - Stopwatch.GetTimestamp();
                if (left <= 0) return;
                double ms = left * TickSeconds * 1000;
                if (ms > 2.5) Thread.Sleep(1);
                else if (ms > 0.3) Thread.Sleep(0);
                else Thread.SpinWait(50);
            }
        }

        /// <summary>Raises the system timer resolution to 1 ms and keeps the display awake while held.</summary>
        public sealed class HighResolution : IDisposable
        {
            bool disposed;
            public HighResolution()
            {
                try { Native.timeBeginPeriod(1); } catch (Exception) { }
                try { Native.SetThreadExecutionState(Native.ES_CONTINUOUS | Native.ES_SYSTEM_REQUIRED | Native.ES_DISPLAY_REQUIRED); } catch (Exception) { }
            }
            public void Dispose()
            {
                if (disposed) return;
                disposed = true;
                try { Native.timeEndPeriod(1); } catch (Exception) { }
                try { Native.SetThreadExecutionState(Native.ES_CONTINUOUS); } catch (Exception) { }
            }
        }
    }
}
