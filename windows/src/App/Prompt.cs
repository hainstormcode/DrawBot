using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;
using DrawBot.Core;

namespace DrawBot.App
{
    public enum PromptModeKind { Color, Paused, Obstructed, Done, LearnDemo, LearnVerify, LearnResult, LearnPalette }

    public sealed class PromptContent
    {
        public PromptModeKind Mode;
        /// <summary>Paused reason, obstruction message, done summary, result message or "recorded" summary.</summary>
        public string Detail = "";
        public bool Success;
        public RGB? Color;
        public int StepNumber, StepCount, StrokeCount, StrokesRemaining;
        public string Estimate = "";
        public string BrushHint = "";
        public string Title = "";
        public string AppName = "";
        public string Note = "";
        public bool CanAutoSelect;
        public List<RGB> Swatches = new List<RGB>();

        public bool IsLearn => Mode == PromptModeKind.LearnDemo || Mode == PromptModeKind.LearnVerify || Mode == PromptModeKind.LearnResult || Mode == PromptModeKind.LearnPalette;
    }

    public enum PromptAction { Proceed, CheckAgain, Skip, Stop, Close, AutoSelect, Redo, No, Retry, Palette }

    /// <summary>The floating prompt: never takes the focus, so pressing its buttons leaves the drawing app in front.</summary>
    public sealed class PromptController
    {
        readonly NoActivateForm form;
        readonly FlowLayoutPanel body;
        public Action<PromptAction> OnAction = _ => { };
        PromptContent content;
        RectD avoid;

        public PromptController()
        {
            form = new NoActivateForm
            {
                BackColor = Color.FromArgb(250, 250, 250), Padding = new Padding(1), Text = "DrawBot",
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            };
            form.Paint += (s, e) => { using (var p = new Pen(Color.FromArgb(170, 170, 170))) e.Graphics.DrawRectangle(p, 0, 0, form.Width - 1, form.Height - 1); };
            body = new FlowLayoutPanel
            {
                FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                Padding = new Padding(14, 12, 14, 12), Margin = new Padding(0), BackColor = Color.Transparent,
            };
            form.Controls.Add(body);
        }

        public bool IsVisible => form.Visible;
        public IntPtr Handle => form.Handle;

        public void Show(PromptContent c, RectD avoidRect)
        {
            content = c;
            avoid = avoidRect;
            Build();
            form.Location = Ui.PlaceOutside(avoid, form.Size);
            form.ShowNoActivate();
        }

        /// <summary>Refreshes the content in place (keeps the position).</summary>
        public void Update(PromptContent c)
        {
            if (!form.Visible) return;
            content = c;
            var loc = form.Location;
            Build();
            form.Location = loc;
        }

        public void Hide() { if (form.Visible) form.Hide(); }

        const int Width = 330;

        Label Text(string s, Font font = null, Color? color = null)
        {
            return new Label
            {
                Text = s, Font = font ?? Ui.Body, ForeColor = color ?? Color.FromArgb(30, 30, 30), AutoSize = true,
                MaximumSize = new Size(Width, 0), Margin = new Padding(0, 2, 0, 4), UseMnemonic = false,
            };
        }

