using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using DrawBot.Core;
using DrawBot.Win;

namespace DrawBot.App
{
    /// <summary>
    /// Calls then once the user has let go of Ctrl / Alt / Shift / Win and no click or key press has
    /// happened for quiet seconds (or after the deadline). Synthetic input inherits held modifiers,
    /// and many apps ignore input while a dialog is still animating closed.
    /// </summary>
    public static class ModifierWait
    {
        public static ActivityMonitor Activity;

        public static void WhenReleased(double quiet, DateTime deadline, Action then)
        {
            bool released = GlobalInputHook.HeldModifiers() == KeyModifiers.None;
            bool calm = Activity == null || Activity.SecondsSinceLastClickOrKey >= quiet;
            if ((released && calm) || DateTime.UtcNow > deadline) { then(); return; }
            Ui.After(0.05, () => WhenReleased(quiet, deadline, then));
        }
    }

    /// <summary>
    /// One Color Learn lesson:
    ///     demo(color A) ─Done─▶ demo(color B) ─Done─▶ analyze ─▶ trying(test color) ─▶ verify
    ///     verify ─Yes─▶ result(success)            verify ─No─▶ demo(that test color) ─▶ analyze …
    ///     verify ─Try again─▶ trying               any ─Cancel─▶ end
    /// While a demo prompt is up, the recorder captures the user's clicks and typing in the drawing
    /// app (never DrawBot's own panels).
    /// </summary>
    public sealed class ColorLearnSession
    {
        public sealed class Target
        {
            public string AppKey;
            public string AppName;
            public RectD Canvas;
            /// <summary>Brings the drawing app (or the Test Canvas) to the front, then calls back.</summary>
            public Action<Action> Activate;
            /// <summary>DrawBot windows whose events count as demonstration (the Test Canvas).</summary>
            public Func<IntPtr, bool> RecordsLocalWindow;
            public bool Careful;
            /// <summary>Claim (true) / release (false) the Esc key while DrawBot is trying the picker.</summary>
            public Action<bool> WatchEscape;
            /// <summary>Screen area to watch when learning preset colors (the drawing app's window).</summary>
            public RectD CaptureRect;
        }

        enum Stage { Demo, Trying, Verify, Result, Palette, PaletteChecking }

        readonly Target target;
        readonly PromptController prompt;
        readonly HudController hud;
        readonly InputReplayer replayer;
        readonly InputRecorder recorder = new InputRecorder();
        readonly Action<ColorPickerProfile, RGB?> onLearned;
        readonly Action onEnd;

        Stage stage = Stage.Demo;
        readonly List<ColorDemo> demos = new List<ColorDemo>();
        RGB demoColor = ColorLearner.DemoColors[0];
        RGB? demoPrevious;
        RGB? pickerColor;
        ColorPickerProfile candidate, learned;
        readonly HashSet<string> rejected = new HashSet<string>();
        int testIndex;
        RGB testColor = ColorLearner.TestColors[0];
        string noteText = "";
        int token;
        bool ended;
        public const int MaxDemos = 6;

        readonly DateTime startedAt = DateTime.Now;
        readonly List<string> events = new List<string>();
        string logPath;

        public ColorLearnSession(Target target, PromptController prompt, HudController hud, InputReplayer replayer,
                                 Action<ColorPickerProfile, RGB?> onLearned, Action onEnd)
        {
            this.target = target; this.prompt = prompt; this.hud = hud; this.replayer = replayer; this.onLearned = onLearned; this.onEnd = onEnd;
        }

