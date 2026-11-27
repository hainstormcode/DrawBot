using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;
using DrawBot.Core;
using DrawBot.Win;

namespace DrawBot.App
{
    /// <summary>
    /// End-to-end checks that drive the real mouse on this machine:
    ///   --selftest        draws a test picture into the Test Canvas and compares it cell by cell;
    ///   --selftest-learn  teaches Color Learn the Test Canvas's picker with simulated clicks, checks
    ///                     DrawBot's own try, then draws automatically and compares the colors;
    ///   --selftest-paint  draws a one-color doodle into Microsoft Paint and checks a screenshot.
    /// Options: --speed careful|normal|fast|ludicrous, --out DIR (where images and the report go).
    /// Hands off the mouse while it runs (moving it pauses the drawing).
    /// </summary>
    public static class SelfTest
    {
        static string outDir;
        static bool virtualInput;
        static readonly List<string> log = new List<string>();
        static readonly Stopwatch clock = Stopwatch.StartNew();

        static void Log(string s)
        {
            var line = clock.Elapsed.TotalSeconds.ToString("F1").PadLeft(6) + "s  " + s;
            log.Add(line);
            Console.WriteLine(line);
            try { File.AppendAllText(Path.Combine(outDir, "selftest.log"), line + Environment.NewLine); } catch (Exception) { }
        }

        public static int Run(string[] args)
        {
            AttachConsole(-1);
            string Arg(string name) { int i = Array.IndexOf(args, name); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
            outDir = Arg("--out") ?? Path.Combine(Path.GetTempPath(), "DrawBotSelfTest");
            Directory.CreateDirectory(outDir);
            try { File.Delete(Path.Combine(outDir, "selftest.log")); } catch (Exception) { }
            var data = Path.Combine(outDir, "data");
            if (Directory.Exists(data)) try { Directory.Delete(data, true); } catch (Exception) { }
            Environment.SetEnvironmentVariable("DRAWBOT_DATA_DIR", data);
            SpeedPreset speed;
            if (!Enum.TryParse(Arg("--speed") ?? "Normal", true, out speed)) speed = SpeedPreset.Normal;
            virtualInput = args.Contains("--virtual");
            if (virtualInput) VirtualInput.Install();
            else if (!InputDesktop.IsAvailable())
            {
                Log("The Windows desktop is locked or disconnected, so real mouse input can't be tested now. Unlock it, or run with --virtual.");
                Log("FAIL (7)");
                return 7;
            }
            Log("input: " + (virtualInput ? "virtual (window messages)" : "real (SendInput)"));

            int code = 1;
            var ctx = new ApplicationContext();
            Ui.After(0.1, async () =>
            {
                try
                {
                    if (args.Contains("--selftest-ui")) code = await UiTest();
                    else if (args.Contains("--selftest-learn")) code = await LearnTest(speed);
                    else if (args.Contains("--selftest-paint")) code = await PaintTest(speed);
                    else code = await DrawTest(speed);
                }
                catch (Exception e) { Log("CRASH: " + e); code = 2; }
                Log(code == 0 ? "PASS" : "FAIL (" + code + ")");
                ctx.ExitThread();
            });
            Application.Run(ctx);
            return code;
        }

        [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);

        // MARK: Shared steps

        static AppController MakeController(SpeedPreset speed, int colors, double pen, ColorSelectionMode mode)
        {
            var c = new AppController();
            var s = c.Settings.Copy();
            s.MaxColors = colors; s.MergeDistance = 6; s.PenSize = pen; s.Speed = speed; s.CountdownSeconds = 0;
            s.PauseOnMouseMove = true; s.SkipNearWhite = true; s.ColorSelection = mode; s.StrokeStyle = StrokeStyle.Paths;
            s.SelectionSpeed = SelectionSpeed.Fast;
            c.Settings = s;
            return c;
        }

        /// <summary>A crisp test picture: white paper with a red disc, a blue bar, a green triangle and dark lines.</summary>
        public static RGBAImage TestPicture(int w = 240, int h = 160)
        {
            var img = new RGBAImage(w, h);
            Action<int, int, RGB> set = (x, y, c) => { int i = (y * w + x) * 4; img.Data[i] = c.R; img.Data[i + 1] = c.G; img.Data[i + 2] = c.B; img.Data[i + 3] = 255; };
            var white = new RGB(255, 255, 255); var red = new RGB(220, 40, 40); var blue = new RGB(40, 80, 210);
            var green = new RGB(40, 170, 70); var ink = new RGB(30, 30, 30);
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    var c = white;
                    double dx = x - w * 0.27, dy = y - h * 0.45;
                    if (dx * dx + dy * dy < (h * 0.28) * (h * 0.28)) c = red;
                    if (x > w * 0.55 && x < w * 0.92 && y > h * 0.15 && y < h * 0.38) c = blue;
                    double tx = (x - w * 0.55) / (w * 0.37), ty = (y - h * 0.5) / (h * 0.4);
                    if (ty >= 0 && ty <= 1 && tx >= 0.5 - ty / 2 && tx <= 0.5 + ty / 2) c = green;
                    if ((y > h * 0.88 && y < h * 0.93 && x > w * 0.08 && x < w * 0.9) || (x > w * 0.48 && x < w * 0.51 && y > h * 0.1 && y < h * 0.85)) c = ink;
                    set(x, y, c);
                }
            return img;
        }

