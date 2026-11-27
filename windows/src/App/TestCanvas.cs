using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using DrawBot.Core;

namespace DrawBot.App
{
    /// <summary>A white surface that records mouse drags as round-capped lines into an offscreen bitmap.</summary>
    public sealed class TestCanvasView : Control
    {
        public Func<Tuple<Color, float>> StrokeStyle = () => Tuple.Create(Color.Black, 4f);
        Bitmap bitmap;
        Point? last;
        Color color = Color.Black;
        float width = 4;

        public TestCanvasView()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.Opaque, true);
            BackColor = Color.White;
        }

        /// <summary>The drawing so far (for tests).</summary>
        public Bitmap Snapshot() { Ensure(); return (Bitmap)bitmap.Clone(); }

        public void Clear()
        {
            Ensure();
            using (var g = Graphics.FromImage(bitmap)) g.Clear(Color.White);
            Invalidate();
        }

        void Ensure()
        {
            int w = Math.Max(1, ClientSize.Width), h = Math.Max(1, ClientSize.Height);
            if (bitmap != null && bitmap.Width >= w && bitmap.Height >= h) return;
            var nb = new Bitmap(Math.Max(w, bitmap?.Width ?? 0), Math.Max(h, bitmap?.Height ?? 0));
            using (var g = Graphics.FromImage(nb))
            {
                g.Clear(Color.White);
                if (bitmap != null) g.DrawImageUnscaled(bitmap, 0, 0);
            }
            bitmap?.Dispose();
            bitmap = nb;
        }

        protected override void OnResize(EventArgs e) { base.OnResize(e); Ensure(); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Ensure();
            e.Graphics.DrawImage(bitmap, e.ClipRectangle, e.ClipRectangle, GraphicsUnit.Pixel);
        }

        void Segment(Point a, Point b)
        {
            Ensure();
            using (var g = Graphics.FromImage(bitmap))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (var pen = new Pen(color, width) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                {
                    if (a == b)
                        using (var br = new SolidBrush(color)) g.FillEllipse(br, a.X - width / 2, a.Y - width / 2, width, width);
                    else g.DrawLine(pen, a, b);
                }
            }
            var dirty = Rectangle.FromLTRB(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));
            dirty.Inflate((int)(width / 2) + 2, (int)(width / 2) + 2);
            Invalidate(dirty);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            var st = StrokeStyle();
            color = st.Item1; width = Math.Max(0.5f, st.Item2);
            last = e.Location;
            Segment(e.Location, e.Location);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (last == null) return;   // a stroke is under way from mouse-down to mouse-up
            Segment(last.Value, e.Location);
            last = e.Location;
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (last == null) return;
            if (last.Value != e.Location) Segment(last.Value, e.Location);
            last = null;
        }
    }

    /// <summary>The Test Canvas's color picker: a saturation × brightness square and a hue strip (0° at the top).</summary>
    public sealed class MiniColorPicker : Control
    {
        public double Hue { get; private set; }
        public double Saturation { get; private set; }
        public double Brightness { get; private set; }
        public Action<RGB> OnChange = _ => { };
        enum Zone { None, Square, Strip }
        Zone dragging;

        public const int Side = 150, StripWidth = 18, Gap = 10;
        Rectangle SquareRect => new Rectangle(0, 0, Side, Side);
        Rectangle StripRect => new Rectangle(Side + Gap, 0, StripWidth, Side);

        public MiniColorPicker()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
            Size = new Size(Side + Gap + StripWidth + 1, Side + 1);
        }

        public RGB Color => ColorMath.RgbFromHsb(Hue, Saturation, Brightness);

        public void SetColor(RGB c, bool notify = false)
        {
            double h, s, v;
            ColorMath.Hsb(c, out h, out s, out v);
            if (s > 0 && v > 0) Hue = h;
            Saturation = s; Brightness = v;
            Invalidate();
            if (notify) OnChange(Color);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            var sq = SquareRect;
            using (var b = new SolidBrush(ColorMath.RgbFromHsb(Hue, 100, 100).ToColor())) g.FillRectangle(b, sq);
            using (var white = new LinearGradientBrush(new Rectangle(sq.X - 1, sq.Y, sq.Width + 1, sq.Height), System.Drawing.Color.White, System.Drawing.Color.FromArgb(0, 255, 255, 255), LinearGradientMode.Horizontal))
                g.FillRectangle(white, sq);
            using (var black = new LinearGradientBrush(new Rectangle(sq.X, sq.Y - 1, sq.Width, sq.Height + 1), System.Drawing.Color.FromArgb(0, 0, 0, 0), System.Drawing.Color.Black, LinearGradientMode.Vertical))
                g.FillRectangle(black, sq);
            var st = StripRect;
            for (int y = 0; y < st.Height; y++)
                using (var p = new Pen(ColorMath.RgbFromHsb(360.0 * y / st.Height, 100, 100).ToColor())) g.DrawLine(p, st.Left, st.Top + y, st.Right - 1, st.Top + y);
            using (var border = new Pen(System.Drawing.Color.FromArgb(160, 160, 160))) { g.DrawRectangle(border, sq); g.DrawRectangle(border, st); }
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float px = (float)(sq.Left + Saturation / 100 * sq.Width), py = (float)(sq.Top + (1 - Brightness / 100) * sq.Height);
            using (var m = new Pen(Brightness > 55 && Saturation < 45 ? System.Drawing.Color.Black : System.Drawing.Color.White, 1.5f)) g.DrawEllipse(m, px - 5, py - 5, 10, 10);
            float hy = (float)(st.Top + Hue / 360 * st.Height);
            using (var m = new Pen(System.Drawing.Color.Black)) g.DrawRectangle(m, st.Left - 2, hy - 2, st.Width + 3, 4);
        }

        void UpdateAt(Point p)
        {
            if (dragging == Zone.Square)
            {
                var sq = SquareRect;
                Saturation = Math.Min(Math.Max((p.X - sq.Left) / (double)sq.Width, 0), 1) * 100;
                Brightness = (1 - Math.Min(Math.Max((p.Y - sq.Top) / (double)sq.Height, 0), 1)) * 100;
            }
            else if (dragging == Zone.Strip)
            {
                var st = StripRect;
                Hue = Math.Min(Math.Max((p.Y - st.Top) / (double)st.Height, 0), 1) * 360;
                if (Hue >= 360) Hue = 0;
            }
            else return;
            Invalidate();
            OnChange(Color);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            var sq = SquareRect; sq.Inflate(3, 3);
            var st = StripRect; st.Inflate(4, 3);
            dragging = sq.Contains(e.Location) ? Zone.Square : st.Contains(e.Location) ? Zone.Strip : Zone.None;
            UpdateAt(e.Location);
        }

        protected override void OnMouseMove(MouseEventArgs e) { if (dragging != Zone.None) UpdateAt(e.Location); }
        protected override void OnMouseUp(MouseEventArgs e) { UpdateAt(e.Location); dragging = Zone.None; }
    }

    /// <summary>The built-in Test Canvas: a white drawing surface, Clear, and a small color picker Color Learn can learn.</summary>
    public sealed class TestCanvasForm : Form
    {
        public readonly TestCanvasView Canvas;
        public readonly MiniColorPicker Picker;
        readonly TextBox hexField;
        readonly Swatch swatch;

        public RGB PickedColor => Picker.Color;

        public TestCanvasForm(Func<Tuple<Color, float>> strokeStyle)
        {
            Text = "DrawBot Test Canvas";
            AutoScaleMode = AutoScaleMode.Dpi;
            ClientSize = new Size(1010, 600);
            MinimumSize = new Size(560, 360);
            StartPosition = FormStartPosition.CenterScreen;
            Icon = Ui.MakeIcon();
            KeyPreview = true;

            var bar = new Panel { Dock = DockStyle.Top, Height = 38, BackColor = SystemColors.Control };
            var clear = new Button { Text = "Clear", Location = new Point(8, 7), AutoSize = true, FlatStyle = FlatStyle.System };
            bar.Controls.Add(clear);
            bar.Controls.Add(new Label { Text = "Select Canvas inside the white area, then Start Drawing.", AutoSize = true, Location = new Point(96, 11), ForeColor = Ui.Secondary });

            var side = new Panel { Dock = DockStyle.Right, Width = 210, BackColor = SystemColors.Control };
            side.Controls.Add(new Label { Text = "Color picker", Font = Ui.Bold, AutoSize = true, Location = new Point(16, 12) });
            Picker = new MiniColorPicker { Location = new Point(16, 36) };
            side.Controls.Add(Picker);
            side.Controls.Add(new Label { Text = "Hex #", AutoSize = true, Location = new Point(16, 204) });
            hexField = new TextBox { Location = new Point(60, 200), Width = 76, Font = Ui.Mono, Text = "000000" };
            side.Controls.Add(hexField);
            swatch = new Swatch { Location = new Point(144, 200), Size = new Size(40, 22) };
            side.Controls.Add(swatch);
            side.Controls.Add(new Label
            {
                Text = "With Color selection set to automatic, DrawBot paints with this picker's color. Teach it with Learn Color Picker… in the DrawBot panel.",
                Location = new Point(16, 236), Size = new Size(184, 90), ForeColor = Ui.Secondary, Font = Ui.Small,
            });

            Canvas = new TestCanvasView { Dock = DockStyle.Fill, StrokeStyle = strokeStyle };
            Controls.Add(Canvas);
            Controls.Add(side);
            Controls.Add(bar);

            clear.Click += (s, e) => Canvas.Clear();
            Picker.OnChange = c => { swatch.Color = c; if (!hexField.Focused) hexField.Text = c.HexNoHash; };
            hexField.KeyDown += (s, e) => { if (e.KeyCode == Keys.Enter) { ApplyHex(); e.SuppressKeyPress = true; } };
            hexField.Leave += (s, e) => ApplyHex();
            hexField.TextChanged += (s, e) => { RGB c; if (hexField.Focused && RGB.TryParseHex(hexField.Text, out c) && hexField.Text.Trim().TrimStart('#').Length == 6) { Picker.SetColor(c); swatch.Color = c; } };
            Picker.OnChange(Picker.Color);
            FormClosing += (s, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } };
        }

        void ApplyHex()
        {
            RGB c;
            if (!RGB.TryParseHex(hexField.Text, out c)) { hexField.Text = Picker.Color.HexNoHash; return; }
            Picker.SetColor(c);
            swatch.Color = c;
            hexField.Text = c.HexNoHash;
        }

        public bool IsShown => Visible && WindowState != FormWindowState.Minimized;

        /// <summary>The drawing surface's bounds in screen pixels.</summary>
        public RectD CanvasScreenRect => Canvas.RectangleToScreen(Canvas.ClientRectangle).ToRectD();

        public void ShowCanvas()
        {
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Show();
            Activate();
        }
    }
}
