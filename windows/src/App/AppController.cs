using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;
using DrawBot.Core;
using DrawBot.Win;

namespace DrawBot.App
{
    public enum TargetKind { None, App, TestCanvas }

    /// <summary>The app that will receive the drawing.</summary>
    public sealed class DrawTarget
    {
        public TargetKind Kind;
        public TargetApp App;
        public static readonly DrawTarget None = new DrawTarget { Kind = TargetKind.None };
        public static readonly DrawTarget TestCanvas = new DrawTarget { Kind = TargetKind.TestCanvas };
        public static DrawTarget Of(TargetApp a) => new DrawTarget { Kind = TargetKind.App, App = a };

        public string DisplayName
        {
            get
            {
                switch (Kind)
                {
                    case TargetKind.None: return "Unknown (nothing found under the canvas)";
                    case TargetKind.TestCanvas: return "DrawBot Test Canvas";
                    default: return App.Name ?? App.ExeName ?? "pid " + App.Pid;
                }
            }
        }
    }

    /// <summary>One color of a run, frozen at Start.</summary>
    public sealed class RunStep
    {
        public int PaletteIndex;
        public RGB Color;
        public List<ScreenStroke> Strokes;
        public double Estimate;
    }

    /// <summary>Everything a run needs, snapshotted at Start so later setting changes cannot corrupt it.</summary>
    public sealed class RunPlan
    {
        public RectD Canvas;
        public List<RunStep> Steps;
        public SpeedSettings Speed;
        public bool PauseOnMouseMove;
        public int CountdownSeconds;
        public SelectionSpeed SelectionSpeed;
        public double PenSize;
        public DateTime StartedAt;
        public ColorPickerProfile Profile;
        public bool Automatic;
    }

    public enum PhaseKind { Ready, SelectingCanvas, AwaitingColor, Preparing, Obstructed, Countdown, Drawing, Paused, Finished, SelectingColor, Learning }

    public sealed class Phase : IEquatable<Phase>
    {
        public PhaseKind Kind;
        public int Step, ResumeIndex, Remaining;
        public string Message = "";
        public static Phase Of(PhaseKind k, int step = 0, int resume = 0, int remaining = 0, string message = "")
            => new Phase { Kind = k, Step = step, ResumeIndex = resume, Remaining = remaining, Message = message };
        public bool Is(PhaseKind k) => Kind == k;
        public bool Equals(Phase o) => o != null && Kind == o.Kind && Step == o.Step && ResumeIndex == o.ResumeIndex && Remaining == o.Remaining && Message == o.Message;
        public override bool Equals(object obj) => Equals(obj as Phase);
        public override int GetHashCode() => (int)Kind;
    }

    /// <summary>
    /// UI-thread state machine and model for the whole app.
    ///     ready ──Select Canvas──▶ selectingCanvas ──▶ ready
    ///     ready ──Start──▶ awaitingColor(i) ──Continue──▶ preparing(i,r) ──▶ countdown(i,r) ──▶ drawing(i)
    ///     drawing(i) ──completed──▶ awaitingColor(i+1) … ──▶ finished ──Close──▶ ready
    ///     drawing(i) ──paused──▶ paused(i,r) ──Resume──▶ preparing(i,r)
    ///     any ──Stop──▶ ready
    /// Color Learn replaces the prompt with selectingColor(i) ──replayed──▶ preparing(i,0) …
    /// </summary>
    public sealed class AppController
    {
        public event Action Changed = () => { };
        void Notify() => Changed();

        DrawSettings settings;
        public DrawSettings Settings
        {
            get => settings;
            set
            {
                var old = settings;
                settings = value.Clamped();
                SettingsStore.Save(settings);
                if (old.MaxColors != settings.MaxColors || old.MergeDistance != settings.MergeDistance || old.PenSize != settings.PenSize
                    || old.StrokeStyle != settings.StrokeStyle || old.ColorSelection != settings.ColorSelection) Reprocess();
                if (old.SkipNearWhite != settings.SkipNearWhite) ResetSkipSet();
                Notify();
            }
        }

        public RGBAImage Image { get; private set; }
        public string ImageName { get; private set; }
        public RectD? Canvas { get; private set; }
        public DrawTarget Target { get; private set; } = DrawTarget.None;
        public SiteDetector.Site TargetSite { get; private set; }
        public ProcessedResult Result { get; private set; }
        public bool IsProcessing { get; private set; }
        public bool IsLoadingImage { get; private set; }
        public HashSet<int> SkipSet { get; private set; } = new HashSet<int>();
        public Bitmap PreviewImage { get; private set; }
        public Phase Phase { get; private set; } = Phase.Of(PhaseKind.Ready);
        string statusMessage;
        public string StatusMessage { get => statusMessage; set { statusMessage = value; Notify(); } }
        public double DrawProgress { get; private set; }
        public Dictionary<string, ColorPickerProfile> ColorProfiles { get; private set; } = SettingsStore.LoadProfiles();
        /// <summary>Hotkeys Windows refused (another app owns them).</summary>
        public List<string> HotkeyProblems = new List<string>();

        int imageToken;
        readonly ImageProcessor processor = new ImageProcessor();
        RunPlan plan;
        readonly DrawingEngine engine = new DrawingEngine(SpeedSettings.Normal);
        int passToken;
        bool escRegistered;
        readonly List<Form> hiddenWindows = new List<Form>();
        bool controlPanelWasVisible;
        bool showPanelAfterPass;
        readonly InputReplayer replayer = new InputReplayer();
        ColorLearnSession learnSession;
        readonly Dictionary<string, RGB> pickerColor = new Dictionary<string, RGB>();
        string autoNote = "";
        ActivityMonitor activity;

        const int EscHotKeyId = 100;

        PromptController prompt;
        PromptController Prompt
        {
            get
            {
                if (prompt == null) { prompt = new PromptController(); prompt.OnAction = HandlePrompt; }
                return prompt;
            }
        }
        readonly HudController hud = new HudController();
        readonly SelectionOverlay overlay = new SelectionOverlay();
        TestCanvasForm testCanvas;
        public ControlPanel ControlPanel;

        public AppController()
        {
            settings = SettingsStore.LoadSettings();
            var saved = SettingsStore.LastCanvas;
            if (saved.HasValue && Displays.IsOnConnectedScreen(saved.Value)) Canvas = saved;
            var path = SettingsStore.LastImagePath;
            if (path != null && File.Exists(path)) LoadImage(path, false);
            Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (s, e) => ScreensChanged();
            if (Canvas.HasValue) Ui.After(0.3, CaptureTarget);
        }

        public TestCanvasForm TestCanvasWindow => testCanvas;

        // MARK: Derived state

        public bool IsRunning => !(Phase.Is(PhaseKind.Ready) || Phase.Is(PhaseKind.SelectingCanvas) || Phase.Is(PhaseKind.Finished));