        static async Task<bool> WaitFor(Func<bool> condition, double seconds, int pollMs = 50)
        {
            var end = DateTime.UtcNow.AddSeconds(seconds);
            while (DateTime.UtcNow < end)
            {
                if (condition()) return true;
                await Task.Delay(pollMs);
            }
            return condition();
        }

        static async Task<TestCanvasForm> OpenCanvas(AppController c)
        {
            c.OpenTestCanvas();
            var tc = c.TestCanvasWindow;
            // Raise it above whatever launched the test (Windows may refuse a background process the
            // foreground), then drop topmost: a topmost window counts as floating, like DrawBot's prompts,
            // and those are never a drawing target.
            tc.TopMost = true;
            tc.TopMost = false;
            tc.Activate();
            var wa = Screen.PrimaryScreen.WorkingArea;
            // On the right of the screen: DrawBot's prompts then go to the left of the canvas,
            // clear of the Test Canvas's color picker (a user would drag a prompt out of the way).
            tc.Size = new Size(Math.Min(1010, wa.Width - 40), Math.Min(640, wa.Height - 40));
            tc.Location = new Point(wa.Right - tc.Width - 20, wa.Top + 20);
            tc.Canvas.Clear();
            await Task.Delay(400);
            var center = tc.CanvasScreenRect.Center;
            if (!await WaitFor(() => WindowInspector.TargetWindow(new RectD(center.X - 5, center.Y - 5, 10, 10))?.Handle == tc.Handle, 5))
                Log("warning: Windows doesn't list the Test Canvas as the front window yet");
            return tc;
        }

        static async Task<bool> RunToEnd(AppController c, double timeout, bool answerPrompts)
        {
            var end = DateTime.UtcNow.AddSeconds(timeout);
            int obstructed = 0, paused = 0;
            Phase lastSeen = null;
            while (DateTime.UtcNow < end)
            {
                var p = c.Phase;
                if (!p.Equals(lastSeen))
                {
                    if (lastSeen == null || p.Kind != lastSeen.Kind || p.Step != lastSeen.Step) Log("phase: " + c.PhaseDescription + (p.Message.Length > 0 ? " — " + p.Message : ""));
                    lastSeen = p;
                }
                if (p.Is(PhaseKind.Finished)) return true;
                if (p.Is(PhaseKind.Ready)) { Log("run ended: " + c.StatusMessage); return false; }
                if (p.Is(PhaseKind.AwaitingColor))
                {
                    if (!answerPrompts) { Log("automatic selection fell back to the prompt"); return false; }
                    await Task.Delay(150);
                    c.ContinueFromHotkey();
                }
                else if (p.Is(PhaseKind.Paused))
                {
                    if (++paused > 5) { Log("paused too often"); return false; }
                    await Task.Delay(300);
                    c.ContinueFromHotkey();
                }
                else if (p.Is(PhaseKind.Obstructed))
                {
                    if (++obstructed > 3) { Log("canvas stays obstructed: " + p.Message); return false; }
                    await Task.Delay(500);
                    c.ContinueFromHotkey();
                }
                await Task.Delay(50);
            }
            Log("timed out in phase " + c.PhaseDescription);
            return false;
        }

