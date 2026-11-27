using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using DrawBot.Core;

namespace DrawBot.Win
{
    public sealed class OnScreenWindow : IEquatable<OnScreenWindow>
    {
        public IntPtr Handle;
        public int Pid;
        public string OwnerName = "";
        public RectD Bounds;
        /// <summary>0 for normal windows; 3 for floating ones (owned, tool or topmost windows).</summary>
        public int Layer;
        public double Alpha = 1;
        public bool ClickThrough;
        public string ClassName = "";

        public bool Equals(OnScreenWindow o) => o != null && Handle == o.Handle;
        public override bool Equals(object obj) => Equals(obj as OnScreenWindow);
        public override int GetHashCode() => Handle.GetHashCode();
        public override string ToString() => OwnerName + " [" + ClassName + "] " + Bounds + " layer " + Layer;
    }

    /// <summary>Processes: names, executables, elevation, liveness.</summary>
    public static class ProcessUtil
    {
        public static readonly int OwnPid = Process.GetCurrentProcess().Id;
        static readonly Dictionary<int, string> nameCache = new Dictionary<int, string>();

        public static string ExecutablePath(int pid)
        {
            var h = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                var sb = new StringBuilder(1024);
                int size = sb.Capacity;
                return Native.QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString(0, size) : null;
            }
            finally { Native.CloseHandle(h); }
        }

        /// <summary>The app's display name ("Paint", "Google Chrome"), falling back to the executable name.</summary>
        public static string DisplayName(int pid)
        {
            string n;
            lock (nameCache) if (nameCache.TryGetValue(pid, out n)) return n;
            n = null;
            var path = ExecutablePath(pid);
            if (path != null)
            {
                try
                {
                    var info = FileVersionInfo.GetVersionInfo(path);
                    n = !string.IsNullOrWhiteSpace(info.FileDescription) ? info.FileDescription.Trim()
                        : !string.IsNullOrWhiteSpace(info.ProductName) ? info.ProductName.Trim() : null;
                }
                catch (Exception) { }
                if (n == null) n = Path.GetFileNameWithoutExtension(path);
            }
            if (n == null)
            {
                try { n = Process.GetProcessById(pid).ProcessName; } catch (Exception) { n = "pid " + pid; }
            }
            lock (nameCache) nameCache[pid] = n;
            return n;
        }

        public static bool IsAlive(int pid)
        {
            var h = Native.OpenProcess(Native.SYNCHRONIZE, false, pid);
            if (h == IntPtr.Zero) return false;
            try { return Native.WaitForSingleObject(h, 0) != 0; }   // WAIT_OBJECT_0 == exited
            finally { Native.CloseHandle(h); }
        }