        /// <summary>Everything that happened in this lesson, saved after every step (to diagnose a failed lesson).</summary>
        void Log(string e)
        {
            events.Add(Num.F((DateTime.Now - startedAt).TotalSeconds, 1) + "s " + e);
            try
            {
                if (logPath == null) logPath = Path.Combine(SettingsStore.LessonsFolder, "lesson_" + startedAt.ToString("yyyy-MM-dd_HH-mm-ss", CultureInfo.InvariantCulture) + ".json");
                var d = new Dictionary<string, object>
                {
                    { "appKey", target.AppKey }, { "appName", target.AppName }, { "canvas", LearnJson.Rect(target.Canvas) },
                    { "screens", Displays.ScreenRects().Select(r => LearnJson.Rect(r)).ToList<object>() },
                    { "startedAt", startedAt.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture) },
                    { "demos", demos.Select(LearnJson.Demo).ToList<object>() }, { "events", events.Cast<object>().ToList() },
                };
                File.WriteAllText(logPath, Json.Write(d));
            }
            catch (Exception) { }
        }

        public void Begin() => StartDemo(ColorLearner.DemoColors[0], null);

        public void Handle(PromptAction action)
        {
            if (action == PromptAction.Stop) { Cancel(); return; }
            switch (stage)
            {
                case Stage.Demo:
                    if (action == PromptAction.Proceed) FinishDemo();
                    else if (action == PromptAction.Redo) { noteText = ""; recorder.Clear(); ShowDemo(); }
                    else if (action == PromptAction.Palette) StartPalette();
                    break;
                case Stage.Verify:
                    if (action == PromptAction.Proceed) Accept();
                    else if (action == PromptAction.Retry) TryCandidate();
                    else if (action == PromptAction.No) RejectCandidate();
                    break;
                case Stage.Result:
                    if (action == PromptAction.Close) End();
                    else if (action == PromptAction.Redo) Restart();
                    break;
                case Stage.Palette:
                    if (action == PromptAction.Proceed) FinishPalette();
                    else if (action == PromptAction.Redo) StartPalette();
                    break;
            }
        }

        /// <summary>The Continue hotkey.</summary>
        public void HotkeyProceed()
        {
            switch (stage)
            {
                case Stage.Demo: FinishDemo(); break;
                case Stage.Verify: Accept(); break;
                case Stage.Result: if (learned != null) End(); else Restart(); break;
                case Stage.Palette: FinishPalette(); break;
            }
        }

        public void Escape() { if (stage == Stage.Trying) replayer.RequestStop(DrawingEngine.Reason.Escape); }

        public void Cancel()
        {
            if (stage == Stage.Trying) replayer.RequestStop("Canceled");
            End();
        }

        void End()
        {
            if (ended) return;
            Log(learned == null ? "lesson ended without a result" : "lesson finished");
            ended = true;
            token++;
            target.WatchEscape(false);
            recorder.Stop();
            prompt.Hide();
            hud.Hide();
            onEnd();
        }

        void Restart()
        {
            demos.Clear(); rejected.Clear(); candidate = null; learned = null; testIndex = 0; noteText = ""; pickerColor = null;
            StartDemo(ColorLearner.DemoColors[0], null);
        }

        /// <summary>Keep the prompt off the canvas and off the parts of the picker seen so far.</summary>
        RectD AvoidRect
        {
            get
            {
                var r = target.Canvas;
                foreach (var d in demos)
                    foreach (var e in d.Inputs)
                        if (e.Kind == InputKind.MouseDown && !target.Canvas.Contains(e.Point)) r = r.Union(RectD.At(e.Point).Inset(-20, -20));
                return r;
            }
        }

        void StartDemo(RGB color, RGB? previous)
        {
            stage = Stage.Demo;
            demoColor = color;
            demoPrevious = previous;
            int t = ++token;
            recorder.Stop();
            recorder.Clear();
            recorder.RecordsLocalWindow = target.RecordsLocalWindow;
            recorder.OnChange = RefreshDemo;
            ShowDemo();
            target.Activate(() =>
            {
                if (token != t || stage != Stage.Demo || ended) return;
                recorder.Start();
            });
        }