        /// <summary>Compares every cell's center in the drawing with the color DrawBot meant to paint there.</summary>
        static double Compare(QuantizedImage q, HashSet<int> skip, GridLayout layout, Func<PointD, RGB> pixelAt, double tolerance, string name,
                              Func<int, RGB> expectedColor = null)
        {
            int painted = 0, correct = 0, blank = 0, stray = 0;
            var wrong = new Dictionary<string, int>();
            for (int row = 0; row < layout.Rows; row++)
                for (int col = 0; col < layout.Columns; col++)
                {
                    int l = q.Labels[row * q.Width + col];
                    var actual = pixelAt(layout.CellCenter(col, row));
                    if (l < 0 || skip.Contains(l))
                    {
                        blank++;
                        if (ColorMath.DeltaE(actual, new RGB(255, 255, 255)) > 25) stray++;
                        continue;
                    }
                    painted++;
                    var expected = expectedColor != null ? expectedColor(l) : q.Palette[l];
                    if (ColorMath.DeltaE(actual, expected) <= tolerance) correct++;
                    else
                    {
                        var k = expected.Hex + "→" + actual.Hex;
                        wrong[k] = wrong.TryGetValue(k, out var n) ? n + 1 : 1;
                    }
                }
            double coverage = painted == 0 ? 0 : 100.0 * correct / painted;
            Log(name + ": " + correct + "/" + painted + " painted cells correct (" + coverage.ToString("F2") + "%), " + stray + "/" + blank + " blank cells touched");
            foreach (var kv in wrong.OrderByDescending(kv => kv.Value).Take(6)) Log("   mismatch " + kv.Key + " ×" + kv.Value);
            return coverage;
        }

        static void LogWindowsAt(PointD p, TestCanvasForm tc)
        {
            Log("test canvas handle " + tc.Handle + ", visible " + tc.Visible + ", bounds " + tc.Bounds);
            foreach (var w in WindowInspector.OnScreenWindows().Where(w => w.Bounds.Contains(p)))
                Log("   window at center: " + w.Handle + " pid " + w.Pid + " " + w);
        }

        static void Save(Bitmap bmp, string file) { try { bmp.Save(Path.Combine(outDir, file), ImageFormat.Png); } catch (Exception) { } }

        static Func<PointD, RGB> CanvasPixels(TestCanvasForm tc, Bitmap snap)
        {
            var origin = tc.CanvasScreenRect;
            return p =>
            {
                int x = (int)Math.Floor(p.X - origin.X), y = (int)Math.Floor(p.Y - origin.Y);
                if (x < 0 || y < 0 || x >= snap.Width || y >= snap.Height) return new RGB(255, 255, 255);
                return snap.GetPixel(x, y).ToRGB();
            };
        }

        // MARK: Test Canvas, colors selected "by the user"

        static async Task<int> DrawTest(SpeedPreset speed)
        {
            Log("Self test: draw into the Test Canvas at " + speed.DisplayName() + " speed. Hands off the mouse.");
            var c = MakeController(speed, 5, 4, ColorSelectionMode.Manual);
            var tc = await OpenCanvas(c);
            var canvas = tc.CanvasScreenRect.Inset(24, 24);
            c.LoadImageForTesting(TestPicture(), "self test picture");
            c.SetCanvasForTesting(canvas);
            Log("canvas " + canvas + ", target: " + c.TargetDescription);
            if (c.Target.Kind != TargetKind.TestCanvas) { Log("the canvas is not on the Test Canvas"); LogWindowsAt(canvas.Center, tc); return 3; }
            if (!await WaitFor(() => c.ResultIsCurrent && !c.IsProcessing, 20)) { Log("processing did not finish"); return 4; }
            var q = c.Result.Quantized;
            Log("palette: " + string.Join(" ", q.Palette.Select(x => x.Hex)) + "; skipped: " + string.Join(" ", c.SkipSet.Select(i => q.Palette[i].Hex)));
            Log(c.FooterText);
            Save(c.PreviewImage, "expected.png");
            var t0 = DateTime.UtcNow;
            c.Start();
            bool ok = await RunToEnd(c, 300, true);
            Log("drawing took " + (DateTime.UtcNow - t0).TotalSeconds.ToString("F1") + " s; " + c.LastRunSummary);
            await Task.Delay(300);
            using (var snap = tc.Canvas.Snapshot())
            {
                Save(snap, "actual.png");
                double coverage = Compare(q, c.SkipSet, new GridLayout(canvas, c.Settings.PenSize), CanvasPixels(tc, snap), 8, "Test Canvas");
                if (!ok) return 5;
                return coverage >= 99 ? 0 : 6;
            }
        }