        /// <summary>True / false when known; null when the process can't be inspected (often: it is elevated and we are not).</summary>
        public static bool? IsElevated(int pid)
        {
            var h = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                IntPtr token;
                if (!Native.OpenProcessToken(h, Native.TOKEN_QUERY, out token)) return null;
                try
                {
                    int elevated, len;
                    if (!Native.GetTokenInformation(token, Native.TokenElevation, out elevated, 4, out len)) return null;
                    return elevated != 0;
                }
                finally { Native.CloseHandle(token); }
            }
            finally { Native.CloseHandle(h); }
        }

        public static bool SelfElevated => IsElevated(OwnPid) == true;
    }

    /// <summary>
    /// Top-level windows in front-to-back order (EnumWindows), with the filtering of the macOS
    /// version: invisible, cloaked, minimized, click-through and nearly transparent windows, tiny
    /// windows, and the desktop itself are ignored.
    /// </summary>
    public static class WindowInspector
    {
        static readonly HashSet<string> DesktopClasses = new HashSet<string> { "Progman", "WorkerW" };

        /// <summary>All eligible on-screen windows, front to back, including DrawBot's own.</summary>
        public static List<OnScreenWindow> OnScreenWindows()
        {
            var list = new List<OnScreenWindow>();
            Native.EnumWindows((hwnd, _) =>
            {
                var w = Describe(hwnd);
                if (w != null) list.Add(w);
                return true;
            }, IntPtr.Zero);
            return FilterEligible(list);
        }

        static OnScreenWindow Describe(IntPtr hwnd)
        {
            if (!Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd)) return null;
            int cloaked;
            if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_CLOAKED, out cloaked, 4) == 0 && cloaked != 0) return null;
            Native.RECT r;
            if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(Native.RECT))) != 0
                && !Native.GetWindowRect(hwnd, out r)) return null;
            int pid;
            Native.GetWindowThreadProcessId(hwnd, out pid);
            long ex = Native.GetWindowLong(hwnd, Native.GWL_EXSTYLE);
            double alpha = 1;
            if ((ex & Native.WS_EX_LAYERED) != 0)
            {
                uint key, flags; byte a;
                if (Native.GetLayeredWindowAttributes(hwnd, out key, out a, out flags) && (flags & Native.LWA_ALPHA) != 0) alpha = a / 255.0;
            }
            var cls = new StringBuilder(256);
            Native.GetClassName(hwnd, cls, cls.Capacity);
            bool floating = (ex & Native.WS_EX_TOPMOST) != 0 || (ex & Native.WS_EX_TOOLWINDOW) != 0 || Native.GetWindow(hwnd, Native.GW_OWNER) != IntPtr.Zero;
            return new OnScreenWindow
            {
                Handle = hwnd, Pid = pid, OwnerName = pid == ProcessUtil.OwnPid ? "DrawBot" : ProcessUtil.DisplayName(pid),
                Bounds = new RectD(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top), Layer = floating ? 3 : 0, Alpha = alpha,
                ClickThrough = (ex & Native.WS_EX_TRANSPARENT) != 0 && (ex & Native.WS_EX_LAYERED) != 0, ClassName = cls.ToString(),
            };
        }

        internal static List<OnScreenWindow> FilterEligible(List<OnScreenWindow> windows) =>
            windows.Where(w => w.Alpha >= 0.05 && !w.ClickThrough && w.Bounds.Width >= 4 && w.Bounds.Height >= 4
                               && !DesktopClasses.Contains(w.ClassName)).ToList();

        /// <summary>On-screen windows front-to-back containing point, excluding this process.</summary>
        public static List<OnScreenWindow> WindowsAt(PointD point) =>
            OnScreenWindows().Where(w => w.Pid != ProcessUtil.OwnPid && w.Bounds.Contains(point)).ToList();

        /// <summary>
        /// The window of the app being drawn in: the front-most window at the center of canvas.
        /// Normal windows win over floating ones (a palette or tooltip over the center is not the
        /// drawing app). DrawBot's own normal windows count (the Test Canvas); its floating panels
        /// are looked through.
        /// </summary>
        public static OnScreenWindow TargetWindow(RectD canvas) => TargetWindow(OnScreenWindows(), canvas, ProcessUtil.OwnPid);

        internal static OnScreenWindow TargetWindow(List<OnScreenWindow> windows, RectD canvas, int ownPid)
        {
            var c = canvas.Center;
            var candidates = windows.Where(w => w.Bounds.Contains(c) && (w.Pid != ownPid || w.Layer == 0)).ToList();
            return candidates.FirstOrDefault(w => w.Layer == 0) ?? candidates.FirstOrDefault();
        }

        /// <summary>
        /// Windows front-most at any of a 7×7 grid of points inside canvas, i.e. things that would
        /// catch the drawing clicks: other apps' windows, and the target app's own floating windows
        /// where they lie over one of its normal windows. DrawBot's own windows count too, except
        /// when DrawBot itself is the target.
        /// </summary>
        public static List<OnScreenWindow> Obstructions(RectD canvas, int targetPid) => Obstructions(OnScreenWindows(), canvas, targetPid);

        internal static List<OnScreenWindow> Obstructions(List<OnScreenWindow> windows, RectD canvas, int targetPid)
        {
            var seen = new HashSet<IntPtr>();
            var result = new List<OnScreenWindow>();
            foreach (var p in SamplePoints(canvas))
            {
                int i = windows.FindIndex(w => w.Bounds.Contains(p));
                if (i < 0) continue;
                var top = windows[i];
                if (top.Pid == targetPid)
                {
                    if (top.Layer == 0) continue;
                    bool overOwnNormal = windows.Skip(i + 1).Any(w => w.Pid == targetPid && w.Layer == 0 && w.Bounds.Contains(p));
                    if (!overOwnNormal) continue;
                }
                if (seen.Add(top.Handle)) result.Add(top);
            }
            return result;
        }

        /// <summary>7×7 sample points inset 2 px inside canvas.</summary>
        internal static List<PointD> SamplePoints(RectD canvas)
        {
            var r = canvas.Standardized;
            var inset = r.Inset(Math.Min(2, r.Width / 2), Math.Min(2, r.Height / 2));
            var pts = new List<PointD>();
            for (int j = 0; j < 7; j++)
                for (int i = 0; i < 7; i++)
                    pts.Add(new PointD(inset.X + inset.Width * i / 6, inset.Y + inset.Height * j / 6));
            return pts;
        }

        public static string Title(IntPtr hwnd)
        {
            int n = Native.GetWindowTextLength(hwnd);
            var sb = new StringBuilder(Math.Max(1, n + 1));
            Native.GetWindowText(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }
    }

    /// <summary>The app that will receive the drawing.</summary>
    public sealed class TargetApp : IEquatable<TargetApp>
    {
        public int Pid;
        /// <summary>The window under the canvas.</summary>
        public IntPtr Window;
        public string ExePath;
        public string Name;

        public static TargetApp From(OnScreenWindow w) => new TargetApp
        {
            Pid = w.Pid, Window = GetRoot(w.Handle), ExePath = ProcessUtil.ExecutablePath(w.Pid), Name = w.OwnerName,
        };

        static IntPtr GetRoot(IntPtr h) { var r = Native.GetAncestor(h, Native.GA_ROOT); return r != IntPtr.Zero ? r : h; }

        public bool IsTerminated => !ProcessUtil.IsAlive(Pid);
        public string ExeName => ExePath != null ? Path.GetFileName(ExePath).ToLowerInvariant() : null;

        public bool Equals(TargetApp o) => o != null && Pid == o.Pid && Window == o.Window;
        public override bool Equals(object obj) => Equals(obj as TargetApp);
        public override int GetHashCode() => Pid;
    }

    public static class AppActivator
    {
        public static int? ForegroundPid
        {
            get
            {
                var fg = Native.GetForegroundWindow();
                if (fg == IntPtr.Zero) return null;
                int pid;
                Native.GetWindowThreadProcessId(fg, out pid);
                return pid;
            }
        }

        /// <summary>
        /// Brings app's window to the front, polling until its process owns the foreground window or
        /// timeout elapses. Completion runs on the UI thread (asynchronously), exactly once: true if
        /// the app is in front. Windows only lets a process take the foreground in some situations;
        /// if a plain request is refused, DrawBot briefly attaches to the foreground thread's input.
        /// </summary>
        public static void Activate(TargetApp app, double timeout, Action<bool> completion)
        {
            var timer = new Timer { Interval = 50 };
            var start = DateTime.UtcNow;
            bool fallbackDone = false;
            if (ForegroundPid == app.Pid) { Defer(() => completion(true)); return; }
            if (app.IsTerminated) { Defer(() => completion(false)); return; }
            Request(app, false);
            timer.Tick += (s, e) =>
            {
                if (ForegroundPid == app.Pid) { timer.Dispose(); completion(true); return; }
                double elapsed = (DateTime.UtcNow - start).TotalSeconds;
                if (elapsed >= timeout || app.IsTerminated) { timer.Dispose(); completion(false); return; }
                if (!fallbackDone && elapsed >= 0.3) { fallbackDone = true; Request(app, true); }
            };
            timer.Start();
        }

        public static void Defer(Action a)
        {
            var t = new Timer { Interval = 1 };
            t.Tick += (s, e) => { t.Dispose(); a(); };
            t.Start();
        }

        static void Request(TargetApp app, bool force)
        {
            var hwnd = app.Window;
            if (!Native.IsWindow(hwnd)) return;
            if (Native.IsIconic(hwnd)) Native.ShowWindow(hwnd, Native.SW_RESTORE);
            if (!force)
            {
                Native.SetForegroundWindow(hwnd);
                return;
            }
            // Attach to the foreground thread's input so SetForegroundWindow is allowed.
            int pid;
            uint fgThread = Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out pid);
            uint me = Native.GetCurrentThreadId();
            bool attached = fgThread != 0 && fgThread != me && Native.AttachThreadInput(me, fgThread, true);
            try
            {
                Native.BringWindowToTop(hwnd);
                Native.SetForegroundWindow(hwnd);
            }
            finally { if (attached) Native.AttachThreadInput(me, fgThread, false); }
        }
    }

    /// <summary>Screenshots of screen rectangles (for learning preset color buttons). Needs no permission on Windows.</summary>
    public static class ScreenSampler
    {
        /// <summary>Captures rect (virtual-screen pixels). DrawBot's own panels are excluded from captures (see ExcludeFromCapture).</summary>
        public static RGBAImage Capture(RectD rect)
        {
            var vs = ScreenSpace.VirtualScreen;
            var clipped = rect.Intersection(vs).Integral;
            if (clipped.IsNull || clipped.Width < 1 || clipped.Height < 1) throw new InvalidOperationException("Nothing to capture");
            int w = (int)clipped.Width, h = (int)clipped.Height;
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                    g.CopyFromScreen((int)clipped.X, (int)clipped.Y, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
                var img = ImageLoader.FromBitmap(bmp);
                for (int i = 3; i < img.Data.Length; i += 4) img.Data[i] = 255;
                return img;
            }
        }

        /// <summary>Keeps a window out of screenshots (Windows 10 2004+; ignored elsewhere).</summary>
        public static void ExcludeFromCapture(IntPtr hwnd)
        {
            try { Native.SetWindowDisplayAffinity(hwnd, Native.WDA_EXCLUDEFROMCAPTURE); } catch (Exception) { }
        }
    }

    public static class Displays
    {
        /// <summary>Refresh rate of the monitor showing most of rect (60 if unknown).</summary>
        public static int RefreshRate(RectD rect)
        {
            try
            {
                var screen = Screen.FromRectangle(new Rectangle((int)rect.X, (int)rect.Y, Math.Max(1, (int)rect.Width), Math.Max(1, (int)rect.Height)));
                var dm = new Native.DEVMODE { dmSize = (short)Marshal.SizeOf(typeof(Native.DEVMODE)) };
                if (Native.EnumDisplaySettings(screen.DeviceName, Native.ENUM_CURRENT_SETTINGS, ref dm) && dm.dmDisplayFrequency > 1)
                    return dm.dmDisplayFrequency;
            }
            catch (Exception) { }
            return 60;
        }

        public static RectD ToRect(Rectangle r) => new RectD(r.X, r.Y, r.Width, r.Height);

        public static List<RectD> ScreenRects() => Screen.AllScreens.Select(s => ToRect(s.Bounds)).ToList();

        public static Screen ScreenFor(RectD rect) =>
            Screen.FromRectangle(new Rectangle((int)rect.X, (int)rect.Y, Math.Max(1, (int)rect.Width), Math.Max(1, (int)rect.Height)));

        /// <summary>True when rect's center is on a connected monitor.</summary>
        public static bool IsOnConnectedScreen(RectD rect) => Screen.AllScreens.Any(s => ToRect(s.Bounds).Contains(rect.Center));

        /// <summary>DPI scale of the monitor showing rect (1 = 100%).</summary>
        public static double Scale(RectD rect)
        {
            try
            {
                IntPtr mon = MonitorFromPoint(new Native.POINT((int)rect.MidX, (int)rect.MidY), 2);
                uint dx, dy;
                if (GetDpiForMonitor(mon, 0, out dx, out dy) == 0) return dx / 96.0;
            }
            catch (Exception) { }
            return 1;
        }

        [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Native.POINT p, uint flags);
        [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr mon, int type, out uint dpiX, out uint dpiY);
    }
}