        public bool PromptWaiting => Phase.Is(PhaseKind.AwaitingColor) || Phase.Is(PhaseKind.Paused) || Phase.Is(PhaseKind.Obstructed) || Phase.Is(PhaseKind.Finished);

        public bool ResultIsCurrent { get { var k = CurrentKey(); return Result != null && k != null && Result.Key.Equals(k); } }

        public bool CanStart => !IsRunning && !Phase.Is(PhaseKind.SelectingCanvas) && Image != null && Canvas.HasValue && !IsProcessing && !IsLoadingImage && ResultIsCurrent;

        bool PassActive => Phase.Is(PhaseKind.Preparing) || Phase.Is(PhaseKind.Countdown) || Phase.Is(PhaseKind.Drawing) || Phase.Is(PhaseKind.SelectingColor);

        /// <summary>Palette indices with pixels, in drawing order (for the swatch strip).</summary>
        public int[] OrderedPalette => Result == null || Result.Quantized.Palette.Length == 0 ? new int[0] : ColorMath.Order(Result.Quantized, settings.Order);

        public int TotalOpaquePixels => Result?.Quantized.Counts.Sum() ?? 0;

        public string FooterText
        {
            get
            {
                if (Result == null)
                {
                    if (IsLoadingImage) return "Loading image…";
                    return Image == null ? "Choose an image to see a preview." : "Processing…";
                }
                var q = Result.Quantized;
                var drawable = Enumerable.Range(0, q.Palette.Length).Where(i => !SkipSet.Contains(i) && q.Counts[i] > 0).ToList();
                var parts = new List<string> { drawable.Count + " color" + (drawable.Count == 1 ? "" : "s") };
                if (Result.Key.IsPreviewLayout) parts.Add("select a canvas to plan strokes");
                else
                {
                    int strokes = drawable.Sum(i => i < Result.Strokes.Count ? Result.Strokes[i].Count : 0);
                    double[] est;
                    Result.Estimates.TryGetValue(settings.Speed, out est);
                    double t = drawable.Sum(i => est != null && i < est.Length ? est[i] : 0);
                    var order = ColorMath.Order(q, settings.Order).Where(drawable.Contains).ToList();
                    t += SelectionTime(order.Select(i => q.Palette[i]).ToList());
                    parts.Add(strokes + " strokes");
                    bool automatic = settings.ColorSelection == ColorSelectionMode.Automatic && CurrentProfile != null;
                    parts.Add("≈ " + TimeEstimator.Format(t) + (automatic || order.Count == 0 ? "" : " + your color picks"));
                }
                if (IsProcessing) parts.Add("updating…");
                return string.Join(" · ", parts);
            }
        }

        /// <summary>Countdowns and, when DrawBot selects colors itself, each selection at the chosen speed.</summary>
        public double SelectionTime(List<RGB> colors)
        {
            double countdown = settings.CountdownSeconds;
            var profile = CurrentProfile;
            if (settings.ColorSelection != ColorSelectionMode.Automatic || profile == null) return countdown * colors.Count;
            var speed = settings.SelectionSpeed;
            double total = 0;
            RGB prevVal;
            RGB? previous = pickerColor.TryGetValue(profile.AppKey, out prevVal) ? prevVal : (RGB?)null;
            for (int i = 0; i < colors.Count; i++)
            {
                total += speed.Settle() + speed.QuietPeriod() + 0.05;
                total += InputReplayer.EstimatedDuration(profile.Actions(colors[i], previous), speed.Pace());
                if (i == 0 || speed.CountdownEveryColor()) total += countdown;
                previous = colors[i];
            }
            return total;
        }