        // MARK: Color Learn on the Test Canvas's picker

        /// <summary>Real (non-DrawBot) mouse input, as a user's would be.</summary>
        static void UserClick(PointD p)
        {
            if (virtualInput)
            {
                // What the hooks would see, then what the window would get.
                GlobalInputHook.Simulate(new HookEvent { Message = Native.WM_LBUTTONDOWN, Point = p, Time = PreciseClock.Now() });
                VirtualInput.Mouse(Native.WM_LBUTTONDOWN, p);
                System.Threading.Thread.Sleep(60);
                GlobalInputHook.Simulate(new HookEvent { Message = Native.WM_LBUTTONUP, Point = p, Time = PreciseClock.Now() });
                VirtualInput.Mouse(Native.WM_LBUTTONUP, p);
                return;
            }
            Native.SetCursorPos((int)p.X, (int)p.Y);
            Send(Native.MOUSEEVENTF_MOVE | Native.MOUSEEVENTF_ABSOLUTE | Native.MOUSEEVENTF_VIRTUALDESK, p);
            Send(Native.MOUSEEVENTF_LEFTDOWN | Native.MOUSEEVENTF_ABSOLUTE | Native.MOUSEEVENTF_VIRTUALDESK | Native.MOUSEEVENTF_MOVE, p);
            System.Threading.Thread.Sleep(60);
            Send(Native.MOUSEEVENTF_LEFTUP | Native.MOUSEEVENTF_ABSOLUTE | Native.MOUSEEVENTF_VIRTUALDESK | Native.MOUSEEVENTF_MOVE, p);
        }

        static void Send(uint flags, PointD p)
        {
            int nx, ny;
            ScreenSpace.Absolute(p, out nx, out ny);
            var input = new Native.INPUT { type = Native.INPUT_MOUSE };
            input.u.mi = new Native.MOUSEINPUT { dx = nx, dy = ny, dwFlags = flags };
            Native.SendInput(1, new[] { input }, Marshal.SizeOf(typeof(Native.INPUT)));
        }

        static PointD SquarePoint(TestCanvasForm tc, RGB c)
        {
            var o = tc.Picker.PointToScreen(Point.Empty);
            double h, s, v; ColorMath.Hsb(c, out h, out s, out v);
            return new PointD(o.X + s / 100 * MiniColorPicker.Side, o.Y + (1 - v / 100) * MiniColorPicker.Side);
        }

        static PointD StripPoint(TestCanvasForm tc, RGB c)
        {
            var o = tc.Picker.PointToScreen(Point.Empty);
            double h, s, v; ColorMath.Hsb(c, out h, out s, out v);
            return new PointD(o.X + MiniColorPicker.Side + MiniColorPicker.Gap + MiniColorPicker.StripWidth / 2.0, o.Y + h / 360 * MiniColorPicker.Side);
        }

        static async Task Demonstrate(TestCanvasForm tc, RGB color)
        {
            // Like a user: hue first, then the square, a little imprecisely.
            var strip = StripPoint(tc, color); strip.Y += 1;
            var square = SquarePoint(tc, color); square.X -= 1; square.Y += 1;
            UserClick(strip);
            await Task.Delay(700);
            UserClick(square);
            await Task.Delay(700);
        }

