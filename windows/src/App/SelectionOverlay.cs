using System;
using System.Drawing;
using System.Windows.Forms;
using DrawBot.Core;
using DrawBot.Win;

namespace DrawBot.App
{
    /// <summary>
    /// Canvas selection: dims every screen; the user drags a rectangle (kept on the screen where
    /// the drag began). Esc cancels. A rectangle smaller than 8×8 is ignored.
    /// </summary>
    public sealed class SelectionOverlay
    {
        static readonly Color Hole = Color.FromArgb(255, 0, 255);
        OverlayForm form;
        NoActivateForm sizeLabel, hint;
        Action<RectD?> completion;

        public bool IsActive => form != null;

        public void Begin(Action<RectD?> done)
        {
            Cancel();
            completion = done;
            var vs = ScreenSpace.VirtualScreen;
            form = new OverlayForm(this) { Bounds = vs.ToRectangle() };
            hint = MakeLabel("Drag to select the drawing area · Esc to cancel", 13f);
            sizeLabel = MakeLabel("", 9.5f);
            form.Show();
            form.Activate();
            form.Focus();
            var primary = Screen.PrimaryScreen.Bounds;
            foreach (var s in Screen.AllScreens)
            {
                if (!s.Bounds.Contains(Cursor.Position)) continue;
                primary = s.Bounds;
            }
            hint.Location = new Point(primary.Left + (primary.Width - hint.Width) / 2, primary.Top + primary.Height / 2 - hint.Height / 2);
            hint.ShowNoActivate();
        }

        NoActivateForm MakeLabel(string text, float size)
        {
            var f = new NoActivateForm { ClickThrough = true, BackColor = Color.FromArgb(30, 30, 30), AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(10, 6, 10, 6) };
            f.Controls.Add(new Label { Text = text, ForeColor = Color.White, Font = new Font("Segoe UI", size), AutoSize = true, Name = "text" });
            return f;
        }

        public void Cancel() => Finish(null);

        void Finish(RectD? rect)
        {
            if (form == null) return;
            var f = form; form = null;
            f.Close(); f.Dispose();
            hint?.Close(); hint?.Dispose(); hint = null;
            sizeLabel?.Close(); sizeLabel?.Dispose(); sizeLabel = null;
            var c = completion; completion = null;
            c?.Invoke(rect);
        }

        void ShowSize(Rectangle screenRect)
        {
            if (sizeLabel == null) return;
            sizeLabel.Controls["text"].Text = screenRect.Width + " × " + screenRect.Height + " px";
            sizeLabel.Location = new Point(screenRect.Left, Math.Max(screenRect.Top - sizeLabel.Height - 4, Screen.FromRectangle(screenRect).Bounds.Top));
            sizeLabel.ShowNoActivate();
            hint?.Hide();
        }

        sealed class OverlayForm : Form
        {
            readonly SelectionOverlay owner;
            Point? start;
            Rectangle screenOfDrag;
            Rectangle selection;   // in screen coordinates

            public OverlayForm(SelectionOverlay owner)
            {
                this.owner = owner;
                FormBorderStyle = FormBorderStyle.None;
                StartPosition = FormStartPosition.Manual;
                ShowInTaskbar = false;
                TopMost = true;
                BackColor = Color.Black;
                Opacity = 0.3;
                TransparencyKey = Hole;
                DoubleBuffered = true;
                Cursor = Cursors.Cross;
                KeyPreview = true;
            }

            protected override CreateParams CreateParams
            {
                get { var cp = base.CreateParams; cp.ExStyle |= (int)Native.WS_EX_TOOLWINDOW; return cp; }
            }

            protected override void OnKeyDown(KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Escape) owner.Cancel();
                base.OnKeyDown(e);
            }

            protected override void OnDeactivate(EventArgs e)
            {
                base.OnDeactivate(e);
                // Keep the keyboard focus (for Esc) while selecting.
                if (owner.form == this && start == null) BeginInvoke((Action)(() => { if (owner.form == this) Activate(); }));
            }

            protected override void OnMouseDown(MouseEventArgs e)
            {
                if (e.Button != MouseButtons.Left) return;
                var p = PointToScreen(e.Location);
                screenOfDrag = Screen.FromPoint(p).Bounds;
                start = p;
                selection = new Rectangle(p, Size.Empty);
            }

            protected override void OnMouseMove(MouseEventArgs e)
            {
                if (start == null) return;
                var p = PointToScreen(e.Location);
                p = new Point(Math.Min(Math.Max(p.X, screenOfDrag.Left), screenOfDrag.Right), Math.Min(Math.Max(p.Y, screenOfDrag.Top), screenOfDrag.Bottom));
                var r = Geometry.RectFrom(new PointD(start.Value.X, start.Value.Y), new PointD(p.X, p.Y));
                var old = selection;
                selection = r.ToRectangle();
                var dirty = Rectangle.Union(old, selection);
                dirty.Inflate(4, 4);
                dirty.Offset(-Left, -Top);
                Invalidate(dirty);
                owner.ShowSize(selection);
            }

            protected override void OnMouseUp(MouseEventArgs e)
            {
                if (start == null || e.Button != MouseButtons.Left) return;
                start = null;
                if (selection.Width < 8 || selection.Height < 8)
                {
                    var dirty = selection; dirty.Inflate(4, 4); dirty.Offset(-Left, -Top);
                    selection = Rectangle.Empty;
                    Invalidate(dirty);
                    owner.sizeLabel?.Hide();
                    return;   // too small: keep the overlay up
                }
                owner.Finish(selection.ToRectD());
            }

            protected override void OnPaint(PaintEventArgs e)
            {
                if (selection.Width <= 0 || selection.Height <= 0) return;
                var r = selection; r.Offset(-Left, -Top);
                using (var hole = new SolidBrush(Hole)) e.Graphics.FillRectangle(hole, r);
                using (var white = new Pen(Color.White, 2)) e.Graphics.DrawRectangle(white, r.X - 1, r.Y - 1, r.Width + 1, r.Height + 1);
            }
        }
    }
}