        void Build()
        {
            form.SuspendLayout();
            body.SuspendLayout();
            foreach (Control c in body.Controls.Cast<Control>().ToList()) c.Dispose();
            body.Controls.Clear();
            var c0 = content;

            if (c0.Mode == PromptModeKind.Done)
            {
                body.Controls.Add(Text("Done!", Ui.Title));
                body.Controls.Add(Text(c0.Detail));
                body.Controls.Add(Buttons(Btn("Close", PromptAction.Close, true)));
                Finish();
                return;
            }
            if (c0.Mode == PromptModeKind.LearnResult)
            {
                body.Controls.Add(Text(c0.Title.Length > 0 ? c0.Title : "Color Learn", Ui.Bold, Ui.Secondary));
                body.Controls.Add(Text(c0.Success ? "Learned!" : "That didn't work", Ui.Title, c0.Success ? Ui.Good : Ui.Warning));
                body.Controls.Add(Text(c0.Detail));
                if (c0.Swatches.Count > 0) body.Controls.Add(SwatchRow(c0.Swatches));
                body.Controls.Add(c0.Success ? Buttons(Btn("Close", PromptAction.Close, true)) : Buttons(Btn("Cancel", PromptAction.Stop), Btn("Start over", PromptAction.Redo, true)));
                Finish();
                return;
            }

            if (c0.IsLearn)
            {
                body.Controls.Add(Text(c0.Title, Ui.Bold, Ui.Secondary));
            }
            else if (c0.StepCount > 0)
            {
                body.Controls.Add(Text("Color " + c0.StepNumber + " of " + c0.StepCount, Ui.Bold, Ui.Secondary));
            }
            if (c0.Mode == PromptModeKind.Paused) body.Controls.Add(Text("Paused — " + c0.Detail, Ui.Bold, Ui.Warning));
            if (c0.Mode == PromptModeKind.Obstructed) body.Controls.Add(Text(c0.Detail, Ui.Bold, Ui.Warning));

            if (c0.Color.HasValue) body.Controls.Add(ColorBlock(c0.Color.Value));

            switch (c0.Mode)
            {
                case PromptModeKind.Color:
                    body.Controls.Add(Text("Select this color in your drawing app, then press Continue (" + Ui.ContinueKey + ")."));
                    if (c0.BrushHint.Length > 0) body.Controls.Add(Text(c0.BrushHint, Ui.Small, Ui.Secondary));
                    break;
                case PromptModeKind.LearnDemo:
                    body.Controls.Add(Text("Select this color in " + c0.AppName + " the way you normally do. DrawBot is watching your clicks and typing."));
                    body.Controls.Add(Text("If the color picker is a popup or dialog, open it, choose the color, and close it again before pressing Done, every time. Typing the color's values (the hex code, or R, G and B) is the most reliable; pasting the hex from Copy hex counts as typing. Clicking works too: get as close as you can. Do it the same way each time, and don't paint on the canvas.", Ui.Small, Ui.Secondary));
                    body.Controls.Add(Text(c0.Detail, Ui.Small, Ui.Secondary));
                    body.Controls.Add(Text("When the color is selected, press Done (" + Ui.ContinueKey + ")."));
                    body.Controls.Add(Text("No color picker in " + c0.AppName + ", just a few preset color buttons? Click Preset colors… instead.", Ui.Small, Ui.Secondary));
                    break;
                case PromptModeKind.LearnPalette:
                    body.Controls.Add(Text("Click every preset color button in " + c0.AppName + " once, one after another, about a second apart. Click near the middle of each."));
                    body.Controls.Add(Text("DrawBot reads each button's color from the spot you click. When drawing, it moves the picture's colors to the closest preset colors. Don't move or scroll the app while doing this.", Ui.Small, Ui.Secondary));
                    body.Controls.Add(Text(c0.Detail, Ui.Small, Ui.Secondary));
                    if (c0.Swatches.Count > 0) body.Controls.Add(SwatchRow(c0.Swatches));
                    body.Controls.Add(Text("When you've clicked them all, press Done (" + Ui.ContinueKey + ")."));
                    break;
                case PromptModeKind.LearnVerify:
                    body.Controls.Add(Text("DrawBot just tried to select this color by itself. Is it selected in " + c0.AppName + " now, with the color picker closed again (nothing covering the canvas)?"));
                    body.Controls.Add(Text("Compare it with the swatch above carefully: a slightly different shade counts as No. If you answer No, DrawBot asks you to select it yourself once more, or suggests another way to teach it.", Ui.Small, Ui.Secondary));
                    break;
                case PromptModeKind.Paused:
                    body.Controls.Add(Text("Make sure this color is still selected, then press Resume (" + Ui.ContinueKey + ")."));
                    if (c0.StrokesRemaining > 0) body.Controls.Add(Text(c0.StrokesRemaining + " strokes left for this color.", Ui.Small, Ui.Secondary));
                    break;
                case PromptModeKind.Obstructed:
                    body.Controls.Add(Text("Windows over the canvas would receive the drawing clicks.", Ui.Small, Ui.Secondary));
                    break;
            }
            if (c0.Note.Length > 0) body.Controls.Add(Text(c0.Note, Ui.Small, Ui.Warning));

            switch (c0.Mode)
            {
                case PromptModeKind.Color:
                    {
                        var list = new List<Button> { Btn("Stop", PromptAction.Stop), Btn("Skip this color", PromptAction.Skip) };
                        if (c0.CanAutoSelect) list.Add(Btn("Select for me", PromptAction.AutoSelect));
                        list.Add(Btn("Continue", PromptAction.Proceed, true));
                        body.Controls.Add(Buttons(list.ToArray()));
                        break;
                    }
                case PromptModeKind.LearnDemo:
                    body.Controls.Add(Buttons(Btn("Cancel", PromptAction.Stop), Btn("Preset colors…", PromptAction.Palette), Btn("Start over", PromptAction.Redo), Btn("Done", PromptAction.Proceed, true)));
                    break;
                case PromptModeKind.LearnPalette:
                    body.Controls.Add(Buttons(Btn("Cancel", PromptAction.Stop), Btn("Start over", PromptAction.Redo), Btn("Done", PromptAction.Proceed, true)));
                    break;
                case PromptModeKind.LearnVerify:
                    body.Controls.Add(Buttons(Btn("Cancel", PromptAction.Stop), Btn("Try again", PromptAction.Retry), Btn("No", PromptAction.No), Btn("Yes, it worked", PromptAction.Proceed, true)));
                    break;
                case PromptModeKind.Paused:
                    body.Controls.Add(Buttons(Btn("Stop", PromptAction.Stop), Btn("Skip rest of color", PromptAction.Skip), Btn("Resume", PromptAction.Proceed, true)));
                    break;
                case PromptModeKind.Obstructed:
                    body.Controls.Add(Buttons(Btn("Stop", PromptAction.Stop), Btn("Draw anyway", PromptAction.Proceed), Btn("Check again", PromptAction.CheckAgain, true)));
                    break;
            }
            Finish();
        }

