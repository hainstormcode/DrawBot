using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;
using DrawBot.Core;
using DrawBot.Win;

namespace DrawBot.App
{
    public static class Ui
    {
        /// <summary>Runs action on the UI thread after seconds (a one-shot WinForms timer).</summary>
        public static void After(double seconds, Action action)
        {
            var t = new Timer { Interval = Math.Max(1, (int)Math.Round(seconds * 1000)) };
            t.Tick += (s, e) => { t.Stop(); t.Dispose(); action(); };
            t.Start();
        }

        public static Color ToColor(this RGB c) => Color.FromArgb(c.R, c.G, c.B);
        public static RGB ToRGB(this Color c) => new RGB(c.R, c.G, c.B);
        public static Rectangle ToRectangle(this RectD r) => new Rectangle((int)Math.Round(r.X), (int)Math.Round(r.Y), (int)Math.Round(r.Width), (int)Math.Round(r.Height));
        public static RectD ToRectD(this Rectangle r) => new RectD(r.X, r.Y, r.Width, r.Height);

        public static readonly Font Body = new Font("Segoe UI", 9f);
        public static readonly Font Small = new Font("Segoe UI", 8.25f);
        public static readonly Font Bold = new Font("Segoe UI", 9f, FontStyle.Bold);
        public static readonly Font Title = new Font("Segoe UI Semibold", 12f);
        public static readonly Font Mono = new Font("Consolas", 9.5f);
        public static readonly Color Secondary = Color.FromArgb(100, 100, 100);
        public static readonly Color Warning = Color.FromArgb(196, 96, 0);
        public static readonly Color Good = Color.FromArgb(0, 128, 60);

        public const string HotkeyPrefix = "Ctrl+Alt+Shift+";
        public const string ContinueKey = HotkeyPrefix + "Enter";

        /// <summary>The tray / window icon: a small paintbrush, drawn at run time.</summary>
        public static Icon MakeIcon(int size = 32)
        {
            using (var bmp = new Bitmap(size, size))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    float s = size / 32f;
                    using (var handle = new Pen(Color.FromArgb(120, 72, 40), 5 * s) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                        g.DrawLine(handle, 27 * s, 5 * s, 15 * s, 17 * s);
                    using (var ferrule = new Pen(Color.FromArgb(170, 170, 180), 6 * s))
                        g.DrawLine(ferrule, 16 * s, 16 * s, 12.5f * s, 19.5f * s);
                    using (var tip = new SolidBrush(Color.FromArgb(230, 90, 40)))
                        g.FillPolygon(tip, new[] { new PointF(13 * s, 17 * s), new PointF(15 * s, 21 * s), new PointF(6 * s, 29 * s), new PointF(4 * s, 26 * s) });
                }
                return Icon.FromHandle(bmp.GetHicon());
            }
        }

        /// <summary>Where to put a w×h window on the canvas's screen without covering avoid (or as little as possible).</summary>
        public static Point PlaceOutside(RectD avoid, Size size, int margin = 16)
        {
            var screen = Displays.ScreenFor(avoid).WorkingArea;
            var a = avoid.ToRectangle();
            var candidates = new List<Point>
            {
                new Point(a.Right + margin, a.Top),
                new Point(a.Left - margin - size.Width, a.Top),
                new Point(a.Left, a.Bottom + margin),
                new Point(a.Left, a.Top - margin - size.Height),
                new Point(screen.Right - size.Width - margin, screen.Top + margin),
                new Point(screen.Left + margin, screen.Top + margin),
                new Point(screen.Right - size.Width - margin, screen.Bottom - size.Height - margin),
                new Point(screen.Left + margin, screen.Bottom - size.Height - margin),
            };
            Point best = candidates[4];
            long bestOverlap = long.MaxValue;
            foreach (var p in candidates)
            {
                var x = Math.Min(Math.Max(p.X, screen.Left), screen.Right - size.Width);
                var y = Math.Min(Math.Max(p.Y, screen.Top), screen.Bottom - size.Height);
                var r = new Rectangle(x, y, size.Width, size.Height);
                var inter = Rectangle.Intersect(r, a);
                long overlap = inter.IsEmpty ? 0 : (long)inter.Width * inter.Height;
                if (overlap < bestOverlap) { bestOverlap = overlap; best = new Point(x, y); }
                if (overlap == 0) break;
            }
            return best;
        }
    }

    /// <summary>A window that never takes the focus: clicking it leaves the drawing app in front.</summary>
    public class NoActivateForm : Form
    {
        public bool ClickThrough;

        public NoActivateForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            AutoScaleMode = AutoScaleMode.Dpi;
        }

        protected override bool ShowWithoutActivation => true;

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= (int)(Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST);
                if (ClickThrough) cp.ExStyle |= (int)(Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED);
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            ScreenSampler.ExcludeFromCapture(Handle);
        }

        const int WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3, WM_NCHITTEST = 0x84, HTCAPTION = 2, HTCLIENT = 1, HTTRANSPARENT = -1;

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_MOUSEACTIVATE) { m.Result = (IntPtr)MA_NOACTIVATE; return; }
            if (m.Msg == WM_NCHITTEST && ClickThrough) { m.Result = (IntPtr)HTTRANSPARENT; return; }
            base.WndProc(ref m);
            // Drag the panel by its background.
            if (m.Msg == WM_NCHITTEST && m.Result == (IntPtr)HTCLIENT && !ClickThrough) m.Result = (IntPtr)HTCAPTION;
        }

        /// <summary>Shows without activating and keeps it above everything.</summary>
        public void ShowNoActivate()
        {
            if (!Visible) { Native.ShowWindow(Handle, Native.SW_SHOWNOACTIVATE); Visible = true; }
            Native.SetWindowPos(Handle, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        }
    }

    /// <summary>A plain color swatch.</summary>
    public sealed class Swatch : Control
    {
        RGB color;
        public RGB Color { get => color; set { color = value; Invalidate(); } }
        public bool Crossed;
        public Swatch() { DoubleBuffered = true; Size = new Size(40, 22); }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var b = new SolidBrush(color.ToColor())) g.FillRectangle(b, r);
            using (var p = new Pen(System.Drawing.Color.FromArgb(150, 150, 150))) g.DrawRectangle(p, r);
            if (Crossed)
                using (var p = new Pen(System.Drawing.Color.Red, 2)) { g.DrawLine(p, 2, 2, Width - 3, Height - 3); g.DrawLine(p, Width - 3, 2, 2, Height - 3); }
        }
    }
}
