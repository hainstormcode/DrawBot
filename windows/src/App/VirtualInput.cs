using System;
using DrawBot.Core;
using DrawBot.Win;

namespace DrawBot.App
{
    /// <summary>
    /// Mouse and key input delivered as window messages to the window under each point, instead of
    /// through SendInput. Used by the self test (--virtual) where there is no interactive desktop,
    /// e.g. a disconnected remote session: everything but the operating system's input queue runs
    /// for real. Only DrawBot's own windows are targeted.
    /// </summary>
    internal static class VirtualInput
    {
        const int MK_LBUTTON = 1, MK_RBUTTON = 2, WM_CHAR = 0x0102;
        static readonly object l = new object();
        static PointD cursor = new PointD(0, 0);
        static IntPtr capture, lastClicked;
        static bool left, right;

        public static PointD Cursor { get { lock (l) return cursor; } }

        public static void Install()
        {
            InputOverrides.Mouse = () => new MouseSink();
            InputOverrides.Replay = () => new ReplaySink();
            InputOverrides.DesktopAvailable = () => true;
        }

        public static void Mouse(int msg, PointD p)
        {
            IntPtr hwnd;
            lock (l)
            {
                bool down = msg == Native.WM_LBUTTONDOWN || msg == Native.WM_RBUTTONDOWN;
                hwnd = !down && capture != IntPtr.Zero ? capture : Native.WindowFromPoint(new Native.POINT((int)Num.Round(p.X), (int)Num.Round(p.Y)));
                if (msg == Native.WM_LBUTTONDOWN) left = true;
                if (msg == Native.WM_RBUTTONDOWN) right = true;
                if (msg == Native.WM_LBUTTONUP) left = false;
                if (msg == Native.WM_RBUTTONUP) right = false;
                if (down) { capture = hwnd; lastClicked = hwnd; }
                if (!left && !right) capture = IntPtr.Zero;
                cursor = p;
            }
            if (hwnd == IntPtr.Zero) return;
            var pt = new Native.POINT((int)Num.Round(p.X), (int)Num.Round(p.Y));
            Native.ScreenToClient(hwnd, ref pt);
            int wParam = (left ? MK_LBUTTON : 0) | (right ? MK_RBUTTON : 0);
            Native.SendMessage(hwnd, msg, new IntPtr(wParam), new IntPtr((pt.Y << 16) | (pt.X & 0xFFFF)));
        }

        public static void Char(char ch)
        {
            IntPtr hwnd;
            lock (l) hwnd = lastClicked;
            if (hwnd != IntPtr.Zero) Native.SendMessage(hwnd, WM_CHAR, new IntPtr(ch), new IntPtr(1));
        }

        sealed class MouseSink : IMouseEventSink
        {
            public bool Post(SyntheticMouseEvent e)
            {
                int msg = e.Kind == SyntheticMouseEventKind.Down ? Native.WM_LBUTTONDOWN : e.Kind == SyntheticMouseEventKind.Up ? Native.WM_LBUTTONUP : Native.WM_MOUSEMOVE;
                Mouse(msg, e.Point);
                return true;
            }
            public PointD? CursorLocation() => Cursor;
        }

        sealed class ReplaySink : IReplayEventSink
        {
            public void PostMouse(ReplayMouse type, PointD p, PointerButton button, int clickState, KeyModifiers modifiers)
            {
                switch (type)
                {
                    case ReplayMouse.LeftDown: Mouse(Native.WM_LBUTTONDOWN, p); break;
                    case ReplayMouse.LeftUp: Mouse(Native.WM_LBUTTONUP, p); break;
                    case ReplayMouse.RightDown: Mouse(Native.WM_RBUTTONDOWN, p); break;
                    case ReplayMouse.RightUp: Mouse(Native.WM_RBUTTONUP, p); break;
                    default: Mouse(Native.WM_MOUSEMOVE, p); break;
                }
            }
            public void PostKey(KeyStroke stroke, bool down)
            {
                if (down && !stroke.IsShortcut && stroke.Characters.Length > 0) foreach (var ch in stroke.Characters) Char(ch);
            }
            public void SetClipboard(string s) { }
            public PointD? CursorLocation() => Cursor;
            public bool EscapePressed() => false;
            public bool IsTrusted() => true;
            public void Sleep(double seconds) => PreciseClock.Sleep(seconds);
        }
    }
}
