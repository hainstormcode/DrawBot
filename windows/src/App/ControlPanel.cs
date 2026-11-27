using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using DrawBot.Core;
using DrawBot.Win;

namespace DrawBot.App
{
    /// <summary>The main window: image, canvas, settings, preview, Color Learn and Start.</summary>
    public sealed class ControlPanel : Form
    {
        readonly AppController c;
        bool refreshing, refreshQueued;

        readonly Label statusRow, imageInfo, canvasInfo, targetInfo, targetWarning, penHelper, learnStatus, footer, message, hotkeyNote;
        readonly Button startButton, learnButton, forgetButton, selectButton;
        readonly NumericUpDown colors, pen, countdown;
        readonly TrackBar merge;
        readonly Label mergeValue;
        readonly ComboBox speed, strokes, order, selection, selectionSpeed;
        readonly CheckBox pauseOnMove, skipWhite;
        readonly PreviewBox preview;
        readonly FlowLayoutPanel palette;

        public ControlPanel(AppController controller)
        {
            c = controller;
            Text = "DrawBot";
            Icon = Ui.MakeIcon();
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = Ui.Body;
            StartPosition = FormStartPosition.Manual;
            ClientSize = new Size(470, 860);
            MinimumSize = new Size(420, 520);
            var wa = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(wa.Right - Width - 24, wa.Top + 24);
            if (Height > wa.Height - 48) Height = wa.Height - 48;
            KeyPreview = true;
            AllowDrop = true;

            var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(12, 8, 12, 8) };
            var col = new TableLayoutPanel { ColumnCount = 1, Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
            col.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            scroll.Controls.Add(col);
            Controls.Add(scroll);
            scroll.Resize += (s, e) => col.Width = scroll.ClientSize.Width - scroll.Padding.Horizontal;

            Func<string, Label> label = t => new Label { Text = t, AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 2, 0, 2), UseMnemonic = false };
            Func<string, Label> wrap = t => new WrapLabel { Text = t, Dock = DockStyle.Top, Margin = new Padding(0, 2, 0, 4), ForeColor = Ui.Secondary, Font = Ui.Small };
            Func<string, GroupBox> group = t => new GroupBox { Text = t, Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(8, 4, 8, 6), Margin = new Padding(0, 6, 0, 0) };
            Func<GroupBox, TableLayoutPanel> inner = g =>
            {
                var t = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1 };
                t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
                g.Controls.Add(t);
                return t;
            };
            Func<Control[], FlowLayoutPanel> row = cs =>
            {
                var f = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, WrapContents = true, Margin = new Padding(0, 2, 0, 2) };
                f.Controls.AddRange(cs);
                return f;
            };
            Func<string, Button> button = t => new Button { Text = t, AutoSize = true, FlatStyle = FlatStyle.System, Margin = new Padding(0, 0, 6, 0) };

            statusRow = new WrapLabel { Dock = DockStyle.Top, Font = Ui.Bold, Margin = new Padding(0, 4, 0, 4) };
            col.Controls.Add(statusRow);

            // Image
            var gImage = group("Image");
            var tImage = inner(gImage);
            var choose = button("Choose Image…");
            var paste = button("Paste");
            tImage.Controls.Add(row(new Control[] { choose, paste }));
            imageInfo = wrap("Drop an image here, paste one (Ctrl+V), or choose a file.");
            tImage.Controls.Add(imageInfo);
            col.Controls.Add(gImage);

            // Canvas
            var gCanvas = group("Canvas");
            var tCanvas = inner(gCanvas);
            selectButton = button("Select Canvas (" + Ui.HotkeyPrefix + "S)");
            var testCanvas = button("Test Canvas");
            tCanvas.Controls.Add(row(new Control[] { selectButton, testCanvas }));
            canvasInfo = wrap("No canvas yet: open your drawing app at 100% zoom, then select the part of its canvas to paint.");
            tCanvas.Controls.Add(canvasInfo);
            targetInfo = label("");
            tCanvas.Controls.Add(targetInfo);
            targetWarning = new WrapLabel { Dock = DockStyle.Top, ForeColor = Ui.Warning, Font = Ui.Small, Visible = false };
            tCanvas.Controls.Add(targetWarning);
            col.Controls.Add(gCanvas);

            // Settings
            var gSettings = group("Settings");
            var grid = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2 };
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            gSettings.Controls.Add(grid);
            Action<string, Control> add = (t, ctl) =>
            {
                grid.Controls.Add(new Label { Text = t, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(0, 6, 8, 2) });
                ctl.Anchor = ctl is NumericUpDown ? AnchorStyles.Left : AnchorStyles.Left | AnchorStyles.Right;
                grid.Controls.Add(ctl);
            };
            colors = new NumericUpDown { Minimum = DrawSettings.MinColors, Maximum = DrawSettings.MaxColorsLimit, Width = 70, Anchor = AnchorStyles.Left };
            add("Colors", colors);
            var mergeRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0) };
            merge = new TrackBar { Minimum = 0, Maximum = 30, TickFrequency = 5, Width = 200, AutoSize = false, Height = 30 };
            mergeValue = new Label { AutoSize = true, Margin = new Padding(4, 8, 0, 0) };
            mergeRow.Controls.Add(merge); mergeRow.Controls.Add(mergeValue);
            add("Merge similar", mergeRow);
            pen = new NumericUpDown { Minimum = (decimal)DrawSettings.MinPen, Maximum = (decimal)DrawSettings.MaxPen, DecimalPlaces = 1, Increment = 0.5m, Width = 70 };
            add("Pen size (px)", pen);
            grid.Controls.Add(new Label());
            penHelper = new WrapLabel { ForeColor = Ui.Secondary, Font = Ui.Small, Anchor = AnchorStyles.Left | AnchorStyles.Right };
            grid.Controls.Add(penHelper);
            speed = Combo(EnumNames.All<SpeedPreset>().Select(p => p.DisplayName()));
            add("Speed", speed);
            strokes = Combo(EnumNames.All<StrokeStyle>().Select(p => p.DisplayName()));
            add("Strokes", strokes);
            order = Combo(EnumNames.All<ColorOrder>().Select(p => p.DisplayName()));
            add("Color order", order);
            countdown = new NumericUpDown { Minimum = DrawSettings.MinCountdown, Maximum = DrawSettings.MaxCountdown, Width = 70 };
            add("Countdown (s)", countdown);
            pauseOnMove = new CheckBox { Text = "Pause if I move the mouse", AutoSize = true };
            skipWhite = new CheckBox { Text = "Skip near-white colors", AutoSize = true };
            grid.Controls.Add(new Label()); grid.Controls.Add(pauseOnMove);
            grid.Controls.Add(new Label()); grid.Controls.Add(skipWhite);
            col.Controls.Add(gSettings);

            // Color selection
            var gLearn = group("Color selection");
            var tLearn = inner(gLearn);
            selection = Combo(EnumNames.All<ColorSelectionMode>().Select(m => m.DisplayName()));
            selection.Dock = DockStyle.Top;
            tLearn.Controls.Add(selection);
            var speedRow = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, WrapContents = false, Margin = new Padding(0, 4, 0, 0) };
            speedRow.Controls.Add(new Label { Text = "Selection speed", AutoSize = true, Margin = new Padding(0, 6, 8, 0) });
            selectionSpeed = Combo(EnumNames.All<SelectionSpeed>().Select(s => s.DisplayName()));
            selectionSpeed.Width = 160;
            speedRow.Controls.Add(selectionSpeed);
            tLearn.Controls.Add(speedRow);
            learnStatus = wrap("");
            tLearn.Controls.Add(learnStatus);
            learnButton = button("Learn Color Picker…");
            forgetButton = button("Forget");
            tLearn.Controls.Add(row(new Control[] { learnButton, forgetButton }));
            col.Controls.Add(gLearn);

            // Preview
            var gPreview = group("Preview");
            var tPreview = inner(gPreview);
            preview = new PreviewBox { Dock = DockStyle.Top, Height = 230 };
            tPreview.Controls.Add(preview);
            palette = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true, Margin = new Padding(0, 6, 0, 0) };
            tPreview.Controls.Add(palette);
            tPreview.Controls.Add(wrap("Click a color to skip it (or to draw it again)."));
            footer = new WrapLabel { Dock = DockStyle.Top, Margin = new Padding(0, 4, 0, 2) };
            tPreview.Controls.Add(footer);
            col.Controls.Add(gPreview);

            message = new WrapLabel { Dock = DockStyle.Top, ForeColor = Ui.Warning, Margin = new Padding(0, 6, 0, 0) };
            col.Controls.Add(message);

            startButton = new Button { Text = "Start Drawing", Dock = DockStyle.Top, Height = 40, Font = Ui.Title, Margin = new Padding(0, 8, 0, 4) };
            col.Controls.Add(startButton);
            hotkeyNote = wrap("Hotkeys: " + Ui.HotkeyPrefix + "P show this panel · " + Ui.HotkeyPrefix + "S select canvas · " + Ui.ContinueKey + " continue · " + Ui.HotkeyPrefix + ". stop · Esc stops while drawing.");
            col.Controls.Add(hotkeyNote);

            // Events
            choose.Click += (s, e) => c.ChooseImage(this);
            paste.Click += (s, e) => c.PasteImage();
            selectButton.Click += (s, e) => c.SelectCanvas();
            testCanvas.Click += (s, e) => c.OpenTestCanvas();
            learnButton.Click += (s, e) => c.LearnColorPicker();
            forgetButton.Click += (s, e) => c.ForgetColorProfile();
            startButton.Click += (s, e) => c.StartOrContinue();
            colors.ValueChanged += (s, e) => Change(x => x.MaxColors = (int)colors.Value);
            merge.ValueChanged += (s, e) => Change(x => x.MergeDistance = merge.Value);
            pen.ValueChanged += (s, e) => Change(x => x.PenSize = (double)pen.Value);
            countdown.ValueChanged += (s, e) => Change(x => x.CountdownSeconds = (int)countdown.Value);
            speed.SelectedIndexChanged += (s, e) => Change(x => x.Speed = EnumNames.All<SpeedPreset>()[speed.SelectedIndex]);
            strokes.SelectedIndexChanged += (s, e) => Change(x => x.StrokeStyle = EnumNames.All<StrokeStyle>()[strokes.SelectedIndex]);
            order.SelectedIndexChanged += (s, e) => Change(x => x.Order = EnumNames.All<ColorOrder>()[order.SelectedIndex]);
            selection.SelectedIndexChanged += (s, e) => Change(x => x.ColorSelection = EnumNames.All<ColorSelectionMode>()[selection.SelectedIndex]);
            selectionSpeed.SelectedIndexChanged += (s, e) => Change(x => x.SelectionSpeed = EnumNames.All<SelectionSpeed>()[selectionSpeed.SelectedIndex]);
            pauseOnMove.CheckedChanged += (s, e) => Change(x => x.PauseOnMouseMove = pauseOnMove.Checked);
            skipWhite.CheckedChanged += (s, e) => Change(x => x.SkipNearWhite = skipWhite.Checked);
            DragEnter += (s, e) => e.Effect = e.Data.GetDataPresent(DataFormats.FileDrop) || e.Data.GetDataPresent(DataFormats.Bitmap) ? DragDropEffects.Copy : DragDropEffects.None;
            DragDrop += (s, e) =>
            {
                var files = e.Data.GetData(DataFormats.FileDrop) as string[];
                if (files != null && files.Length > 0) { c.LoadImage(files[0]); return; }
                var img = e.Data.GetData(DataFormats.Bitmap) as Image;
                if (img != null) c.LoadImage(img, "Dropped image");
            };
            KeyDown += (s, e) =>
            {
                if (e.Control && e.KeyCode == Keys.V && !(ActiveControl is TextBoxBase) && !(ActiveControl is NumericUpDown)) { c.PasteImage(); e.Handled = true; }
            };
            FormClosing += (s, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } };
            VisibleChanged += (s, e) => { if (Visible) { c.RefreshSite(); Refresh(); } };
            c.Changed += QueueRefresh;
            RefreshNow();
        }

        static ComboBox Combo(IEnumerable<string> items)
        {
            var cb = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 220 };
            cb.Items.AddRange(items.Cast<object>().ToArray());
            return cb;
        }

        void Change(Action<DrawSettings> edit)
        {
            if (refreshing) return;
            var s = c.Settings.Copy();
            edit(s);
            if (!s.Equals(c.Settings)) c.Settings = s;
        }

        public void ShowPanel()
        {
            if (!Visible) Show();
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Activate();
        }

        void QueueRefresh()
        {
            if (refreshQueued || !IsHandleCreated) { if (!IsHandleCreated) RefreshNow(); return; }
            refreshQueued = true;
            BeginInvoke((Action)(() => { refreshQueued = false; RefreshNow(); }));
        }

        void RefreshNow()
        {
            refreshing = true;
            try
            {
                var s = c.Settings;
                colors.Value = s.MaxColors;
                merge.Value = (int)Math.Round(s.MergeDistance);
                mergeValue.Text = s.MergeDistance <= 0 ? "Off" : "ΔE " + (int)Math.Round(s.MergeDistance);
                pen.Value = (decimal)s.PenSize;
                countdown.Value = s.CountdownSeconds;
                speed.SelectedIndex = Array.IndexOf(EnumNames.All<SpeedPreset>(), s.Speed);
                strokes.SelectedIndex = Array.IndexOf(EnumNames.All<StrokeStyle>(), s.StrokeStyle);
                order.SelectedIndex = Array.IndexOf(EnumNames.All<ColorOrder>(), s.Order);
                selection.SelectedIndex = Array.IndexOf(EnumNames.All<ColorSelectionMode>(), s.ColorSelection);
                selectionSpeed.SelectedIndex = Array.IndexOf(EnumNames.All<SelectionSpeed>(), s.SelectionSpeed);
                selectionSpeed.Enabled = s.ColorSelection == ColorSelectionMode.Automatic;
                pauseOnMove.Checked = s.PauseOnMouseMove;
                skipWhite.Checked = s.SkipNearWhite;
                penHelper.Text = c.PenHelperText;

                var problems = c.HotkeyProblems;
                statusRow.Text = problems.Count > 0 ? "Another app owns " + string.Join(", ", problems) + ": use the buttons here instead." : c.PhaseDescription;
                statusRow.ForeColor = problems.Count > 0 ? Ui.Warning : c.CanStart || c.IsRunning ? Ui.Good : Ui.Secondary;

                imageInfo.Text = c.ImageInfo ?? (c.IsLoadingImage ? "Loading…" : "Drop an image here, paste one (Ctrl+V), or choose a file.");
                canvasInfo.Text = c.CanvasDescription != null ? c.CanvasDescription + " · " + c.GridDescription
                    : "No canvas yet: open your drawing app at 100% zoom, then select the part of its canvas to paint.";
                targetInfo.Text = c.Canvas.HasValue ? "Drawing into: " + c.TargetDescription : "";
                var warning = c.TargetWarning;
                targetWarning.Visible = warning != null;
                targetWarning.Text = warning ?? "";

                learnStatus.Text = c.LearnStatusText;
                learnButton.Text = c.CurrentProfile != null ? "Learn Again…" : "Learn Color Picker…";
                learnButton.Enabled = c.CanLearn;
                forgetButton.Visible = c.CurrentProfile != null;
                forgetButton.Enabled = !c.IsRunning;

                preview.Image = c.PreviewImage;
                RebuildPalette();
                footer.Text = c.FooterText;
                message.Text = c.StatusMessage ?? "";
                message.Visible = !string.IsNullOrEmpty(c.StatusMessage);

                startButton.Text = c.IsRunning && !c.Phase.Is(PhaseKind.Learning) ? "Drawing… (" + c.PhaseDescription + ")" : "Start Drawing";
                startButton.Enabled = c.CanStart || (c.PromptWaiting && !c.Phase.Is(PhaseKind.Finished));
                selectButton.Enabled = !c.IsRunning;
            }
            finally { refreshing = false; }
        }

        int[] shownPalette = new int[0];
        HashSet<int> shownSkip = new HashSet<int>();
        RGB[] shownColors = new RGB[0];

        void RebuildPalette()
        {
            var order = c.OrderedPalette;
            var q = c.Result?.Quantized;
            var colorsNow = q?.Palette ?? new RGB[0];
            if (order.SequenceEqual(shownPalette) && shownSkip.SetEquals(c.SkipSet) && colorsNow.SequenceEqual(shownColors)) return;
            shownPalette = order; shownSkip = new HashSet<int>(c.SkipSet); shownColors = colorsNow;
            palette.SuspendLayout();
            foreach (Control ctl in palette.Controls.Cast<Control>().ToList()) ctl.Dispose();
            palette.Controls.Clear();
            int total = Math.Max(1, c.TotalOpaquePixels);
            foreach (var i in order)
            {
                var color = q.Palette[i];
                bool skipped = c.SkipSet.Contains(i);
                var cell = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(0, 0, 6, 6), Cursor = Cursors.Hand };
                var sw = new Swatch { Color = color, Size = new Size(44, 26), Crossed = skipped, Margin = new Padding(0), Cursor = Cursors.Hand };
                var hex = new Label { Text = color.HexNoHash, Font = Ui.Small, AutoSize = true, Margin = new Padding(0), ForeColor = skipped ? Ui.Secondary : SystemColors.ControlText };
                var pct = new Label { Text = Num.F(100.0 * q.Counts[i] / total, q.Counts[i] * 1000 / total < 10 ? 1 : 0) + "%", Font = Ui.Small, AutoSize = true, Margin = new Padding(0), ForeColor = Ui.Secondary };
                int index = i;
                EventHandler toggle = (s, e) => c.ToggleSkip(index);
                foreach (var ctl in new Control[] { cell, sw, hex, pct }) ctl.Click += toggle;
                var tip = new ToolTip();
                tip.SetToolTip(sw, ColorMath.ApproximateName(color) + (skipped ? " (skipped)" : ""));
                cell.Controls.Add(sw); cell.Controls.Add(hex); cell.Controls.Add(pct);
                palette.Controls.Add(cell);
            }
            palette.ResumeLayout(true);
        }

        /// <summary>The quantized preview, nearest-neighbor scaled, on a checkerboard where transparent.</summary>
        sealed class PreviewBox : Control
        {
            Bitmap image;
            public Bitmap Image { get => image; set { if (image != value) { image = value; Invalidate(); } } }

            public PreviewBox()
            {
                SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            }

            protected override void OnPaint(PaintEventArgs e)
            {
                var g = e.Graphics;
                g.Clear(SystemColors.Control);
                if (image == null)
                {
                    TextRenderer.DrawText(g, "No image", Ui.Body, ClientRectangle, Ui.Secondary, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                    return;
                }
                double k = Math.Min((double)Width / image.Width, (double)Height / image.Height);
                int w = Math.Max(1, (int)(image.Width * k)), h = Math.Max(1, (int)(image.Height * k));
                var r = new Rectangle((Width - w) / 2, (Height - h) / 2, w, h);
                using (var light = new SolidBrush(Color.FromArgb(235, 235, 235)))
                using (var dark = new SolidBrush(Color.FromArgb(205, 205, 205)))
                {
                    const int sq = 8;
                    for (int y = r.Top; y < r.Bottom; y += sq)
                        for (int x = r.Left; x < r.Right; x += sq)
                            g.FillRectangle(((x - r.Left) / sq + (y - r.Top) / sq) % 2 == 0 ? light : dark, x, y, Math.Min(sq, r.Right - x), Math.Min(sq, r.Bottom - y));
                }
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.DrawImage(image, r);
                using (var p = new Pen(Color.FromArgb(160, 160, 160))) g.DrawRectangle(p, r.X, r.Y, r.Width - 1, r.Height - 1);
            }
        }
    }

    /// <summary>A label that wraps to its parent's width.</summary>
    public class WrapLabel : Label
    {
        public WrapLabel() { AutoSize = false; UseMnemonic = false; }

        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Fit(); }
        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); Fit(); }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); Fit(); }

        bool fitting;
        void Fit()
        {
            if (fitting || Width <= 0) return;
            fitting = true;
            var size = TextRenderer.MeasureText(string.IsNullOrEmpty(Text) ? " " : Text, Font, new Size(Width, int.MaxValue), TextFormatFlags.WordBreak);
            Height = string.IsNullOrEmpty(Text) ? 0 : size.Height + 2;
            fitting = false;
        }
    }
}