        PromptContent DemoContent() => new PromptContent
        {
            Mode = PromptModeKind.LearnDemo, Detail = recorder.Summary, Color = demoColor,
            Title = demos.Count < 2 ? "Teach DrawBot · color " + (demos.Count + 1) + " of 2" : "Teach DrawBot · one more example",
            AppName = target.AppName, Note = noteText,
        };

        void ShowDemo() => prompt.Show(DemoContent(), AvoidRect);

        void RefreshDemo()
        {
            if (stage != Stage.Demo || ended) return;
            prompt.Update(DemoContent());
        }

        void FinishDemo()
        {
            var inputs = recorder.Inputs.ToList();
            bool meaningful = inputs.Any(e => e.Kind == InputKind.MouseDown || (e.Kind == InputKind.KeyDown && !ColorLearner.IsHotkey(e)));
            if (!meaningful)
            {
                noteText = "DrawBot didn't see you click or type in " + target.AppName + " yet. Select the color there, then press Done.";
                RefreshDemo();
                return;
            }
            recorder.Stop();
            noteText = "";
            demos.Add(new ColorDemo(demoColor, demoPrevious, inputs));
            Log("demo " + demos.Count + " for " + demoColor.Hex + ": " + inputs.Count + " inputs (" + recorder.Summary + ")");
            pickerColor = demoColor;
            if (demos.Count < 2) StartDemo(ColorLearner.DemoColors[1], demoColor);
            else Analyze();
        }

        void Analyze()
        {
            var r = ColorLearner.Learn(demos, target.Canvas, Displays.ScreenRects(), target.AppKey, target.AppName, rejected);
            if (r.Ok)
            {
                Log("learned: " + r.Profile.Summary + " [" + r.Profile.HypothesisKey + "]");
                candidate = r.Profile;
                TryCandidate();
            }
            else
            {
                Log("learning failed: " + r.Failure);
                ShowResult(false, r.Failure);
            }
        }

        void TryCandidate(int attempt = 0)
        {
            if (candidate == null || ended) return;
            if (replayer.IsRunning)
            {
                if (attempt >= 40) { ShowResult(false, "DrawBot's previous try didn't finish."); return; }
                Ui.After(0.05, () => TryCandidate(attempt + 1));
                return;
            }
            stage = Stage.Trying;
            int t = ++token;
            testColor = ColorLearner.TestColors[testIndex % ColorLearner.TestColors.Length];
            prompt.Hide();
            hud.Show(new HudContent { Mode = HudMode.LearnTrying, Color = testColor }, target.Canvas);
            var profile = candidate;
            target.Activate(() => Ui.After(0.25, () =>
            {
                if (token != t) return;
                ModifierWait.WhenReleased(SettingEnums.PickerQuietPeriod, DateTime.UtcNow.AddSeconds(5), () =>
                {
                    if (token != t) return;
                    replayer.Careful = target.Careful;
                    replayer.StopOnUserMouseMove = true;
                    target.WatchEscape(true);
                    var actions = profile.Actions(testColor, pickerColor);
                    replayer.Run(actions, outcome => TryFinished(outcome, t));
                });
            }));
        }

        void TryFinished(InputReplayer.Outcome outcome, int t)
        {
            if (token == t) Log("try for " + testColor.Hex + ": " + outcome);
            if (token != t || ended) return;
            target.WatchEscape(false);
            hud.Hide();
            pickerColor = null;
            noteText = outcome.Kind == InputReplayer.OutcomeKind.Stopped
                ? "The try was interrupted (" + outcome.Reason + "). Press Try again, or No to show DrawBot yourself." : "";
            stage = Stage.Verify;
            prompt.Show(new PromptContent { Mode = PromptModeKind.LearnVerify, Color = testColor, Title = "Teach DrawBot · check", AppName = target.AppName, Note = noteText }, AvoidRect);
        }