        void Finish()
        {
            body.ResumeLayout(true);
            form.ResumeLayout(true);
            form.PerformLayout();
        }

        Control ColorBlock(RGB c)
        {
            var row = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true, WrapContents = false, Margin = new Padding(0, 4, 0, 6) };
            var sw = new Swatch { Color = c, Size = new Size(64, 64), Margin = new Padding(0, 0, 12, 0) };
            row.Controls.Add(sw);
            var info = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(0) };
            var hexRow = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true, WrapContents = false, Margin = new Padding(0) };
            hexRow.Controls.Add(new Label { Text = c.Hex, Font = new Font("Consolas", 13f, FontStyle.Bold), AutoSize = true, Margin = new Padding(0, 3, 6, 0) });
            var copy = new Button { Text = "Copy hex", AutoSize = true, FlatStyle = FlatStyle.System, Margin = new Padding(0) };
            copy.Click += (s, e) => { try { Clipboard.SetText(c.HexNoHash); copy.Text = "Copied"; } catch (Exception) { } };
            hexRow.Controls.Add(copy);
            info.Controls.Add(hexRow);
            double h, sat, v;
            ColorMath.Hsb(c, out h, out sat, out v);
            var hsl = ColorMath.Hsl(c);
            info.Controls.Add(new Label { Text = "RGB " + c.R + ", " + c.G + ", " + c.B, Font = Ui.Mono, AutoSize = true, Margin = new Padding(0, 2, 0, 0) });
            info.Controls.Add(new Label { Text = "HSB " + (int)Num.Round(h) + "°, " + (int)Num.Round(sat) + "%, " + (int)Num.Round(v) + "%", Font = Ui.Mono, AutoSize = true, Margin = new Padding(0) });
            info.Controls.Add(new Label { Text = "HSL " + (int)Num.Round(hsl[0]) + "°, " + (int)Num.Round(hsl[1]) + "%, " + (int)Num.Round(hsl[2]) + "%", Font = Ui.Mono, AutoSize = true, Margin = new Padding(0) });
            var extra = ColorMath.ApproximateName(c);
            if (content.StrokeCount > 0) extra += " · " + content.StrokeCount + " strokes";
            if (content.Estimate.Length > 0) extra += " · " + content.Estimate;
            info.Controls.Add(new Label { Text = extra, Font = Ui.Small, ForeColor = Ui.Secondary, AutoSize = true, Margin = new Padding(0, 2, 0, 0) });
            row.Controls.Add(info);
            return row;
        }

        Control SwatchRow(List<RGB> colors)
        {
            var row = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true, WrapContents = true, MaximumSize = new Size(Width, 0), Margin = new Padding(0, 4, 0, 4) };
            foreach (var c in colors) row.Controls.Add(new Swatch { Color = c, Size = new Size(22, 22), Margin = new Padding(0, 0, 4, 4) });
            return row;
        }

        Button Btn(string title, PromptAction action, bool primary = false)
        {
            var b = new Button { Text = title, AutoSize = true, FlatStyle = FlatStyle.System, Margin = new Padding(6, 0, 0, 0), Font = primary ? Ui.Bold : Ui.Body };
            b.Click += (s, e) => OnAction(action);
            return b;
        }

        Control Buttons(params Button[] buttons)
        {
            var row = new FlowLayoutPanel
            {
                FlowDirection = FlowDirection.RightToLeft, AutoSize = true, WrapContents = true, MinimumSize = new Size(Width, 0),
                MaximumSize = new Size(Width, 0), Margin = new Padding(0, 10, 0, 0),
            };
            foreach (var b in buttons.Reverse()) row.Controls.Add(b);
            return row;
        }
    }

    public enum HudMode { Preparing, Countdown, Drawing, SelectingColor, LearnTrying }

    public sealed class HudContent
    {
        public HudMode Mode;
        public int Countdown;
        public double Fraction;
        public RGB? Color;
        public int StepNumber, StepCount;
    }

    /// <summary>The small click-through progress display, placed away from the canvas.</summary>
    public sealed class HudController
    {
        readonly NoActivateForm form;
        readonly Swatch swatch;
        readonly Label label;

        public HudController()
        {
            form = new NoActivateForm { ClickThrough = true, BackColor = Color.FromArgb(32, 32, 36), Size = new Size(300, 44), Opacity = 0.94 };
            swatch = new Swatch { Location = new Point(10, 10), Size = new Size(24, 24) };
            label = new Label { Location = new Point(44, 0), Size = new Size(250, 44), ForeColor = Color.White, Font = Ui.Body, TextAlign = ContentAlignment.MiddleLeft, AutoEllipsis = true };
            form.Controls.Add(swatch);
            form.Controls.Add(label);
        }

        public bool IsVisible => form.Visible;

        public void Show(HudContent c, RectD canvas)
        {
            swatch.Visible = c.Color.HasValue;
            if (c.Color.HasValue) swatch.Color = c.Color.Value;
            string step = c.StepCount > 0 ? " " + c.StepNumber + "/" + c.StepCount : "";
            switch (c.Mode)
            {
                case HudMode.Preparing: label.Text = "Getting ready to draw color" + step + "…"; break;
                case HudMode.Countdown: label.Text = c.Countdown > 0 ? "Drawing color" + step + " in " + c.Countdown + "… · Esc to cancel" : "Let go of Ctrl, Alt and Shift…"; break;
                case HudMode.Drawing: label.Text = "Drawing color" + step + " · " + (int)(c.Fraction * 100) + "% · Esc to stop"; break;
                case HudMode.SelectingColor: label.Text = "Selecting color" + step + "… · Esc to stop"; break;
                case HudMode.LearnTrying: label.Text = "DrawBot is trying the color picker… · Esc to stop"; break;
            }
            var screen = Win.Displays.ScreenFor(canvas).Bounds;
            // The corner of the canvas's screen furthest from the canvas.
            var corners = new[]
            {
                new Point(screen.Right - form.Width - 12, screen.Top + 12), new Point(screen.Left + 12, screen.Top + 12),
                new Point(screen.Right - form.Width - 12, screen.Bottom - form.Height - 60), new Point(screen.Left + 12, screen.Bottom - form.Height - 60),
            };
            var cc = canvas.Center;
            var best = corners.OrderByDescending(p => (p.X + form.Width / 2 - cc.X) * (p.X + form.Width / 2 - cc.X) + (p.Y + form.Height / 2 - cc.Y) * (p.Y + form.Height / 2 - cc.Y)).First();
            if (canvas.Contains(new PointD(best.X + 1, best.Y + 1)) && canvas.Contains(new PointD(best.X + form.Width - 1, best.Y + form.Height - 1)))
                best = corners[0];
            form.Location = best;
            form.ShowNoActivate();
        }

        public void Hide() { if (form.Visible) form.Hide(); }
    }
}