        static async Task<int> LearnTest(SpeedPreset speed)
        {
            Log("Self test: teach Color Learn the Test Canvas's picker, then draw with automatic color selection. Hands off the mouse.");
            var c = MakeController(speed, 4, 5, ColorSelectionMode.Manual);
            var tc = await OpenCanvas(c);
            var canvas = tc.CanvasScreenRect.Inset(24, 24);
            c.LoadImageForTesting(TestPicture(), "self test picture");
            c.SetCanvasForTesting(canvas);
            if (c.Target.Kind != TargetKind.TestCanvas) { Log("the canvas is not on the Test Canvas"); LogWindowsAt(canvas.Center, tc); return 3; }
            tc.Picker.SetColor(new RGB(0, 0, 0), true);

            c.LearnColorPicker();
            if (!c.Phase.Is(PhaseKind.Learning)) { Log("the lesson did not start: " + c.StatusMessage); return 10; }
            await Task.Delay(900);
            for (int d = 0; d < 2; d++)
            {
                var color = ColorLearner.DemoColors[d];
                Log("demonstrating " + color.Hex);
                await Demonstrate(tc, color);
                Log("  the picker shows " + tc.PickedColor.Hex);
                c.ContinueFromHotkey();   // Done
                await Task.Delay(1000);
            }
            // DrawBot now tries a test color by itself.
            var test = ColorLearner.TestColors[0];
            bool tried = await WaitFor(() => ColorMath.DeltaE(tc.PickedColor, test) < 6, 15);
            Log("DrawBot's own try: wanted " + test.Hex + ", the picker shows " + tc.PickedColor.Hex + " (ΔE " + ColorMath.DeltaE(tc.PickedColor, test).ToString("F1") + ")");
            if (!tried) { c.Stop(); return 11; }
            await Task.Delay(800);
            c.ContinueFromHotkey();   // Yes, it worked
            await Task.Delay(500);
            c.ContinueFromHotkey();   // Close
            if (!await WaitFor(() => c.Phase.Is(PhaseKind.Ready), 5)) { Log("the lesson did not end"); return 12; }
            var profile = c.CurrentProfile;
            if (profile == null) { Log("no profile was saved"); return 13; }
            Log("learned: " + profile.Summary + " [" + profile.HypothesisKey + "]");
            if (c.Settings.ColorSelection != ColorSelectionMode.Automatic) { Log("color selection did not switch to automatic"); return 14; }

            if (!await WaitFor(() => c.ResultIsCurrent && !c.IsProcessing, 20)) { Log("processing did not finish"); return 4; }
            var q = c.Result.Quantized;
            Log(c.FooterText);
            var t0 = DateTime.UtcNow;
            c.Start();
            bool ok = await RunToEnd(c, 400, false);
            Log("drawing took " + (DateTime.UtcNow - t0).TotalSeconds.ToString("F1") + " s; " + c.LastRunSummary);
            await Task.Delay(300);
            using (var snap = tc.Canvas.Snapshot())
            {
                Save(snap, "actual-learn.png");
                // A click-learned picker is only as precise as its pixels: allow a small color error.
                double coverage = Compare(q, c.SkipSet, new GridLayout(canvas, c.Settings.PenSize), CanvasPixels(tc, snap), 10, "Color Learn drawing");
                if (!ok) return 5;
                return coverage >= 98 ? 0 : 6;
            }
        }

        // MARK: Windows rendered to images (works without a desktop)

        static async Task<int> UiTest()
        {
            var c = MakeController(SpeedPreset.Normal, 5, 4, ColorSelectionMode.Manual);
            var panel = new ControlPanel(c);
            c.ControlPanel = panel;
            panel.Show();
            var tc = await OpenCanvas(c);
            c.LoadImageForTesting(TestPicture(), "self test picture.png");
            c.SetCanvasForTesting(tc.CanvasScreenRect.Inset(24, 24));
            await WaitFor(() => c.ResultIsCurrent && !c.IsProcessing && c.PreviewImage != null, 20);
            await Task.Delay(500);
            Action<Control, string> shot = (ctl, file) =>
            {
                using (var bmp = new Bitmap(Math.Max(1, ctl.Width), Math.Max(1, ctl.Height)))
                {
                    ctl.DrawToBitmap(bmp, new Rectangle(0, 0, ctl.Width, ctl.Height));
                    Save(bmp, file);
                }
                Log("rendered " + file + " (" + ctl.Width + " × " + ctl.Height + ")");
            };
            shot(panel, "ui-panel.png");
            shot(tc, "ui-testcanvas.png");
            var prompt = new PromptController();
            prompt.Show(new PromptContent { Mode = PromptModeKind.Color, Color = new RGB(220, 41, 41), StepNumber = 2, StepCount = 4, StrokeCount = 3, Estimate = "≈ 7 s", BrushHint = "Brush: hard, round, 100% opacity, ≈ 4 px" }, tc.CanvasScreenRect);
            await Task.Delay(300);
            var form = Application.OpenForms.Cast<Form>().First(f => f is NoActivateForm && f.Visible && !((NoActivateForm)f).ClickThrough);
            shot(form, "ui-prompt.png");
            Log(c.FooterText);
            return 0;
        }