        void Accept()
        {
            Log("user: yes, it worked");
            if (candidate == null) return;
            var p = candidate.Copy();
            p.LearnedAt = DateTime.UtcNow;
            learned = p;
            pickerColor = testColor;
            onLearned(p, testColor);
            var how = p.IsExact ? "It types the color, so colors come out exact." : "It clicks positions, so a color can be off by a little.";
            ShowResult(true, p.Summary + "\n" + how + "\n\nWith Color selection set to automatic, DrawBot now selects every color in " + target.AppName + " by itself. Keep the color picker where it is; if it moves, learn it again.");
        }

        void RejectCandidate()
        {
            Log("user: no");
            if (candidate == null) return;
            rejected.Add(candidate.HypothesisKey);
            var failed = testColor;
            testIndex++;
            // A typed profile repeats exactly what the user typed: if that gave the wrong color, the
            // app itself changes typed values, and demonstrating the same way again can't help.
            if (candidate.IsExact)
            {
                bool typedHex = candidate.TypedSlots.Any(s => s.IsHex);
                var other = typedHex ? "type the R, G and B values into their fields instead, or click the color in the picker" : "click the color in the picker instead";
                ShowResult(false, "DrawBot typed exactly what you typed, so " + target.AppName + " itself changed the color. Some apps convert typed values wrongly. Start over and " + other + ".");
                return;
            }
            if (demos.Count >= MaxDemos)
            {
                ShowResult(false, "None of DrawBot's " + rejected.Count + " interpretations of your clicks worked. Start over and type the color's values instead (its hex code, or R, G and B), if your color picker has fields for them.");
                return;
            }
            noteText = "DrawBot's try didn't work. Select this color yourself once more so DrawBot can learn from it.";
            StartDemo(failed, null);
        }

        void ShowResult(bool success, string message, List<RGB> swatches = null)
        {
            stage = Stage.Result;
            recorder.Stop();
            prompt.Show(new PromptContent
            {
                Mode = PromptModeKind.LearnResult, Success = success, Detail = message, Title = "Color Learn", AppName = target.AppName,
                Swatches = swatches ?? new List<RGB>(),
            }, target.Canvas);
        }

        // MARK: Preset colors

        RGBAImage paletteBaseline;
        readonly List<PointD> paletteClicks = new List<PointD>();
        readonly List<int> paletteClickCounts = new List<int>();
        readonly List<RGBAImage> paletteFrames = new List<RGBAImage>();
        int pendingCaptures;
        RectD paletteRect;
        List<RGB> paletteColorsSoFar = new List<RGB>();
        const int MaxSwatches = 64;

        void StartPalette()
        {
            int t = ++token;
            recorder.Stop();
            recorder.Clear();
            paletteBaseline = null;
            paletteClicks.Clear(); paletteClickCounts.Clear(); paletteFrames.Clear(); paletteColorsSoFar = new List<RGB>();
            pendingCaptures = 0;
            stage = Stage.Palette;
            noteText = "";
            paletteRect = target.CaptureRect;
            Log("palette lesson started, watching " + paletteRect);
            ShowPalettePrompt(true);
            target.Activate(() => Ui.After(0.4, () =>
            {
                if (token != t || stage != Stage.Palette) return;
                // The colors are read from this first screenshot: take it before listening for clicks.
                paletteBaseline = Capture(t);
                if (token != t || stage != Stage.Palette) return;
                recorder.RecordsLocalWindow = target.RecordsLocalWindow;
                recorder.OnChange = () => PaletteInput(t);
                recorder.Start();
            }));
        }

        RGBAImage Capture(int t)
        {
            try { return ScreenSampler.Capture(paletteRect); }
            catch (Exception e)
            {
                Log("palette: screenshot failed (" + e.Message + ")");
                return null;
            }
        }

        void ShowPalettePrompt(bool initial = false)
        {
            var c = new PromptContent
            {
                Mode = PromptModeKind.LearnPalette, Detail = paletteClicks.Count + " color button" + (paletteClicks.Count == 1 ? "" : "s") + " clicked",
                Title = "Teach DrawBot · preset colors", AppName = target.AppName, Note = noteText, Swatches = paletteColorsSoFar,
            };
            if (initial) prompt.Show(c, target.Canvas.Union(paletteRect.Inset(40, 40)));
            else prompt.Update(c);
        }