        public string CanvasDescription
        {
            get
            {
                if (!Canvas.HasValue) return null;
                var c = Canvas.Value;
                var screen = Displays.ScreenFor(c);
                var name = screen.Primary ? "the main display" : screen.DeviceName.Replace(@"\\.\", "");
                return (int)c.Width + " × " + (int)c.Height + " px at (" + (int)c.X + ", " + (int)c.Y + ") on " + name;
            }
        }

        public string GridDescription => Canvas.HasValue ? new GridLayout(Canvas.Value, settings.PenSize).Columns + " × " + new GridLayout(Canvas.Value, settings.PenSize).Rows + " cells" : null;

        public string PenHelperText => "Set your brush to " + BrushSize(settings.PenSize, Canvas);

        public static string BrushSize(double pen, RectD? canvas)
        {
            var n = FormatPen(pen);
            double scale = canvas.HasValue ? Displays.Scale(canvas.Value) : 1;
            if (scale > 1.01) return "≈ " + n + " px (apps that measure brushes in scaled units at " + (int)Math.Round(scale * 100) + "% want ≈ " + FormatPen(pen / scale) + ")";
            return "≈ " + n + " px";
        }

        public static string FormatPen(double v) => Num.Round(v) == v ? ((int)v).ToString() : Num.F(v, 1);

        public string ImageInfo => Image == null ? null : (ImageName ?? "Image") + " — " + Image.Width + " × " + Image.Height + " px";

        /// <summary>Color and width the Test Canvas uses for incoming strokes.</summary>
        public Tuple<Color, float> TestCanvasStrokeStyle()
        {
            float width = (float)(plan?.PenSize ?? settings.PenSize);
            if (Phase.Is(PhaseKind.Drawing) || Phase.Is(PhaseKind.Preparing) || Phase.Is(PhaseKind.Countdown))
            {
                if (plan != null && plan.Automatic && testCanvas != null) return Tuple.Create(testCanvas.PickedColor.ToColor(), width);
                if (plan != null && Phase.Step < plan.Steps.Count) return Tuple.Create(plan.Steps[Phase.Step].Color.ToColor(), width);
            }
            if (testCanvas != null && settings.ColorSelection == ColorSelectionMode.Automatic) return Tuple.Create(testCanvas.PickedColor.ToColor(), width);
            return Tuple.Create(Color.Black, width);
        }

        // MARK: Processing

        ProcessingKey CurrentKey()
        {
            if (Image == null) return null;
            if (Canvas.HasValue)
                return new ProcessingKey
                {
                    ImageToken = imageToken, Layout = new GridLayout(Canvas.Value, settings.PenSize), Options = settings.QuantizeOptions,
                    IsPreviewLayout = false, SnapPalette = SnapPalette, StrokeStyle = settings.StrokeStyle,
                };
            return new ProcessingKey { ImageToken = imageToken, Layout = ImageProcessor.PreviewLayout(Image), Options = settings.QuantizeOptions, IsPreviewLayout = true, SnapPalette = SnapPalette };
        }

        void Reprocess()
        {
            var key = CurrentKey();
            if (Image == null || key == null)
            {
                processor.Cancel();
                Result = null; PreviewImage = null; IsProcessing = false;
                Notify();
                return;
            }
            if (Result != null && Result.Key.Equals(key)) { IsProcessing = false; Notify(); return; }
            IsProcessing = true;
            processor.Process(Image, key, Accept);
            Notify();
        }

        void Accept(ProcessedResult r)
        {
            if (!r.Key.Equals(CurrentKey())) return;
            var oldPalette = Result?.Quantized.Palette;
            Result = r;
            IsProcessing = false;
            if (oldPalette == null || !oldPalette.SequenceEqual(r.Quantized.Palette)) ResetSkipSet();
            else UpdatePreview();
            Notify();
        }

        void ResetSkipSet()
        {
            var q = Result?.Quantized;
            SkipSet = q != null && settings.SkipNearWhite
                ? new HashSet<int>(Enumerable.Range(0, q.Palette.Length).Where(i => ColorMath.IsNearWhite(q.Palette[i])))
                : new HashSet<int>();
            UpdatePreview();
        }

        public void ToggleSkip(int index)
        {
            if (IsRunning) return;
            if (!SkipSet.Remove(index)) SkipSet.Add(index);
            UpdatePreview();
            Notify();
        }

        void UpdatePreview()
        {
            var q = Result?.Quantized;
            if (q == null) { PreviewImage = null; Notify(); return; }
            if (SkipSet.Count == 0 && Result.Preview != null) PreviewImage = Result.Preview;
            processor.RenderPreview(q, SkipSet, bmp => { PreviewImage = bmp; Notify(); });
        }

        // MARK: Image input

        public void ChooseImage(IWin32Window owner)
        {
            if (IsRunning) return;
            using (var dlg = new OpenFileDialog
            {
                Title = "Choose an image for DrawBot to paint",
                Filter = "Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.ico;*.webp;*.heic;*.heif;*.jxr;*.dds|All files|*.*",
            })
            {
                var last = SettingsStore.LastImagePath;
                if (last != null) try { dlg.InitialDirectory = Path.GetDirectoryName(last); } catch (Exception) { }
                if (dlg.ShowDialog(owner) == DialogResult.OK) LoadImage(dlg.FileName);
            }
        }

        public void LoadImage(string path, bool reportErrors = true)
        {
            if (IsRunning) return;
            IsLoadingImage = true;
            Notify();
            Task.Run(() =>
            {
                RGBAImage img = null; string error = null;
                try { img = ImageLoader.Load(path); } catch (Exception e) { error = e.Message; }
                return Tuple.Create(img, error);
            }).ContinueWith(t =>
            {
                IsLoadingImage = false;
                if (t.Result.Item1 != null)
                {
                    SetImage(t.Result.Item1, Path.GetFileName(path));
                    SettingsStore.LastImagePath = path;
                }
                else if (reportErrors) StatusMessage = t.Result.Item2;
                Notify();
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        public void LoadImage(Image image, string name)
        {
            if (IsRunning) return;
            var img = ImageLoader.FromImage(image);
            if (img == null) { StatusMessage = "That doesn't look like a readable image."; return; }
            SetImage(img, name);
            SettingsStore.LastImagePath = null;   // pasted images are not saved anywhere
        }

        void SetImage(RGBAImage img, string name)
        {
            imageToken++;
            Image = img;
            ImageName = name;
            statusMessage = null;
            Result = null;
            PreviewImage = null;
            Reprocess();
        }

        /// <summary>Ctrl+V in the control panel.</summary>
        public bool PasteImage()
        {
            if (IsRunning) return false;
            try
            {
                if (Clipboard.ContainsFileDropList())
                {
                    var f = Clipboard.GetFileDropList().Cast<string>().FirstOrDefault();
                    if (f != null) { LoadImage(f); return true; }
                }
                if (Clipboard.ContainsImage())
                {
                    using (var img = Clipboard.GetImage()) LoadImage(img, "Pasted image");
                    return true;
                }
            }
            catch (Exception) { }
            StatusMessage = "The clipboard doesn't contain an image.";
            return false;
        }

        // MARK: Canvas selection

        public void SelectCanvas()
        {
            if (IsRunning || Phase.Is(PhaseKind.SelectingCanvas)) return;
            if (Phase.Is(PhaseKind.Finished)) CloseDonePrompt();
            SetPhase(Phase.Of(PhaseKind.SelectingCanvas));
            controlPanelWasVisible = ControlPanel != null && ControlPanel.Visible;
            ControlPanel?.Hide();
            RegisterEsc();
            overlay.Begin(SelectionFinished);
        }

        void SelectionFinished(RectD? rect)
        {
            UnregisterEsc();
            SetPhase(Phase.Of(PhaseKind.Ready));
            if (rect.HasValue)
            {
                Canvas = rect;
                SettingsStore.LastCanvas = rect;
                Target = DrawTarget.None;
                statusMessage = null;
                Reprocess();
                Ui.After(0.15, CaptureTarget);   // let the overlay disappear first
            }
            if (controlPanelWasVisible) ShowControlPanel();
        }

        void CaptureTarget()
        {
            if (!Canvas.HasValue) { Target = DrawTarget.None; Notify(); return; }
            var w = WindowInspector.TargetWindow(Canvas.Value);
            if (w == null) Target = DrawTarget.None;
            else if (w.Pid == ProcessUtil.OwnPid) Target = testCanvas != null && w.Handle == testCanvas.Handle ? DrawTarget.TestCanvas : DrawTarget.None;
            else Target = DrawTarget.Of(TargetApp.From(w));
            RefreshSite();
            Reprocess();
        }

        public void RefreshSite()
        {
            if (Target.Kind != TargetKind.App || Target.App.IsTerminated || !Canvas.HasValue)
            {
                if (TargetSite != null) { TargetSite = null; Notify(); }
                return;
            }
            var site = SiteDetector.SiteOf(Target.App);
            if (!Equals(site, TargetSite))
            {
                TargetSite = site;
                Reprocess();
            }
        }

        /// <summary>"Google Chrome — paintz.app", or just the app's name.</summary>
        public string TargetDescription => TargetSite != null && Target.Kind == TargetKind.App ? Target.DisplayName + " — " + TargetSite.Name : Target.DisplayName;

        /// <summary>A warning when Windows would block DrawBot's input into the target.</summary>
        public string TargetWarning
        {
            get
            {
                if (Target.Kind != TargetKind.App || ProcessUtil.SelfElevated) return null;
                var e = ProcessUtil.IsElevated(Target.App.Pid);
                if (e == false) return null;
                return Target.DisplayName + " seems to run as administrator. Windows doesn't let normal apps click into it: run DrawBot as administrator too.";
            }
        }

        void ResolveTarget()
        {
            switch (Target.Kind)
            {
                case TargetKind.None: CaptureTarget(); break;
                case TargetKind.App: if (Target.App.IsTerminated || !Native.IsWindow(Target.App.Window)) CaptureTarget(); break;
                case TargetKind.TestCanvas: if (testCanvas == null || !testCanvas.IsShown) CaptureTarget(); break;
            }
        }

        void ScreensChanged()
        {
            if (Phase.Is(PhaseKind.SelectingCanvas)) overlay.Cancel();
            if (!Canvas.HasValue || Displays.IsOnConnectedScreen(Canvas.Value)) return;
            if (IsRunning) Stop("Displays changed");
            Canvas = null;
            SettingsStore.LastCanvas = null;
            Target = DrawTarget.None;
            statusMessage = "The canvas is no longer on a connected display — select it again.";
            Reprocess();
        }

        // MARK: Color Learn

        /// <summary>Key under which the target's learned picker is stored: the app, plus the website for browsers.</summary>
        public string TargetAppKey
        {
            get
            {
                switch (Target.Kind)
                {
                    case TargetKind.App:
                        var b = Target.App.ExeName ?? (Target.App.Name != null ? "name:" + Target.App.Name : null);
                        if (b == null) return null;
                        return TargetSite != null ? b + "|site:" + TargetSite.Key : b;
                    case TargetKind.TestCanvas: return "local.drawbot.testcanvas";
                    default: return null;
                }
            }
        }

        public ColorPickerProfile CurrentProfile
        {
            get { var k = TargetAppKey; ColorPickerProfile p; return k != null && ColorProfiles.TryGetValue(k, out p) ? p : null; }
        }

        public bool CanLearn => !IsRunning && !Phase.Is(PhaseKind.SelectingCanvas) && Canvas.HasValue && TargetAppKey != null;

        public string LearnStatusText
        {
            get
            {
                if (!Canvas.HasValue || TargetAppKey == null) return "Select a canvas first. DrawBot learns the color picker of the app under the canvas.";
                var p = CurrentProfile;
                if (p != null) return "Learned for " + TargetDescription + ": " + p.Summary;
                return "DrawBot hasn't learned " + TargetDescription + "'s color picker yet. Click Learn and select two colors while DrawBot watches.";
            }
        }

        public void LearnColorPicker()
        {
            if (IsRunning || Phase.Is(PhaseKind.SelectingCanvas)) return;
            if (Phase.Is(PhaseKind.Finished)) CloseDonePrompt();
            if (!Canvas.HasValue) { StatusMessage = "Select a canvas first (" + Ui.HotkeyPrefix + "S)."; return; }
            if (!InputDesktop.IsAvailable()) { StatusMessage = DrawingEngine.Reason.PermissionMissing + "."; return; }
            var canvas = Canvas.Value;
            ResolveTarget();
            RefreshSite();
            var key = TargetAppKey;
            if (key == null) { StatusMessage = "DrawBot couldn't tell which app is under the canvas. Select the canvas again."; return; }
            var appName = TargetDescription;
            bool isTestCanvas = Target.Kind == TargetKind.TestCanvas;
            activity?.Dispose();
            activity = new ActivityMonitor();
            ModifierWait.Activity = activity;
            var session = new ColorLearnSession(new ColorLearnSession.Target
            {
                AppKey = key, AppName = appName, Canvas = canvas,
                Activate = done => ActivateTarget(done),
                RecordsLocalWindow = h => isTestCanvas && testCanvas != null && h == testCanvas.Handle,
                Careful = settings.Speed == SpeedPreset.Careful,
                WatchEscape = on => { if (!Phase.Is(PhaseKind.Learning)) return; if (on) RegisterEsc(); else UnregisterEsc(); },
                CaptureRect = TargetWindowRect(canvas),
            }, Prompt, hud, replayer,
            (profile, color) =>
            {
                ColorProfiles[profile.AppKey] = profile;
                SettingsStore.SaveProfiles(ColorProfiles);
                if (color.HasValue) pickerColor[profile.AppKey] = color.Value; else pickerColor.Remove(profile.AppKey);
                if (settings.ColorSelection == ColorSelectionMode.Manual) { var s = settings.Copy(); s.ColorSelection = ColorSelectionMode.Automatic; Settings = s; }
                Reprocess();
            },
            LearningEnded);
            learnSession = session;
            statusMessage = null;
            SetPhase(Phase.Of(PhaseKind.Learning));
            controlPanelWasVisible = ControlPanel != null && ControlPanel.Visible;
            ControlPanel?.Hide();
            session.Begin();
        }

        void LearningEnded()
        {
            learnSession = null;
            activity?.Dispose(); activity = null; ModifierWait.Activity = null;
            if (!Phase.Is(PhaseKind.Learning)) return;
            SetPhase(Phase.Of(PhaseKind.Ready));
            var p = CurrentProfile;
            if (p != null) statusMessage = "Color picker learned for " + p.AppName + ".";
            if (controlPanelWasVisible) ShowControlPanel();
            Notify();
        }

        public void ForgetColorProfile()
        {
            var key = TargetAppKey;
            if (IsRunning || key == null) return;
            ColorProfiles.Remove(key);
            pickerColor.Remove(key);
            SettingsStore.SaveProfiles(ColorProfiles);
            Reprocess();
        }

        /// <summary>The drawing app's window around the canvas, or the canvas's screen.</summary>
        RectD TargetWindowRect(RectD canvas)
        {
            if (Target.Kind == TargetKind.App)
            {
                var w = WindowInspector.WindowsAt(canvas.Center).FirstOrDefault(x => x.Pid == Target.App.Pid);
                if (w != null) return w.Bounds;
            }
            if (Target.Kind == TargetKind.TestCanvas && testCanvas != null) return testCanvas.Bounds.ToRectD();
            return Displays.ScreenFor(canvas).Bounds.ToRectD();
        }

        /// <summary>Fixed-palette profiles: the swatch colors the picture is snapped to (automatic mode only).</summary>
        public RGB[] SnapPalette
        {
            get
            {
                var s = CurrentProfile?.Swatches;
                if (settings.ColorSelection != ColorSelectionMode.Automatic || s == null || s.Count == 0) return null;
                return s.Select(x => x.Color).ToArray();
            }
        }

        void ActivateTarget(Action done)
        {
            switch (Target.Kind)
            {
                case TargetKind.TestCanvas:
                    OpenTestCanvas();
                    Ui.After(0.15, done);
                    break;
                case TargetKind.App:
                    if (!Target.App.IsTerminated) AppActivator.Activate(Target.App, 1.5, _ => done());
                    else done();
                    break;
                default:
                    done();
                    break;
            }
        }

        /// <summary>Color Learn: select this step's color by replaying the learned picker input, then draw.</summary>
        void AutoSelect(int step)
        {
            if (plan == null || plan.Profile == null || step >= plan.Steps.Count) return;
            var profile = plan.Profile;
            if (replayer.IsRunning)
            {
                int tk = passToken;
                Ui.After(0.05, () => { if (passToken == tk) AutoSelect(step); });
                return;
            }
            int token = ++passToken;
            autoNote = "";
            Prompt.Hide();
            SetPhase(Phase.Of(PhaseKind.SelectingColor, step));
            ShowHud();
            RegisterEsc();
            ResolveTarget();
            HideOwnWindowsOverlapping(plan.Canvas);
            if (profile.PointerBounds.HasValue) HideOwnWindowsOverlapping(profile.PointerBounds.Value);
            var color = plan.Steps[step].Color;
            var pace = plan.SelectionSpeed;
            ActivateTarget(() => Ui.After(pace.Settle(), () =>
            {
                if (passToken != token) return;
                // Never replay picker clicks into whatever other app happens to be in front.
                if (Target.Kind == TargetKind.App && AppActivator.ForegroundPid != Target.App.Pid)
                {
                    UnregisterEsc();
                    hud.Hide();
                    SetPhase(Phase.Of(PhaseKind.AwaitingColor, step));
                    autoNote = "Couldn't bring " + Target.DisplayName + " to the front to select the color. Click its window once (outside the canvas), then press Select for me.";
                    ShowPrompt();
                    return;
                }
                ModifierWait.WhenReleased(pace.QuietPeriod(), DateTime.UtcNow.AddSeconds(5), () =>
                {
                    if (passToken != token) return;
                    replayer.Pace = pace.Pace();
                    replayer.StopOnUserMouseMove = plan.PauseOnMouseMove;
                    RGB prev;
                    var actions = profile.Actions(color, pickerColor.TryGetValue(profile.AppKey, out prev) ? prev : (RGB?)null);
                    replayer.Run(actions, outcome => AutoSelectFinished(step, color, profile.AppKey, outcome, token));
                });
            }));
        }

        void AutoSelectFinished(int step, RGB color, string key, InputReplayer.Outcome outcome, int token)
        {
            if (passToken != token || !Phase.Is(PhaseKind.SelectingColor) || Phase.Step != step) return;
            if (outcome.Kind == InputReplayer.OutcomeKind.Completed)
            {
                pickerColor[key] = color;
                SetPhase(Phase.Of(PhaseKind.Preparing, step, 0));
                ShowHud();
                bool skip = step > 0 && !(plan?.SelectionSpeed.CountdownEveryColor() ?? true);
                CheckCanvasThenCountdown(step, 0, true, token, skip, DateTime.UtcNow);
            }
            else
            {
                pickerColor.Remove(key);
                UnregisterEsc();
                hud.Hide();
                SetPhase(Phase.Of(PhaseKind.AwaitingColor, step));
                autoNote = "Automatic color selection stopped (" + outcome.Reason + "). Select the color yourself and press Continue, or press Select for me.";
                ShowPrompt();
            }
        }

        // MARK: Windows

        public void ShowControlPanel()
        {
            switch (Phase.Kind)
            {
                case PhaseKind.Preparing:
                case PhaseKind.Countdown:
                    CancelPassBackToPrompt(Phase.Step, Phase.ResumeIndex);
                    break;
                case PhaseKind.SelectingColor:
                    replayer.RequestStop("Paused to show the DrawBot panel");
                    CancelPassBackToPrompt(Phase.Step, 0);
                    break;
                case PhaseKind.Drawing:
                    showPanelAfterPass = true;
                    engine.RequestPause("Paused to show the DrawBot panel");
                    return;   // PassFinished shows it
            }
            ControlPanel?.ShowPanel();
        }

        public void OpenTestCanvas()
        {
            // Don't pop a window in the middle of a pass into another app.
            if (PassActive && Target.Kind != TargetKind.TestCanvas) return;
            if (testCanvas == null || testCanvas.IsDisposed) testCanvas = new TestCanvasForm(TestCanvasStrokeStyle);
            testCanvas.ShowCanvas();
        }

        /// <summary>Our own windows would catch the synthetic clicks, so move them out of the way.</summary>
        void HideOwnWindowsOverlapping(RectD rect)
        {
            var r = rect.ToRectangle();
            var candidates = new List<Form>();
            if (ControlPanel != null) candidates.Add(ControlPanel);
            if (testCanvas != null && Target.Kind != TargetKind.TestCanvas) candidates.Add(testCanvas);
            foreach (var w in candidates)
            {
                if (!w.Visible || !w.Bounds.IntersectsWith(r)) continue;
                w.Hide();
                if (!hiddenWindows.Contains(w)) hiddenWindows.Add(w);
            }
        }

        void RestoreHiddenWindows()
        {
            foreach (var w in hiddenWindows) if (!w.IsDisposed) w.Show();
            hiddenWindows.Clear();
        }

        // MARK: Hotkeys

        public void RegisterGlobalHotkeys()
        {
            var mods = Keys.Control | Keys.Alt | Keys.Shift;
            HotkeyProblems.Clear();
            if (!HotKeyCenter.Shared.Register(1, Keys.P, mods, ShowControlPanel)) HotkeyProblems.Add(Ui.HotkeyPrefix + "P");
            if (!HotKeyCenter.Shared.Register(2, Keys.S, mods, SelectCanvas)) HotkeyProblems.Add(Ui.HotkeyPrefix + "S");
            if (!HotKeyCenter.Shared.Register(3, Keys.Enter, mods, ContinueFromHotkey)) HotkeyProblems.Add(Ui.ContinueKey);
            if (!HotKeyCenter.Shared.Register(4, Keys.OemPeriod, mods, () => Stop())) HotkeyProblems.Add(Ui.HotkeyPrefix + ".");
        }

        void RegisterEsc()
        {
            if (escRegistered) return;
            escRegistered = HotKeyCenter.Shared.Register(EscHotKeyId, Keys.Escape, Keys.None, EscPressed);
        }

        void UnregisterEsc()
        {
            if (!escRegistered) return;
            HotKeyCenter.Shared.Unregister(EscHotKeyId);
            escRegistered = false;
        }

        void EscPressed()
        {
            switch (Phase.Kind)
            {
                case PhaseKind.SelectingCanvas: overlay.Cancel(); break;
                case PhaseKind.Preparing:
                case PhaseKind.Countdown: CancelPassBackToPrompt(Phase.Step, Phase.ResumeIndex); break;
                case PhaseKind.Drawing: engine.RequestStop(DrawingEngine.Reason.Escape); break;
                case PhaseKind.SelectingColor:
                    replayer.RequestStop(DrawingEngine.Reason.Escape);
                    CancelPassBackToPrompt(Phase.Step, 0);
                    break;
                case PhaseKind.Learning: learnSession?.Escape(); break;
                default: UnregisterEsc(); break;
            }
        }

        // MARK: Run control

        public void StartOrContinue()
        {
            if (Phase.Is(PhaseKind.Learning) || (PromptWaiting && !Phase.Is(PhaseKind.Finished))) ContinueFromHotkey();
            else Start();
        }

        public void Start()
        {
            if (IsRunning || Phase.Is(PhaseKind.SelectingCanvas)) return;
            if (Phase.Is(PhaseKind.Finished)) CloseDonePrompt();
            if (Image == null) { StatusMessage = "Choose an image first."; ShowControlPanel(); return; }
            if (!Canvas.HasValue) { StatusMessage = "Select a canvas first (" + Ui.HotkeyPrefix + "S)."; ShowControlPanel(); return; }
            var canvas = Canvas.Value;
            if (!Displays.IsOnConnectedScreen(canvas))
            {
                StatusMessage = "The canvas is no longer on a connected display — select it again.";
                ShowControlPanel();
                return;
            }
            if (Result == null || !ResultIsCurrent || IsProcessing) { StatusMessage = "Still processing the image — try again in a moment."; return; }
            if (!InputDesktop.IsAvailable()) { StatusMessage = DrawingEngine.Reason.PermissionMissing + "."; ShowControlPanel(); return; }
            var q = Result.Quantized;
            double[] est;
            Result.Estimates.TryGetValue(settings.Speed, out est);
            var steps = ColorMath.Order(q, settings.Order)
                .Where(i => !SkipSet.Contains(i) && i < Result.Strokes.Count && Result.Strokes[i].Count > 0)
                .Select(i => new RunStep { PaletteIndex = i, Color = q.Palette[i], Strokes = Result.Strokes[i], Estimate = est != null && i < est.Length ? est[i] : 0 })
                .ToList();
            if (steps.Count == 0) { StatusMessage = "Nothing to draw — every color is skipped."; ShowControlPanel(); return; }
            ResolveTarget();
            RefreshSite();
            var profile = CurrentProfile;
            bool automatic = settings.ColorSelection == ColorSelectionMode.Automatic;
            if (automatic && profile == null)
            {
                StatusMessage = Target.Kind == TargetKind.None
                    ? "DrawBot couldn't tell which app is under the canvas. Select the canvas again."
                    : "DrawBot hasn't learned " + TargetDescription + "'s color picker yet. Click Learn Color Picker…, or set Color selection to “Ask me”.";
                ShowControlPanel();
                return;
            }
            int fps = Displays.RefreshRate(canvas);
            plan = new RunPlan
            {
                Canvas = canvas, Steps = steps, Speed = settings.Speed.Settings().Adapted(fps), PauseOnMouseMove = settings.PauseOnMouseMove,
                CountdownSeconds = settings.CountdownSeconds, SelectionSpeed = settings.SelectionSpeed, PenSize = settings.PenSize,
                StartedAt = DateTime.UtcNow, Profile = profile, Automatic = automatic && profile != null,
            };
            statusMessage = null;
            autoNote = "";
            activity?.Dispose();
            activity = new ActivityMonitor();
            ModifierWait.Activity = activity;
            if (plan.Automatic) { AutoSelect(0); return; }
            SetPhase(Phase.Of(PhaseKind.AwaitingColor, 0));
            ShowPrompt();
            // Bring the drawing app forward so the user can pick the first color straight away.
            if (Target.Kind == TargetKind.App && !Target.App.IsTerminated) AppActivator.Activate(Target.App, 1.5, _ => { });
        }

        public void ContinueFromHotkey()
        {
            switch (Phase.Kind)
            {
                case PhaseKind.AwaitingColor:
                case PhaseKind.Paused: HandlePrompt(PromptAction.Proceed); break;
                case PhaseKind.Obstructed: HandlePrompt(PromptAction.CheckAgain); break;
                case PhaseKind.Finished: HandlePrompt(PromptAction.Close); break;
                case PhaseKind.Learning: learnSession?.HotkeyProceed(); break;
            }
        }

        public void Stop(string reason = "Stopped by user")
        {
            switch (Phase.Kind)
            {
                case PhaseKind.Ready: return;
                case PhaseKind.SelectingCanvas: overlay.Cancel(); break;
                case PhaseKind.Drawing:
                    if (engine.IsRunning) engine.RequestStop(reason);   // completion → EndRun
                    else EndRun("Stopped: " + reason);
                    break;
                case PhaseKind.Finished: CloseDonePrompt(); break;
                case PhaseKind.Learning: learnSession?.Cancel(); break;
                default: EndRun("Stopped: " + reason); break;
            }
        }

        void HandlePrompt(PromptAction action)
        {
            if (Phase.Is(PhaseKind.Learning)) { learnSession?.Handle(action); return; }
            var p = Phase;
            if (p.Is(PhaseKind.AwaitingColor) && action == PromptAction.AutoSelect) AutoSelect(p.Step);
            else if (p.Is(PhaseKind.AwaitingColor) && action == PromptAction.Proceed) BeginPass(p.Step, 0, true);
            else if (p.Is(PhaseKind.Paused) && action == PromptAction.Proceed) BeginPass(p.Step, p.ResumeIndex, true);
            else if (p.Is(PhaseKind.Obstructed) && action == PromptAction.Proceed) BeginPass(p.Step, p.ResumeIndex, false);   // "Draw anyway"
            else if (p.Is(PhaseKind.Obstructed) && action == PromptAction.CheckAgain) BeginPass(p.Step, p.ResumeIndex, true);
            else if ((p.Is(PhaseKind.AwaitingColor) || p.Is(PhaseKind.Paused)) && action == PromptAction.Skip) Advance(p.Step);
            else if (p.Is(PhaseKind.Finished)) CloseDonePrompt();
            else if (action == PromptAction.Stop) Stop();
        }

        void BeginPass(int step, int resumeIndex, bool checkObstructions)
        {
            if (plan == null) return;
            int token = ++passToken;
            Prompt.Hide();
            SetPhase(Phase.Of(PhaseKind.Preparing, step, resumeIndex));
            ShowHud();
            RegisterEsc();
            ResolveTarget();
            HideOwnWindowsOverlapping(plan.Canvas);

            Action afterActivation = () => Ui.After(0.25, () =>
            {
                if (passToken != token) return;
                CheckCanvasThenCountdown(step, resumeIndex, checkObstructions, token, false, DateTime.UtcNow);
            });
            switch (Target.Kind)
            {
                case TargetKind.TestCanvas:
                    OpenTestCanvas();
                    afterActivation();
                    break;
                case TargetKind.App:
                    if (Target.App.IsTerminated) { afterActivation(); break; }
                    var app = Target.App;
                    AppActivator.Activate(app, 1.5, ok =>
                    {
                        if (passToken != token) return;
                        // If the drawing app isn't in front, its first click usually only activates the
                        // window, silently losing the first stroke.
                        if (!ok && checkObstructions && AppActivator.ForegroundPid != app.Pid)
                        {
                            UnregisterEsc();
                            hud.Hide();
                            SetPhase(Phase.Of(PhaseKind.Obstructed, step, resumeIndex, 0,
                                "Couldn't bring " + Target.DisplayName + " to the front. Click its window once (outside the canvas, e.g. its title bar or toolbar), then press Check again."));
                            ShowPrompt();
                            return;
                        }
                        afterActivation();
                    });
                    break;
                default:
                    afterActivation();
                    break;
            }
        }

        /// <summary>How long a window may cover the canvas before DrawBot reports it.</summary>
        public const double ObstructionPatience = 2.5;
        const double ObstructionRecheckInterval = 0.25;

        void CheckCanvasThenCountdown(int step, int resumeIndex, bool checkObstructions, int token, bool skipCountdown, DateTime since)
        {
            if (passToken != token || plan == null || !Phase.Is(PhaseKind.Preparing)) return;
            int? targetPid = null;
            if (Target.Kind == TargetKind.App) targetPid = Target.App.Pid;
            else if (Target.Kind == TargetKind.TestCanvas) targetPid = ProcessUtil.OwnPid;
            if (checkObstructions && targetPid.HasValue)
            {
                var obstructions = WindowInspector.Obstructions(plan.Canvas, targetPid.Value)
                    .Where(w => !(w.Pid == ProcessUtil.OwnPid && w.Handle == (prompt != null ? prompt.Handle : IntPtr.Zero) && !prompt.IsVisible)).ToList();
                if (obstructions.Count > 0 && (DateTime.UtcNow - since).TotalSeconds < ObstructionPatience)
                {
                    Ui.After(ObstructionRecheckInterval, () => CheckCanvasThenCountdown(step, resumeIndex, true, token, skipCountdown, since));
                    return;
                }
                if (obstructions.Count > 0)
                {
                    var names = new List<string>();
                    foreach (var o in obstructions)
                    {
                        var n = string.IsNullOrEmpty(o.OwnerName) ? "another app" : o.OwnerName;
                        if (!names.Contains(n)) names.Add(n);
                    }
                    UnregisterEsc();
                    hud.Hide();
                    SetPhase(Phase.Of(PhaseKind.Obstructed, step, resumeIndex, 0, "Something from " + ListFormat(names) + " is covering the canvas — move it away."));
                    ShowPrompt();
                    return;
                }
            }
            if (Target.Kind == TargetKind.App)
            {
                var warning = TargetWarning;
                if (warning != null && checkObstructions)
                {
                    UnregisterEsc();
                    hud.Hide();
                    SetPhase(Phase.Of(PhaseKind.Obstructed, step, resumeIndex, 0, warning));
                    ShowPrompt();
                    return;
                }
            }
            Countdown(step, resumeIndex, skipCountdown ? 0 : plan.CountdownSeconds, token);
        }

        void Countdown(int step, int resumeIndex, int remaining, int token)
        {
            if (passToken != token) return;
            if (remaining <= 0) { WaitForModifierRelease(step, resumeIndex, token, DateTime.UtcNow.AddSeconds(5)); return; }
            SetPhase(Phase.Of(PhaseKind.Countdown, step, resumeIndex, remaining));
            ShowHud();
            Ui.After(1, () => Countdown(step, resumeIndex, remaining - 1, token));
        }

        /// <summary>Synthetic clicks inherit held modifiers (Ctrl+click, Shift-constrained lines): wait for release.</summary>
        void WaitForModifierRelease(int step, int resumeIndex, int token, DateTime deadline)
        {
            if (passToken != token) return;
            if (GlobalInputHook.HeldModifiers() == KeyModifiers.None || DateTime.UtcNow > deadline) { StartDrawing(step, resumeIndex); return; }
            SetPhase(Phase.Of(PhaseKind.Countdown, step, resumeIndex, 0));
            ShowHud();
            Ui.After(0.05, () => WaitForModifierRelease(step, resumeIndex, token, deadline));
        }

        void StartDrawing(int step, int resumeIndex, int attempt = 0)
        {
            if (engine.IsRunning)
            {
                int token = passToken;
                if (attempt < 40) Ui.After(0.05, () => { if (passToken == token) StartDrawing(step, resumeIndex, attempt + 1); });
                else EndRun("Stopped: the previous pass did not finish");
                return;
            }
            if (plan == null || step >= plan.Steps.Count) { EndRun("Stopped: internal error (no color to draw)"); return; }
            var strokes = plan.Steps[step].Strokes;
            if (resumeIndex >= strokes.Count)
            {
                passToken++;
                UnregisterEsc();
                hud.Hide();
                Advance(step);
                return;
            }
            if (Target.Kind == TargetKind.TestCanvas && testCanvas != null) testCanvas.BringToFront();
            engine.Speed = plan.Speed;
            engine.PauseOnUserMouseMove = plan.PauseOnMouseMove;
            DrawProgress = (double)resumeIndex / Math.Max(1, strokes.Count);
            SetPhase(Phase.Of(PhaseKind.Drawing, step));
            ShowHud();
            engine.Draw(strokes, resumeIndex, plan.Canvas, p =>
            {
                if (!Phase.Is(PhaseKind.Drawing) || Phase.Step != step) return;
                DrawProgress = p.Fraction;
                ShowHud();
            }, outcome => PassFinished(step, outcome));
        }

        void PassFinished(int step, DrawingEngine.Outcome outcome)
        {
            LastOutcome = outcome;
            if (!Phase.Is(PhaseKind.Drawing) || Phase.Step != step)
            {
                if (!PassActive && !Phase.Is(PhaseKind.SelectingCanvas)) UnregisterEsc();
                return;
            }
            UnregisterEsc();
            hud.Hide();
            bool wantsPanel = showPanelAfterPass;
            showPanelAfterPass = false;
            switch (outcome.Kind)
            {
                case DrawingEngine.OutcomeKind.Completed: Advance(step); break;
                case DrawingEngine.OutcomeKind.Paused:
                    SetPhase(Phase.Of(PhaseKind.Paused, step, outcome.ResumeIndex, 0, outcome.Reason));
                    ShowPrompt();
                    break;
                default:
                    EndRun("Stopped: " + outcome.Reason);
                    if (outcome.Reason == DrawingEngine.Reason.EventsIgnored || outcome.Reason == DrawingEngine.Reason.InputBlocked
                        || outcome.Reason == DrawingEngine.Reason.PermissionMissing || outcome.Reason == DrawingEngine.Reason.PermissionLost) ShowControlPanel();
                    break;
            }
            if (wantsPanel) ControlPanel?.ShowPanel();
        }

        /// <summary>The last drawing pass's outcome (for the self test).</summary>
        public DrawingEngine.Outcome LastOutcome;

        void CancelPassBackToPrompt(int step, int resumeIndex)
        {
            passToken++;
            UnregisterEsc();
            hud.Hide();
            SetPhase(resumeIndex == 0 ? Phase.Of(PhaseKind.AwaitingColor, step) : Phase.Of(PhaseKind.Paused, step, resumeIndex, 0, "Canceled"));
            ShowPrompt();
        }

        void Advance(int step)
        {
            if (plan == null) { EndRun(null); return; }
            int next = step + 1;
            autoNote = "";
            if (next < plan.Steps.Count)
            {
                if (plan.Automatic) { AutoSelect(next); return; }
                SetPhase(Phase.Of(PhaseKind.AwaitingColor, next));
                ShowPrompt();
            }
            else FinishRun();
        }

        void FinishRun()
        {
            if (plan == null) return;
            passToken++;
            UnregisterEsc();
            hud.Hide();
            RestoreHiddenWindows();
            var elapsed = (DateTime.UtcNow - plan.StartedAt).TotalSeconds;
            int strokes = plan.Steps.Sum(s => s.Strokes.Count);
            int n = plan.Steps.Count;
            SetPhase(Phase.Of(PhaseKind.Finished));
            statusMessage = "Done — " + n + " color" + (n == 1 ? "" : "s") + ", " + strokes + " strokes.";
            LastRunSummary = "Painted " + n + " color" + (n == 1 ? "" : "s") + " (" + strokes + " strokes) in " + TimeEstimator.Format(elapsed) + ".";
            Prompt.Show(new PromptContent { Mode = PromptModeKind.Done, Detail = LastRunSummary }, plan.Canvas);
            plan = null;
            activity?.Dispose(); activity = null; ModifierWait.Activity = null;
            Notify();
        }

        public string LastRunSummary;

        void CloseDonePrompt()
        {
            Prompt.Hide();
            if (Phase.Is(PhaseKind.Finished)) SetPhase(Phase.Of(PhaseKind.Ready));
        }

        void EndRun(string message)
        {
            passToken++;
            showPanelAfterPass = false;
            if (engine.IsRunning) engine.RequestStop("Stopped");
            if (replayer.IsRunning) replayer.RequestStop("Stopped");
            UnregisterEsc();
            Prompt.Hide();
            hud.Hide();
            RestoreHiddenWindows();
            plan = null;
            DrawProgress = 0;
            activity?.Dispose(); activity = null; ModifierWait.Activity = null;
            SetPhase(Phase.Of(PhaseKind.Ready));
            if (message != null) statusMessage = message;
            Notify();
        }

        void SetPhase(Phase p) { Phase = p; Notify(); }

        // MARK: Prompt & HUD content

        void ShowPrompt()
        {
            if (plan == null) return;
            var p = Phase;
            PromptModeKind mode; string detail = ""; int remaining = 0;
            switch (p.Kind)
            {
                case PhaseKind.AwaitingColor: mode = PromptModeKind.Color; break;
                case PhaseKind.Paused: mode = PromptModeKind.Paused; detail = p.Message; break;
                case PhaseKind.Obstructed: mode = PromptModeKind.Obstructed; detail = p.Message; break;
                default: return;
            }
            if (p.Step >= plan.Steps.Count) return;
            var st = plan.Steps[p.Step];
            if (mode != PromptModeKind.Color) remaining = st.Strokes.Count - p.ResumeIndex;
            var content = new PromptContent
            {
                Mode = mode, Detail = detail, Color = st.Color, StepNumber = p.Step + 1, StepCount = plan.Steps.Count, StrokeCount = st.Strokes.Count,
                StrokesRemaining = remaining, Estimate = st.Estimate > 0 ? "≈ " + TimeEstimator.Format(st.Estimate) : "",
                BrushHint = "Brush: hard, round, 100% opacity, " + BrushSize(plan.PenSize, plan.Canvas),
            };
            if (mode == PromptModeKind.Color) { content.CanAutoSelect = plan.Profile != null; content.Note = autoNote; }
            Prompt.Show(content, plan.Canvas);
        }

        void ShowHud()
        {
            if (plan == null) return;
            var p = Phase;
            HudMode mode;
            switch (p.Kind)
            {
                case PhaseKind.Preparing: mode = HudMode.Preparing; break;
                case PhaseKind.Countdown: mode = HudMode.Countdown; break;
                case PhaseKind.Drawing: mode = HudMode.Drawing; break;
                case PhaseKind.SelectingColor: mode = HudMode.SelectingColor; break;
                default: return;
            }
            if (p.Step >= plan.Steps.Count) return;
            hud.Show(new HudContent { Mode = mode, Countdown = p.Remaining, Fraction = DrawProgress, Color = plan.Steps[p.Step].Color, StepNumber = p.Step + 1, StepCount = plan.Steps.Count }, plan.Canvas);
        }

        // MARK: Quitting

        /// <summary>Stops a running pass and waits (≤ 2 s) until the worker has released the mouse button.</summary>
        public void PrepareForTermination(Action done)
        {
            Stop("Quitting");
            var deadline = DateTime.UtcNow.AddSeconds(2);
            Action wait = null;
            wait = () =>
            {
                if ((!engine.IsRunning && !replayer.IsRunning) || DateTime.UtcNow > deadline) { done(); return; }
                Ui.After(0.02, wait);
            };
            wait();
        }

        public static string ListFormat(List<string> names)
        {
            switch (names.Count)
            {
                case 0: return "another app";
                case 1: return names[0];
                case 2: return names[0] + " and " + names[1];
                default: return string.Join(", ", names.Take(names.Count - 1)) + " and " + names[names.Count - 1];
            }
        }

        public string PhaseDescription
        {
            get
            {
                var p = Phase;
                switch (p.Kind)
                {
                    case PhaseKind.Ready: return CanStart ? "Ready to draw" : "Not ready";
                    case PhaseKind.SelectingCanvas: return "Selecting canvas…";
                    case PhaseKind.AwaitingColor: return "Waiting for color " + (p.Step + 1);
                    case PhaseKind.Preparing: return "Getting ready…";
                    case PhaseKind.Obstructed: return "Canvas is covered";
                    case PhaseKind.Countdown: return "Starting in " + p.Remaining + "…";
                    case PhaseKind.Drawing: return "Drawing color " + (p.Step + 1) + " · " + (int)(DrawProgress * 100) + "%";
                    case PhaseKind.Paused: return "Paused — " + p.Message;
                    case PhaseKind.Finished: return "Done!";
                    case PhaseKind.SelectingColor: return "Selecting color " + (p.Step + 1) + "…";
                    default: return "Learning the color picker…";
                }
            }
        }

        // MARK: Automation (self test)

        /// <summary>Uses rect as the canvas without the selection overlay (the self test).</summary>
        public void SetCanvasForTesting(RectD rect)
        {
            Canvas = rect;
            Target = DrawTarget.None;
            Reprocess();
            CaptureTarget();
        }

        public void LoadImageForTesting(RGBAImage img, string name) => SetImage(img, name);
    }
}