        // MARK: Microsoft Paint

        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);

        static async Task<int> PaintTest(SpeedPreset speed)
        {
            Log("Self test: draw a one-color doodle into Microsoft Paint. Hands off the mouse.");
            var exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "mspaint.exe");
            if (!File.Exists(exe)) { Log("mspaint.exe not found"); return 20; }
            var proc = Process.Start(exe);
            IntPtr main = IntPtr.Zero, view = IntPtr.Zero;
            await WaitFor(() =>
            {
                try { proc.Refresh(); } catch (Exception) { }
                main = FindWindowEx(IntPtr.Zero, IntPtr.Zero, "MSPaintApp", null);
                if (main == IntPtr.Zero) return false;
                var frame = FindWindowEx(main, IntPtr.Zero, "MSPaintView", null);
                view = frame != IntPtr.Zero ? FindWindowEx(frame, IntPtr.Zero, null, null) : IntPtr.Zero;
                return view != IntPtr.Zero && Native.IsWindowVisible(main);
            }, 20, 200);
            if (view == IntPtr.Zero) { Log("couldn't find Paint's canvas (is this the classic Paint?)"); return 21; }
            Native.ShowWindow(main, 3);   // maximize so the canvas has room
            await Task.Delay(1200);
            Native.RECT r;
            Native.GetWindowRect(view, out r);
            var canvas = new RectD(r.Left + 10, r.Top + 10, Math.Min(500, r.Right - r.Left - 30), Math.Min(330, r.Bottom - r.Top - 30));
            Log("Paint canvas at " + canvas);
            var c = MakeController(speed, 1, 3, ColorSelectionMode.Manual);
            c.LoadImageForTesting(TestPicture(300, 200), "self test picture");
            c.SetCanvasForTesting(canvas);
            Log("target: " + c.TargetDescription);
            if (c.Target.Kind != TargetKind.App) { Log("Paint is not under the canvas"); return 22; }
            if (!await WaitFor(() => c.ResultIsCurrent && !c.IsProcessing, 20)) return 4;
            var q = c.Result.Quantized;
            Log(c.FooterText + "; ink " + q.Palette[0].Hex + " (Paint's default color is black)");
            var t0 = DateTime.UtcNow;
            c.Start();
            bool ok = await RunToEnd(c, 300, true);
            Log("drawing took " + (DateTime.UtcNow - t0).TotalSeconds.ToString("F1") + " s; " + c.LastRunSummary);
            await Task.Delay(600);
            var shot = ScreenSampler.Capture(canvas);
            using (var bmp = ImageLoader.ToBitmap(shot)) Save(bmp, "actual-paint.png");
            // Paint's brush (1 px pencil by default) is thinner than the 3 px grid: check the cell centers only, against black.
            double coverage = Compare(q, c.SkipSet, new GridLayout(canvas, c.Settings.PenSize), p =>
            {
                int x = (int)Math.Floor(p.X - canvas.X), y = (int)Math.Floor(p.Y - canvas.Y);
                if (x < 0 || y < 0 || x >= shot.Width || y >= shot.Height) return new RGB(255, 255, 255);
                int i = (y * shot.Width + x) * 4;
                return new RGB(shot.Data[i], shot.Data[i + 1], shot.Data[i + 2]);
            }, 30, "Microsoft Paint", _ => new RGB(0, 0, 0));
            if (!ok) return 5;
            return coverage >= 97 ? 0 : 6;
        }
    }
}