        /// <summary>After every click: wait for the app to show the new color, then take a screenshot.</summary>
        void PaletteInput(int t)
        {
            if (token != t || stage != Stage.Palette || recorder.Inputs.Count == 0) return;
            var last = recorder.Inputs[recorder.Inputs.Count - 1];
            if (last.Kind != InputKind.MouseUp || paletteClicks.Count >= MaxSwatches) return;
            paletteClicks.Add(last.Point);
            paletteClickCounts.Add(last.ClickCount);
            int index = paletteClicks.Count - 1;
            pendingCaptures++;
            Ui.After(0.45, () =>
            {
                pendingCaptures--;
                if (token != t) return;
                var frame = Capture(t);
                while (paletteFrames.Count < index) paletteFrames.Add(paletteFrames.Count > 0 ? paletteFrames[paletteFrames.Count - 1] : paletteBaseline);
                if (frame != null) paletteFrames.Add(frame);
                else if (paletteFrames.Count > 0 || paletteBaseline != null) paletteFrames.Add(paletteFrames.Count > 0 ? paletteFrames[paletteFrames.Count - 1] : paletteBaseline);
                ShowPalettePrompt();
            });
            ShowPalettePrompt();
        }

        void FinishPalette(int attempt = 0)
        {
            if (stage != Stage.Palette && stage != Stage.PaletteChecking) return;
            int t = token;
            recorder.Stop();
            stage = Stage.PaletteChecking;
            if (pendingCaptures > 0 && attempt < 40) { Ui.After(0.1, () => { if (token == t) FinishPalette(attempt + 1); }); return; }
            if (paletteBaseline == null || paletteClicks.Count < 2)
            {
                stage = Stage.Palette;
                noteText = paletteClicks.Count < 2 ? "Click at least two of the color buttons (ideally all of them), then press Done."
                    : "DrawBot couldn't take screenshots. Start over.";
                recorder.Start();
                ShowPalettePrompt();
                return;
            }
            var rect = paletteRect;
            var local = paletteClicks.Select(p => new PointD(p.X - rect.X, p.Y - rect.Y)).ToList();
            var colors = PaletteLearner.Analyze(paletteBaseline, paletteFrames, local);
            if (colors == null) { ShowResult(false, "DrawBot couldn't read the colors from the screenshots. Start over and click each color button once more."); return; }
            paletteColorsSoFar = colors.ToList();
            var swatches = PaletteLearner.Swatches(paletteClicks, colors, paletteClickCounts);
            Log("palette: " + swatches.Count + " preset colors read from the clicked spots: " + string.Join(" ", swatches.Select(s => s.Color.Hex)));
            var bounds = RectD.At(swatches[0].Point);
            foreach (var s in swatches.Skip(1)) bounds = bounds.Union(RectD.At(s.Point));
            var profile = new ColorPickerProfile
            {
                AppKey = target.AppKey, AppName = target.AppName, Summary = "Clicks one of " + swatches.Count + " preset color buttons; the picture's colors are moved to the closest ones.",
                LearnedAt = DateTime.UtcNow, HypothesisKey = "palette:" + swatches.Count, PointerBounds = bounds.Inset(-30, -30), IsExact = true, Swatches = swatches,
            };
            candidate = profile;
            learned = profile;
            onLearned(profile, pickerColor);
            Log("palette learned");
            ShowResult(true, "Found " + swatches.Count + " preset colors, each read from the spot you clicked; check them below. If one looks wrong, start over and click nearer the middle of that button.\n\nWhen drawing, DrawBot moves the picture's colors to the closest preset colors and clicks the right button for each. Keep the app where it is; if the buttons move, teach it again.",
                swatches.Select(s => s.Color).ToList());
        }
    }
}
