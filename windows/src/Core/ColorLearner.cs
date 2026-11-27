using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace DrawBot.Core
{
    public sealed class LearnResult
    {
        public ColorPickerProfile Profile;
        public string Failure;
        public bool Ok => Profile != null;
        public static LearnResult Success(ColorPickerProfile p) => new LearnResult { Profile = p };
        public static LearnResult Fail(string m) => new LearnResult { Failure = m };
    }

    /// <summary>
    /// Learns how to drive a color picker from demonstrations.
    /// 1. Each demo's events are segmented into actions: pointer gestures and runs of keystrokes.
    /// 2. The demos are aligned action by action (dynamic programming); only actions present in every demo are kept.
    /// 3. Typing: typed / pasted text is split into numbers and hex codes, each matched against the
    ///    color's hex, RGB, HSB and HSL values at several scales.
    /// 4. Pointer: a gesture on the same spot in every demo is a fixed click; one that moves is a
    ///    color control, explained by sliders, areas, wheels or hue rings fitted by least squares
    ///    and scored by fit, plausibility, consistency and how common the layout is.
    /// </summary>
    public static class ColorLearner
    {
        /// <summary>The two colors the user demonstrates first: far apart on any picker.</summary>
        public static readonly RGB[] DemoColors = {
            ColorMath.RgbFromHsb(30, 80, 90),
            ColorMath.RgbFromHsb(210, 35, 45),
        };

        /// <summary>Colors DrawBot tries by itself to check what it learned.</summary>
        public static readonly RGB[] TestColors = {
            ColorMath.RgbFromHsb(135, 55, 70),
            ColorMath.RgbFromHsb(290, 65, 60),
            ColorMath.RgbFromHsb(75, 30, 95),
            ColorMath.RgbFromHsb(345, 90, 35),
        };

        /// <summary>Distance within which a pointer gesture counts as "the same spot" in every demo.</summary>
        public const double FixedTolerance = 10.0;

        public static LearnResult Learn(IList<ColorDemo> demos, RectD? canvas, IList<RectD> screens, string appKey, string appName,
                                        ISet<string> rejected = null, DateTime? now = null)
        {
            rejected = rejected ?? new HashSet<string>();
            if (demos.Count < 2) return LearnResult.Fail("DrawBot needs at least two demonstrations.");
            var actionLists = demos.Select(d => Segment(d.Inputs)).ToList();
            for (int i = 0; i < actionLists.Count; i++)
                if (actionLists[i].Count == 0)
                    return LearnResult.Fail("DrawBot didn't see any clicks or typing for color " + (i + 1) + " (" + demos[i].Color.Hex + ").");

            int refI = 0;
            for (int i = 0; i < actionLists.Count; i++) if (actionLists[i].Count <= actionLists[refI].Count) refI = i;
            var order = new List<int> { refI };
            order.AddRange(Enumerable.Range(0, actionLists.Count).Where(i => i != refI));
            var groups = actionLists[refI].Select(a => new List<DemoAction> { a }).ToList();
            var keep = Enumerable.Repeat(true, groups.Count).ToArray();
            var matches = new Dictionary<int, int?[]>();
            foreach (var d in order.Skip(1))
            {
                var match = Align(actionLists[refI], actionLists[d]);
                matches[d] = match;
                for (int i = 0; i < groups.Count; i++)
                {
                    if (match[i].HasValue) groups[i].Add(actionLists[d][match[i].Value]);
                    else keep[i] = false;
                }
            }
            var keptIdx = Enumerable.Range(0, groups.Count).Where(i => keep[i]).ToList();
            var keptIndices = new Dictionary<int, HashSet<int>> { { refI, new HashSet<int>(keptIdx) } };
            foreach (var d in order.Skip(1))
                keptIndices[d] = new HashSet<int>(keptIdx.Where(i => matches[d][i].HasValue).Select(i => matches[d][i].Value));
            var colors = order.Select(i => demos[i].Color).ToList();
            var previous = order.Select(i => demos[i].PreviousColor).ToList();
            var kept = keptIdx.Select(i => groups[i]).ToList();
            if (kept.Count == 0)
                return LearnResult.Fail("The demonstrations had nothing in common. Select both colors the same way (same controls, same order).");

            // Delays: most of the shortest pause the user left before each action, capped.
            var delays = new List<double>();
            for (int k = 0; k < kept.Count; k++)
            {
                if (k == 0) { delays.Add(0.1); continue; }
                var g = kept[k]; var prev = kept[k - 1];
                var gaps = g.Zip(prev, (a, b) => a.Start - b.End).ToList();
                double gap = gaps.Count > 0 ? gaps.Min() : 0.2;
                double dly = Math.Min(Math.Max(gap * 0.8, 0.15), 1.2);
                if (g[0].Keys != null && prev[0].Gesture != null) dly = Math.Max(dly, 0.15);
                delays.Add(dly);
            }

            // Typing.
            var typingSteps = new Dictionary<int, TypingAnalysis>();
            var typedParams = new HashSet<ColorParam>();
            var unresolvedTyping = new List<string>();
            for (int k = 0; k < kept.Count; k++)
            {
                var g = kept[k];
                var runs = g.Where(a => a.Keys != null).Select(a => a.Keys).ToList();
                if (runs.Count != g.Count) continue;
                var analysis = AnalyzeTyping(runs, colors, delays[k]);
                typingSteps[k] = analysis;
                typedParams.UnionWith(analysis.Params);
                unresolvedTyping.AddRange(analysis.Unresolved);
            }
            bool typingDetermines = PickerColorSpaces.Determines(typedParams);

            // Pointer controls.
            var obsByGroup = new Dictionary<int, List<Obs>>();
            var spreads = new Dictionary<int, double>();
            for (int k = 0; k < kept.Count; k++)
            {
                var g = kept[k];
                var gestures = g.Where(a => a.Gesture != null).Select(a => a.Gesture).ToList();
                if (gestures.Count != g.Count) continue;
                obsByGroup[k] = gestures.Select((x, i) => new Obs { Color = colors[i], Previous = previous[i], Down = x.Down, Up = x.Up, IsDrag = x.IsDrag }).ToList();
                spreads[k] = MaxPairwise(gestures.Select(x => x.Up).ToList());
            }
            var varying = obsByGroup.Keys.Where(k => spreads[k] > FixedTolerance).OrderBy(k => k).ToList();
            var onCanvas = new HashSet<int>(obsByGroup.Keys.Where(k => canvas.HasValue && obsByGroup[k].All(o => canvas.Value.Contains(o.Up))));
            var fixedPenalties = varying.Select(k => onCanvas.Contains(k) ? Math.Min(spreads[k] / 12, 1) : spreads[k] / 12).ToList();
            RectD? bounds = null;
            if (screens.Count > 0) { var b = screens[0]; foreach (var s in screens.Skip(1)) b = b.Union(s); bounds = b; }

            Hypothesis best = null;
            if (typingDetermines || varying.Count == 0)
            {
                if (!typingDetermines)
                {
                    if (unresolvedTyping.Count > 0)
                        return LearnResult.Fail("DrawBot couldn't tell how what you typed (" + string.Join(", ", unresolvedTyping.Take(3)) + ") relates to the color. Type the hex code, RGB or HSB values exactly as DrawBot shows them.");
                    return LearnResult.Fail("Nothing changed between the two colors: every click landed on the same spot and nothing color-related was typed. Select each color inside the picker itself (or type its hex code).");
                }
                var h = new Hypothesis { Space = null, Fits = Enumerable.Repeat<ControlFit>(null, varying.Count).ToList(), Score = 0, Key = "typed:" + Signature(kept, typingSteps) };
                if (!rejected.Contains(h.Key)) best = h;
            }
            else
            {
                var all = new List<Hypothesis>();
                foreach (var space in PickerColorSpaces.All)
                {
                    if (!typedParams.IsSubsetOf(space.Params())) continue;
                    var needed = new HashSet<ColorParam>(space.Params());
                    needed.ExceptWith(typedParams);
                    var controls = varying.Select(k => obsByGroup[k]).ToList();
                    all.AddRange(Search(controls, fixedPenalties, space, needed, bounds, typedParams.Count));
                }
                foreach (var hyp in all)
                {
                    hyp.Key = (hyp.Space.HasValue ? hyp.Space.Value.RawName() : "-") + ":"
                        + string.Join(";", hyp.Fits.Select((f, i) => i + "=" + (f != null ? f.Label : "fixed")))
                        + "|" + Signature(kept, typingSteps);
                }
                foreach (var hyp in all)
                {
                    if (rejected.Contains(hyp.Key)) continue;
                    if (best == null || best.Score < hyp.Score) best = hyp;
                }
            }
            if (best == null)
                return LearnResult.Fail("DrawBot couldn't work out how this color picker turns positions into colors. Typing the hex code into the picker's hex field always works, if your app has one.");
            var chosen = best;

            Func<int, bool> isColorControl = k =>
            {
                int vi = varying.IndexOf(k);
                return vi >= 0 && chosen.Fits[vi] != null;
            };
            var testStrokes = new HashSet<int>();
            foreach (var k in onCanvas)
            {
                if (isColorControl(k)) continue;
                var obs = obsByGroup[k];
                if (obs.Count(o => o.IsDrag) * 2 > obs.Count || spreads[k] > FixedTolerance) testStrokes.Add(k);
            }
            bool pickerOverCanvas = onCanvas.Any(k => !testStrokes.Contains(k));
            if (pickerOverCanvas)
            {
                int lastNonTest = -1;
                for (int k = kept.Count - 1; k >= 0; k--) if (!testStrokes.Contains(k)) { lastNonTest = k; break; }
                var problem = CheckPickerOverCanvas(lastNonTest >= 0 && isColorControl(lastNonTest), actionLists, order, keptIndices, canvas.Value);
                if (problem != null) return LearnResult.Fail(problem);
            }

            var steps = new List<PickerStep>();
            var describeParts = new List<string>();
            int fixedClicks = 0;
            var allPoints = new List<PointD>();
            for (int k = 0; k < kept.Count; k++)
            {
                if (testStrokes.Contains(k)) continue;
                TypingAnalysis t;
                if (typingSteps.TryGetValue(k, out t)) { steps.Add(PickerStep.Of(t.Step)); continue; }
                List<Obs> obs;
                if (!obsByGroup.TryGetValue(k, out obs) || kept[k][0].Gesture == null) continue;
                var refGesture = kept[k][0].Gesture;
                foreach (var o in obs) { allPoints.Add(o.Down); allPoints.Add(o.Up); }
                bool isDrag = obs.Count(o => o.IsDrag) * 2 > obs.Count;
                var mapping = ControlMapping.Fixed(Mean(obs.Select(o => o.Up).ToList()));
                bool grabs = false;
                int vi = varying.IndexOf(k);
                if (vi >= 0 && chosen.Fits[vi] != null)
                {
                    mapping = chosen.Fits[vi].Mapping;
                    describeParts.Add(mapping.Describe);
                    var withPrev = obs.Where(o => o.IsDrag && o.Previous.HasValue).ToList();
                    var grabbed = withPrev.Where(o => Distance(mapping.Point(o.Previous.Value), o.Down) <= 14 && Distance(o.Down, o.Up) > 14).ToList();
                    grabs = grabbed.Count > 0 && grabbed.Count * 2 >= withPrev.Count;
                }
                else fixedClicks++;
                PointD? fixedDragStart = isDrag ? Mean(obs.Select(o => o.Down).ToList()) : (PointD?)null;
                steps.Add(PickerStep.Of(new PointerStep
                {
                    Mapping = mapping, Button = refGesture.Button, ClickCount = refGesture.ClickCount, Modifiers = refGesture.Modifiers,
                    IsDrag = isDrag, DragStart = fixedDragStart, GrabsKnob = grabs, DelayBefore = delays[k],
                }));
            }

            string summary;
            var uniqueSlots = new List<string>();
            foreach (var k in typingSteps.Keys.OrderBy(x => x))
                foreach (var s in typingSteps[k].SlotNames)
                    if (!uniqueSlots.Contains(s)) uniqueSlots.Add(s);
            if (uniqueSlots.Count > 0)
            {
                summary = "Types the color's " + ListFormat(uniqueSlots);
                if (describeParts.Count > 0) summary += " and clicks " + ListFormat(describeParts);
            }
            else
            {
                summary = "Clicks " + ListFormat(describeParts);
                if (chosen.Space.HasValue) summary += " (" + chosen.Space.Value.RawName().ToUpperInvariant() + ")";
            }
            if (fixedClicks > 0) summary += ", plus " + fixedClicks + " fixed click" + (fixedClicks == 1 ? "" : "s");
            summary += ".";

            var keyMap = new Dictionary<string, KeyStroke>();
            foreach (var demo in demos)
                foreach (var e in demo.Inputs)
                    if (e.Kind == InputKind.KeyDown && IsTextKey(e) && e.Characters.Length == 1)
                        keyMap[e.Characters] = new KeyStroke(e.KeyCode, e.Characters, e.Modifiers & (KeyModifiers.Shift | KeyModifiers.Option));

            RectD? pointerBounds = null;
            if (allPoints.Count > 0)
            {
                var r = RectD.At(allPoints[0]);
                foreach (var p in allPoints.Skip(1)) r = r.Union(RectD.At(p));
                pointerBounds = r.Inset(-30, -30);
            }

            return LearnResult.Success(new ColorPickerProfile
            {
                AppKey = appKey, AppName = appName, Steps = steps, KeyMap = keyMap,
                Space = typingDetermines ? null : chosen.Space, Summary = summary, LearnedAt = now ?? DateTime.UtcNow,
                HypothesisKey = chosen.Key, PointerBounds = pointerBounds, IsExact = typingDetermines,
            });
        }

        // MARK: - Segmentation

        public sealed class Gesture
        {
            public PointerButton Button;
            public int ClickCount;
            public KeyModifiers Modifiers;
            public PointD Down, Up;
            public double Travel, Start, End;
            public bool IsDrag => Travel > 3;
            public Gesture Clone() => (Gesture)MemberwiseClone();
        }

        public sealed class KeyRun
        {
            public List<RecordedInput> Keys = new List<RecordedInput>();
            public double Start, End;
        }

        public sealed class DemoAction
        {
            public Gesture Gesture;
            public KeyRun Keys;
            public double Start => Gesture != null ? Gesture.Start : Keys.Start;
            public double End => Gesture != null ? Gesture.End : Keys.End;
        }

        /// <summary>DrawBot's own Ctrl+Alt+Shift hotkeys.</summary>
        public static bool IsHotkey(RecordedInput e)
        {
            var need = KeyModifiers.Control | KeyModifiers.Option | KeyModifiers.Shift;
            return (e.Modifiers & need) == need;
        }

        public static List<DemoAction> Segment(IList<RecordedInput> inputs)
        {
            var sorted = inputs.Select((e, i) => new { e, i }).OrderBy(x => x.e.Time).ThenBy(x => x.i).Select(x => x.e).ToList();
            var actions = new List<DemoAction>();
            Gesture open = null;
            KeyRun run = null;

            System.Action flushRun = () => { if (run != null) actions.Add(new DemoAction { Keys = run }); run = null; };
            Action<Gesture> appendGesture = g0 =>
            {
                var g = g0.Clone();
                var last = actions.Count > 0 ? actions[actions.Count - 1].Gesture : null;
                if (last != null && last.Button == g.Button && !last.IsDrag && !g.IsDrag && Distance(last.Up, g.Down) <= 5 && g.Start - last.End <= 0.5)
                {
                    // Second / third press of a multi-click; count quick presses on the same spot ourselves.
                    g.ClickCount = Math.Min(3, Math.Max(g.ClickCount, last.ClickCount + 1));
                    actions[actions.Count - 1] = new DemoAction { Gesture = g };
                    return;
                }
                if (last != null && last.Button == g.Button && Distance(last.Up, g.Down) <= 5)
                {
                    if (g.ClickCount >= 2 && g.Start - last.End <= 0.8) { actions[actions.Count - 1] = new DemoAction { Gesture = g }; return; }
                }
                if (last != null && last.Button == g.Button && g.ClickCount == 1 && Distance(last.Up, g.Down) <= 12)
                {
                    // A small correction of the previous click on the same control.
                    actions[actions.Count - 1] = new DemoAction { Gesture = g };
                    return;
                }
                actions.Add(new DemoAction { Gesture = g });
            };

            foreach (var e in sorted)
            {
                switch (e.Kind)
                {
                    case InputKind.MouseDown:
                        if (open != null) appendGesture(open);
                        flushRun();
                        open = new Gesture { Button = e.Button, ClickCount = Math.Max(1, e.ClickCount), Modifiers = e.Modifiers, Down = e.Point, Up = e.Point, Travel = 0, Start = e.Time, End = e.Time };
                        break;
                    case InputKind.MouseDragged:
                        if (open == null || open.Button != e.Button) continue;
                        open.Up = e.Point; open.Travel = Math.Max(open.Travel, Distance(open.Down, e.Point)); open.End = e.Time;
                        break;
                    case InputKind.MouseUp:
                        if (open == null || open.Button != e.Button) continue;
                        open.Up = e.Point; open.Travel = Math.Max(open.Travel, Distance(open.Down, e.Point)); open.End = e.Time;
                        appendGesture(open);
                        open = null;
                        break;
                    case InputKind.KeyDown:
                        if (IsHotkey(e)) continue;
                        if (run == null) run = new KeyRun { Start = e.Time, End = e.Time };
                        run.Keys.Add(e);
                        run.End = e.Time;
                        break;
                }
            }
            if (open != null) appendGesture(open);
            flushRun();
            return actions;
        }

        // MARK: - Pickers on top of the canvas

        /// <summary>
        /// A picker that pops up over the canvas must be closed at the start and end of every
        /// selection: DrawBot's obstruction check cannot see a popup inside the drawing app's own
        /// window. Returns a message when the demonstrations show this isn't the case.
        /// </summary>
        static string CheckPickerOverCanvas(bool lastIsColorControl, List<List<DemoAction>> actionLists, List<int> order,
                                            Dictionary<int, HashSet<int>> keptIndices, RectD canvas)
        {
            foreach (var d in order)
            {
                HashSet<int> ki;
                if (!keptIndices.TryGetValue(d, out ki) || ki.Count == 0) continue;
                int firstKept = ki.Min();
                if (firstKept <= 0) continue;
                bool skipped = actionLists[d].Take(firstKept).Any(a => a.Gesture != null && !canvas.Contains(a.Gesture.Up));
                if (skipped)
                    return "Your color picker sits on top of the canvas, so DrawBot has to open it before every color and close it again before drawing. In one demonstration you clicked something first (probably to open the picker) that you didn't click in the other, which usually means the picker was still open. Start over, and for every color: start with the picker closed, open it, choose the color, close it again, then press Done.";
            }
            if (lastIsColorControl)
                return "Your color picker sits on top of the canvas, but it was still open when you pressed Done. DrawBot would draw into it. Start over, and for every color: open the picker, choose the color, close the picker (its close or OK button, or the button that opened it), then press Done.";
            return null;
        }

        // MARK: - Alignment

        /// <summary>For each action of a, the index of the matching action in b (or null).</summary>
        public static int?[] Align(List<DemoAction> a, List<DemoAction> b)
        {
            int n = a.Count, m = b.Count;
            const double gap = 2.0;
            var cost = new double[n + 1, m + 1];
            for (int i = 0; i <= n; i++) cost[i, 0] = i * gap;
            for (int j = 0; j <= m; j++) cost[0, j] = j * gap;
            for (int i = 1; i <= n; i++)
                for (int j = 1; j <= m; j++)
                {
                    double c = MatchCost(a[i - 1], b[j - 1]);
                    cost[i, j] = Math.Min(cost[i - 1, j - 1] + c, Math.Min(cost[i - 1, j] + gap, cost[i, j - 1] + gap));
                }
            var result = new int?[n];
            int ii = n, jj = m;
            while (ii > 0 && jj > 0)
            {
                double c = MatchCost(a[ii - 1], b[jj - 1]);
                if (!double.IsInfinity(c) && Math.Abs(cost[ii, jj] - (cost[ii - 1, jj - 1] + c)) < 1e-9)
                {
                    result[ii - 1] = jj - 1;
                    ii--; jj--;
                }
                else if (Math.Abs(cost[ii, jj] - (cost[ii - 1, jj] + gap)) < 1e-9) ii--;
                else jj--;
            }
            return result;
        }

        static double MatchCost(DemoAction a, DemoAction b)
        {
            if (a.Gesture != null && b.Gesture != null)
            {
                var x = a.Gesture; var y = b.Gesture;
                if (x.Button != y.Button) return double.PositiveInfinity;
                double extra = x.ClickCount == y.ClickCount ? 0 : 0.3;
                double d = Distance(x.Up, y.Up);
                if (d <= FixedTolerance) return extra;
                double shared = Math.Min(Math.Abs(x.Up.X - y.Up.X), Math.Abs(x.Up.Y - y.Up.Y));
                return 0.6 + Math.Min(shared / 120, 1.2) + extra;
            }
            if (a.Keys != null && b.Keys != null)
            {
                var sx = Pieces(a.Keys).Select(p => p.Signature); var sy = Pieces(b.Keys).Select(p => p.Signature);
                return sx.SequenceEqual(sy) ? 0.2 : 1.0;
            }
            return double.PositiveInfinity;
        }

        // MARK: - Typing

        public sealed class RawPiece : IEquatable<RawPiece>
        {
            public KeyStroke Key;
            public string Text;
            public string Signature => Key != null ? "k" + Key.KeyCode + "/" + (int)Key.Modifiers : "t";
            public bool Equals(RawPiece o) => o != null && Equals(Key, o.Key) && Text == o.Text;
            public override bool Equals(object obj) => Equals(obj as RawPiece);
            public override int GetHashCode() => Signature.GetHashCode();
        }

        public static bool IsTextKey(RecordedInput e)
        {
            if ((e.Modifiers & (KeyModifiers.Command | KeyModifiers.Control)) != 0 || VirtualKey.NonText.Contains(e.KeyCode) || e.Characters.Length == 0)
                return false;
            return e.Characters.All(ch => ch >= 0x20 && ch != 0x7F && !(ch >= 0xF700 && ch <= 0xF8FF));
        }

        static bool IsPaste(RecordedInput e)
        {
            if (e.PasteText == null) return false;
            bool ctrlV = (e.Modifiers & KeyModifiers.Control) != 0 && (e.Characters.ToLowerInvariant() == "v" || e.KeyCode == VirtualKey.V);
            bool shiftInsert = (e.Modifiers & KeyModifiers.Shift) != 0 && e.KeyCode == VirtualKey.Insert;
            return ctrlV || shiftInsert;
        }

        public static List<RawPiece> Pieces(KeyRun run)
        {
            var outp = new List<RawPiece>();
            string text = "";
            System.Action flush = () => { if (text.Length > 0) outp.Add(new RawPiece { Text = text }); text = ""; };
            foreach (var e in run.Keys)
            {
                var stroke = new KeyStroke(e.KeyCode, e.Characters, e.Modifiers);
                if (IsTextKey(e)) text += e.Characters;
                else if (e.KeyCode == VirtualKey.Delete && e.Modifiers == KeyModifiers.None && text.Length > 0) text = text.Substring(0, text.Length - 1);
                else if (IsPaste(e)) text += e.PasteText;   // a pasted value counts as typed
                else { flush(); outp.Add(new RawPiece { Key = stroke }); }
            }
            flush();
            return outp;
        }

        public sealed class TypingAnalysis
        {
            public TypingStep Step;
            public HashSet<ColorParam> Params;
            public List<string> Unresolved;
            public List<string> SlotNames;
        }

        /// <summary>runs[i] was typed for colors[i]; runs[0] is the reference.</summary>
        public static TypingAnalysis AnalyzeTyping(List<KeyRun> runs, List<RGB> colors, double delay)
        {
            var all = runs.Select(Pieces).ToList();
            var refP = all[0];
            var refSig = refP.Select(p => p.Signature).ToList();
            bool consistent = all.All(p => p.Select(x => x.Signature).SequenceEqual(refSig));
            var outp = new List<TypingPiece>();
            var ps = new HashSet<ColorParam>();
            var unresolved = new List<string>();
            var names = new List<string>();
            for (int idx = 0; idx < refP.Count; idx++)
            {
                var piece = refP[idx];
                if (piece.Key != null) { outp.Add(TypingPiece.KeyPiece(piece.Key)); continue; }
                var template = new TextTemplate(new[] { TextPart.Lit(piece.Text) });
                if (consistent)
                {
                    var strings = all.Select(p => p[idx].Text ?? "").ToList();
                    List<string> bad;
                    template = BuildTemplate(strings, colors, out bad);
                    unresolved.AddRange(bad);
                }
                else if (all.Any(p => !p.SequenceEqual(refP)))
                    unresolved.Add("“" + piece.Text + "”");
                foreach (var slot in template.Slots)
                {
                    ps.UnionWith(slot.Params);
                    names.Add(slot.DisplayName);
                }
                outp.Add(TypingPiece.TextPiece(template));
            }
            return new TypingAnalysis { Step = new TypingStep { Pieces = outp, DelayBefore = delay }, Params = ps, Unresolved = unresolved, SlotNames = names };
        }

        /// <summary>Splits each string into tokens (runs of hex digits / '.') and literals; differing tokens become slots when one interpretation fits every demo.</summary>
        public static TextTemplate BuildTemplate(List<string> strings, List<RGB> colors, out List<string> unresolved)
        {
            unresolved = new List<string>();
            var toks = strings.Select(Tokenize).ToList();
            var refT = toks[0];
            bool sameShape = toks.All(t => t.Count == refT.Count && t.Zip(refT, (x, y) => x.Value == y.Value && (x.Value || x.Key == y.Key)).All(z => z));
            if (!sameShape)
            {
                if (strings.All(s => s == strings[0])) return new TextTemplate(new[] { TextPart.Lit(strings[0]) });
                unresolved.Add("“" + strings[0] + "”");
                return new TextTemplate(new[] { TextPart.Lit(strings[0]) });
            }
            var parts = new List<TextPart>();
            for (int i = 0; i < refT.Count; i++)
            {
                string text = refT[i].Key; bool isToken = refT[i].Value;
                var texts = toks.Select(t => t[i].Key).ToList();
                if (!isToken || texts.All(t => t == text)) { parts.Add(TextPart.Lit(text)); continue; }
                var common = Candidates(texts[0], colors[0]);
                for (int k = 1; k < texts.Count; k++) common.IntersectWith(Candidates(texts[k], colors[k]));
                var slot = common.OrderBy(s => s.Priority).ThenBy(s => s.ToString(), StringComparer.Ordinal).FirstOrDefault();
                if (slot != null) parts.Add(TextPart.Of(slot));
                else { parts.Add(TextPart.Lit(text)); unresolved.Add("“" + text + "”"); }
            }
            var merged = new List<TextPart>();
            foreach (var p in parts)
            {
                if (!p.IsSlot && merged.Count > 0 && !merged[merged.Count - 1].IsSlot)
                    merged[merged.Count - 1] = TextPart.Lit(merged[merged.Count - 1].Literal + p.Literal);
                else merged.Add(p);
            }
            return new TextTemplate(merged);
        }

        static bool IsHexDigit(char c) => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');

        public static List<KeyValuePair<string, bool>> Tokenize(string s)
        {
            var outp = new List<KeyValuePair<string, bool>>();
            string cur = ""; bool curIsToken = false;
            foreach (var ch in s)
            {
                bool t = IsHexDigit(ch) || ch == '.';
                if (t != curIsToken && cur.Length > 0) { outp.Add(new KeyValuePair<string, bool>(cur, curIsToken)); cur = ""; }
                curIsToken = t;
                cur += ch;
            }
            if (cur.Length > 0) outp.Add(new KeyValuePair<string, bool>(cur, curIsToken));
            return outp;
        }

        static double[] Scales(ColorParam p)
        {
            switch (p)
            {
                case ColorParam.Red: case ColorParam.Green: case ColorParam.Blue: return new double[] { 255, 100, 1 };
                case ColorParam.Hue: return new double[] { 360, 100, 1, 240 };
                default: return new double[] { 100, 255, 1, 240 };
            }
        }

        /// <summary>Every interpretation of token that matches color c.</summary>
        public static HashSet<ValueSlot> Candidates(string token, RGB c)
        {
            var outp = new HashSet<ValueSlot>();
            int v;
            if (token.Length == 6 && token.All(IsHexDigit) && int.TryParse(token, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v))
            {
                int r = (v >> 16) & 255, g = (v >> 8) & 255, b = v & 255;
                if (Math.Abs(r - c.R) <= 1 && Math.Abs(g - c.G) <= 1 && Math.Abs(b - c.B) <= 1)
                    outp.Add(ValueSlot.Hex(token.ToUpperInvariant() == token));
            }
            var parts = token.Split('.');
            double dv;
            if (parts.Length > 2 || !token.All(ch => (ch >= '0' && ch <= '9') || ch == '.') || !token.Any(ch => ch >= '0' && ch <= '9')
                || !double.TryParse(token, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out dv))
                return outp;
            int decimals = parts.Length == 2 ? parts[1].Length : 0;
            foreach (var p in ColorParams.All)
                foreach (var scale in Scales(p))
                {
                    if (decimals == 0 && scale < 50) continue;
                    double expected = p.Value(c) / p.Range() * scale;
                    double tol = Math.Max(decimals == 0 ? 1.01 : 1.01 * Math.Pow(10, -decimals), scale * 0.004);
                    double diff = Math.Abs(dv - expected);
                    if (p == ColorParam.Hue) diff = Math.Min(diff, Math.Abs(diff - scale));
                    if (diff <= tol) outp.Add(ValueSlot.Number(p, scale, decimals));
                }
            return outp;
        }

        // MARK: - Pointer models

        public sealed class Obs
        {
            public RGB Color;
            public RGB? Previous;
            public PointD Down, Up;
            public bool IsDrag;
        }

        public enum FormKind { Axis, Plane, Polar, Ring }

        public sealed class Form
        {
            public FormKind Kind;
            public ColorParam A, B;
            public HashSet<ColorParam> Params
            {
                get
                {
                    switch (Kind)
                    {
                        case FormKind.Axis: return new HashSet<ColorParam> { A };
                        case FormKind.Plane: return new HashSet<ColorParam> { A, B };
                        case FormKind.Polar: return new HashSet<ColorParam> { ColorParam.Hue, A };
                        default: return new HashSet<ColorParam> { ColorParam.Hue };
                    }
                }
            }
        }

        public sealed class ControlFit
        {
            public Form Form;
            public ControlMapping Mapping;
            public double Score;
            public List<KeyValuePair<ScreenAxis, LinearMap>> Linear;
            public double? Diameter;
            public string Label;
        }

        public sealed class Hypothesis
        {
            public PickerColorSpace? Space;
            /// <summary>One entry per varying control; null = treated as a fixed click.</summary>
            public List<ControlFit> Fits;
            public double Score;
            public string Key;
        }

        struct LinFit { public double Offset, Slope, Rms; }

        static LinFit? FitLinear(List<double> values, List<double> coords)
        {
            if (values.Count < 2) return null;
            double mv = values.Average(), mc = coords.Average();
            double sxx = 0, sxy = 0;
            for (int i = 0; i < values.Count; i++) { sxx += (values[i] - mv) * (values[i] - mv); sxy += (values[i] - mv) * (coords[i] - mc); }
            if (sxx <= 1e-9) return null;
            double slope = sxy / sxx, offset = mc - slope * mv;
            double sse = 0;
            for (int i = 0; i < values.Count; i++) { double r = coords[i] - (offset + slope * values[i]); sse += r * r; }
            return new LinFit { Offset = offset, Slope = slope, Rms = Math.Sqrt(sse / values.Count) };
        }

        struct ComplexFit { public double Cx, Cy, Wr, Wi, Rms; }

        /// <summary>Least squares for P = c + w·z over complex numbers.</summary>
        static ComplexFit? FitComplex(List<KeyValuePair<double, double>> z, List<PointD> p)
        {
            double n = z.Count;
            if (z.Count < 2) return null;
            double zr = z.Sum(q => q.Key) / n, zi = z.Sum(q => q.Value) / n;
            double pr = p.Sum(q => q.X) / n, pi = p.Sum(q => q.Y) / n;
            double numR = 0, numI = 0, den = 0;
            for (int k = 0; k < z.Count; k++)
            {
                double ar = z[k].Key - zr, ai = z[k].Value - zi, br = p[k].X - pr, bi = p[k].Y - pi;
                numR += ar * br + ai * bi;
                numI += ar * bi - ai * br;
                den += ar * ar + ai * ai;
            }
            if (den <= 1e-9) return null;
            double wr = numR / den, wi = numI / den;
            double cx = pr - (wr * zr - wi * zi), cy = pi - (wr * zi + wi * zr);
            double sse = 0;
            for (int k = 0; k < z.Count; k++)
            {
                double ex = cx + wr * z[k].Key - wi * z[k].Value, ey = cy + wr * z[k].Value + wi * z[k].Key;
                sse += (p[k].X - ex) * (p[k].X - ex) + (p[k].Y - ey) * (p[k].Y - ey);
            }
            return new ComplexFit { Cx = cx, Cy = cy, Wr = wr, Wi = wi, Rms = Math.Sqrt(sse / n) };
        }

        static bool Plausible(LinearMap m, ScreenAxis axis, RectD? bounds)
        {
            double e = m.Extent;
            if (e < 24 || e > 3000) return false;
            if (!bounds.HasValue) return true;
            var b = bounds.Value.Inset(-60, -60);
            double lo, hi; m.Interval(out lo, out hi);
            double blo = axis == ScreenAxis.X ? b.MinX : b.MinY, bhi = axis == ScreenAxis.X ? b.MaxX : b.MaxY;
            return lo >= blo && hi <= bhi;
        }

        const double ResidualWeight = 1.0 / 3.0;

        /// <summary>Every way one control could set parameters of space.</summary>
        public static List<ControlFit> Fits(List<Obs> obs, PickerColorSpace space, RectD? bounds)
        {
            var outp = new List<ControlFit>();
            var xs = obs.Select(o => o.Up.X).ToList();
            var ys = obs.Select(o => o.Up.Y).ToList();
            var ps = space.Params().Where(p =>
            {
                var vs = obs.Select(o => p.Value(o.Color)).ToList();
                return vs.Max() - vs.Min() >= 0.08 * p.Range();
            }).ToList();
            var linearFits = new Dictionary<ColorParam, Dictionary<ScreenAxis, LinFit>>();
            foreach (var p in ps)
            {
                var vs = obs.Select(o => p.Value(o.Color)).ToList();
                linearFits[p] = new Dictionary<ScreenAxis, LinFit>();
                var fx = FitLinear(vs, xs); if (fx.HasValue) linearFits[p][ScreenAxis.X] = fx.Value;
                var fy = FitLinear(vs, ys); if (fy.HasValue) linearFits[p][ScreenAxis.Y] = fy.Value;
            }
            // Sliders.
            foreach (var p in ps)
                foreach (var axis in new[] { ScreenAxis.X, ScreenAxis.Y })
                {
                    LinFit f;
                    if (!linearFits[p].TryGetValue(axis, out f)) continue;
                    var map = new LinearMap(p, f.Offset, f.Slope);
                    if (!Plausible(map, axis, bounds)) continue;
                    var perp = axis == ScreenAxis.X ? ys : xs;
                    double pm = perp.Average();
                    double perpRMS = Math.Sqrt(perp.Sum(v => (v - pm) * (v - pm)) / perp.Count);
                    double rms = Math.Sqrt(f.Rms * f.Rms + perpRMS * perpRMS);
                    outp.Add(new ControlFit
                    {
                        Form = new Form { Kind = FormKind.Axis, A = p }, Mapping = ControlMapping.AxisMap(axis, map, pm), Score = -rms * ResidualWeight,
                        Linear = new List<KeyValuePair<ScreenAxis, LinearMap>> { new KeyValuePair<ScreenAxis, LinearMap>(axis, map) },
                        Label = "axis-" + (axis == ScreenAxis.X ? "x" : "y") + "(" + p.RawName() + ")",
                    });
                }
            // Areas.
            foreach (var px in ps)
                foreach (var py in ps)
                {
                    if (py == px) continue;
                    LinFit fx, fy;
                    if (!linearFits[px].TryGetValue(ScreenAxis.X, out fx) || !linearFits[py].TryGetValue(ScreenAxis.Y, out fy)) continue;
                    var mx = new LinearMap(px, fx.Offset, fx.Slope);
                    var my = new LinearMap(py, fy.Offset, fy.Slope);
                    if (!Plausible(mx, ScreenAxis.X, bounds) || !Plausible(my, ScreenAxis.Y, bounds)) continue;
                    double rms = Math.Sqrt(fx.Rms * fx.Rms + fy.Rms * fy.Rms);
                    double aspect = Math.Abs(Math.Log(mx.Extent / my.Extent));
                    outp.Add(new ControlFit
                    {
                        Form = new Form { Kind = FormKind.Plane, A = px, B = py }, Mapping = ControlMapping.Plane(mx, my),
                        Score = -rms * ResidualWeight - 0.8 * aspect,
                        Linear = new List<KeyValuePair<ScreenAxis, LinearMap>> { new KeyValuePair<ScreenAxis, LinearMap>(ScreenAxis.X, mx), new KeyValuePair<ScreenAxis, LinearMap>(ScreenAxis.Y, my) },
                        Label = "plane(" + px.RawName() + "," + py.RawName() + ")",
                    });
                }
            // Wheels and rings.
            if (ps.Contains(ColorParam.Hue))
            {
                var hues = obs.Select(o => ColorParam.Hue.Value(o.Color) * Math.PI / 180).ToList();
                var pts = obs.Select(o => o.Up).ToList();
                var radii = new List<ColorParam?> { null };
                radii.AddRange(ps.Where(p => p != ColorParam.Hue).Select(p => (ColorParam?)p));
                foreach (var rp in radii)
                    foreach (var dir in new[] { 1.0, -1.0 })
                    {
                        var z = obs.Select((o, i) =>
                        {
                            double r = rp.HasValue ? rp.Value.Value(o.Color) / rp.Value.Range() : 1;
                            return new KeyValuePair<double, double>(r * Math.Cos(dir * hues[i]), r * Math.Sin(dir * hues[i]));
                        }).ToList();
                        var f = FitComplex(z, pts);
                        if (!f.HasValue) continue;
                        var fv = f.Value;
                        double scale = Math.Sqrt(fv.Wr * fv.Wr + fv.Wi * fv.Wi);
                        if (scale < (rp.HasValue ? 20 : 15) || scale > 1200) continue;
                        if (bounds.HasValue && !bounds.Value.Inset(-60, -60).Contains(new PointD(fv.Cx, fv.Cy))) continue;
                        var pm = new PolarMap(rp, fv.Cx, fv.Cy, fv.Wr, fv.Wi, dir);
                        string label = rp.HasValue ? "polar(" + rp.Value.RawName() + "," + (int)dir + ")" : "ring(" + (int)dir + ")";
                        outp.Add(new ControlFit
                        {
                            Form = rp.HasValue ? new Form { Kind = FormKind.Polar, A = rp.Value } : new Form { Kind = FormKind.Ring },
                            Mapping = ControlMapping.Polar(pm), Score = -fv.Rms * ResidualWeight,
                            Linear = new List<KeyValuePair<ScreenAxis, LinearMap>>(), Diameter = rp.HasValue ? 2 * scale : (double?)null, Label = label,
                        });
                    }
            }
            return outp;
        }

        /// <summary>Assigns the needed parameters to controls in every possible way and scores each.</summary>
        static List<Hypothesis> Search(List<List<Obs>> controls, List<double> fixedPenalties, PickerColorSpace space, HashSet<ColorParam> needed,
                                       RectD? bounds, int typedCount)
        {
            var options = controls.Select(c => Fits(c, space, bounds).Where(f => f.Form.Params.IsSubsetOf(needed)).ToList()).ToList();
            var outp = new List<Hypothesis>();
            var chosen = new List<ControlFit>();
            Action<int, HashSet<ColorParam>> recurse = null;
            recurse = (i, remaining) =>
            {
                if (i == controls.Count)
                {
                    if (remaining.Count > 0) return;
                    var used = chosen.Where(f => f != null).ToList();
                    double score = Prior(space, used, typedCount > 0) + Consistency(used);
                    for (int k = 0; k < chosen.Count; k++) score += chosen[k] != null ? chosen[k].Score : -fixedPenalties[k];
                    outp.Add(new Hypothesis { Space = space, Fits = new List<ControlFit>(chosen), Score = score, Key = "" });
                    return;
                }
                chosen.Add(null);
                recurse(i + 1, remaining);
                chosen.RemoveAt(chosen.Count - 1);
                foreach (var f in options[i])
                {
                    if (!f.Form.Params.IsSubsetOf(remaining)) continue;
                    chosen.Add(f);
                    var rest = new HashSet<ColorParam>(remaining);
                    rest.ExceptWith(f.Form.Params);
                    recurse(i + 1, rest);
                    chosen.RemoveAt(chosen.Count - 1);
                }
            };
            recurse(0, needed);
            return outp;
        }

        /// <summary>How common a layout is (log-odds-ish).</summary>
        static double Prior(PickerColorSpace space, List<ControlFit> fits, bool typed)
        {
            var axes = new HashSet<ColorParam>();
            var planes = new List<KeyValuePair<ColorParam, ColorParam>>();
            var polars = new List<ColorParam>();
            int rings = 0;
            foreach (var f in fits)
            {
                switch (f.Form.Kind)
                {
                    case FormKind.Axis: axes.Add(f.Form.A); break;
                    case FormKind.Plane: planes.Add(new KeyValuePair<ColorParam, ColorParam>(f.Form.A, f.Form.B)); break;
                    case FormKind.Polar: polars.Add(f.Form.A); break;
                    default: rings++; break;
                }
            }
            Func<ColorParam, ColorParam, bool> plane = (a, b) => planes.Any(p => p.Key == a && p.Value == b);
            Func<ColorParam, ColorParam, bool> planeEither = (a, b) => plane(a, b) || plane(b, a);
            Func<ColorParam[], bool> axesAre = set => axes.SetEquals(set);
            Func<ColorParam, bool> polarsAre = p => polars.Count == 1 && polars[0] == p;
            double b0 = 0;
            switch (space)
            {
                case PickerColorSpace.Hsb:
                    if (planeEither(ColorParam.HsbSaturation, ColorParam.HsbBrightness) && axesAre(new[] { ColorParam.Hue }))
                        b0 = plane(ColorParam.HsbSaturation, ColorParam.HsbBrightness) ? 3.0 : 1.6;
                    else if (rings == 1 && planeEither(ColorParam.HsbSaturation, ColorParam.HsbBrightness)) b0 = 2.4;
                    else if (polarsAre(ColorParam.HsbSaturation) && axesAre(new[] { ColorParam.HsbBrightness })) b0 = 2.4;
                    else if (planeEither(ColorParam.Hue, ColorParam.HsbSaturation) && axesAre(new[] { ColorParam.HsbBrightness })) b0 = 1.2;
                    else if (planeEither(ColorParam.Hue, ColorParam.HsbBrightness) && axesAre(new[] { ColorParam.HsbSaturation })) b0 = 0.8;
                    else if (axes.Count == 3) b0 = 1.6;
                    break;
                case PickerColorSpace.Rgb:
                    if (axes.Count == 3) b0 = 2.0;
                    break;
                case PickerColorSpace.Hsl:
                    if (planeEither(ColorParam.Hue, ColorParam.HslSaturation) && axesAre(new[] { ColorParam.HslLightness })) b0 = 2.0;
                    else if (axes.Count == 3) b0 = 1.2;
                    else if (planeEither(ColorParam.HslSaturation, ColorParam.HslLightness) && (axesAre(new[] { ColorParam.Hue }) || rings == 1)) b0 = 1.1;
                    else if (polarsAre(ColorParam.HslSaturation) && axesAre(new[] { ColorParam.HslLightness })) b0 = 1.0;
                    break;
            }
            if (typed) b0 = Math.Max(b0, 1.0);
            foreach (var f in fits)
            {
                if (f.Mapping.Kind != MappingKind.Plane) continue;
                var mx = f.Mapping.MapX; var my = f.Mapping.MapY;
                if ((mx.Param == ColorParam.HsbSaturation || mx.Param == ColorParam.HslSaturation) && mx.Slope > 0) b0 += 0.3;
                if ((my.Param == ColorParam.HsbBrightness || my.Param == ColorParam.HslLightness || my.Param == ColorParam.HsbSaturation || my.Param == ColorParam.HslSaturation) && my.Slope < 0) b0 += 0.3;
            }
            return b0;
        }

        /// <summary>Controls of one picker tend to share a size and line up.</summary>
        static double Consistency(List<ControlFit> fits)
        {
            var extents = new List<double>();
            var intervals = new Dictionary<ScreenAxis, List<double[]>>();
            foreach (var f in fits)
            {
                foreach (var kv in f.Linear)
                {
                    extents.Add(kv.Value.Extent);
                    double lo, hi; kv.Value.Interval(out lo, out hi);
                    if (!intervals.ContainsKey(kv.Key)) intervals[kv.Key] = new List<double[]>();
                    intervals[kv.Key].Add(new[] { lo, hi });
                }
                if (f.Diameter.HasValue) extents.Add(f.Diameter.Value);
            }
            if (extents.Count < 2) return 0;
            double med = Median(extents);
            double s = -1.2 * extents.Sum(e => Math.Abs(Math.Log(e / med)));
            foreach (var axis in new[] { ScreenAxis.X, ScreenAxis.Y })
            {
                List<double[]> list;
                if (!intervals.TryGetValue(axis, out list) || list.Count < 2) continue;
                for (int i = 0; i < list.Count; i++)
                    for (int j = i + 1; j < list.Count; j++)
                    {
                        double inter = Math.Min(list[i][1], list[j][1]) - Math.Max(list[i][0], list[j][0]);
                        double union = Math.Max(list[i][1], list[j][1]) - Math.Min(list[i][0], list[j][0]);
                        if (inter > 0 && union > 0) s += 0.8 * inter / union;
                    }
            }
            return s;
        }

        /// <summary>Structure of the kept actions (so a rejected typed interpretation is recognized).</summary>
        static string Signature(List<List<DemoAction>> kept, Dictionary<int, TypingAnalysis> typing)
        {
            return string.Join(" ", Enumerable.Range(0, kept.Count).Select(k =>
            {
                TypingAnalysis t;
                if (typing.TryGetValue(k, out t))
                    return "T[" + string.Join(",", t.Step.Pieces.Select(p =>
                        p.Kind == TypingPieceKind.Key ? "k" + p.Stroke.KeyCode + "/" + (int)p.Stroke.Modifiers
                        : (p.Kind == TypingPieceKind.Text ? "t" : "p") + p.Template.Slots.Count)) + "]";
                return "G";
            }));
        }

        // MARK: - Helpers

        public static double Distance(PointD a, PointD b) => PointD.Distance(a, b);

        static PointD Mean(List<PointD> p)
        {
            if (p.Count == 0) return PointD.Zero;
            return new PointD(p.Average(q => q.X), p.Average(q => q.Y));
        }

        static double Median(List<double> v)
        {
            var s = v.OrderBy(x => x).ToList();
            return s.Count % 2 == 1 ? s[s.Count / 2] : (s[s.Count / 2 - 1] + s[s.Count / 2]) / 2;
        }

        static double MaxPairwise(List<PointD> p)
        {
            double m = 0;
            for (int i = 0; i < p.Count; i++) for (int j = i + 1; j < p.Count; j++) m = Math.Max(m, Distance(p[i], p[j]));
            return m;
        }

        public static string ListFormat(IList<string> items)
        {
            switch (items.Count)
            {
                case 0: return "";
                case 1: return items[0];
                case 2: return items[0] + " and " + items[1];
                default: return string.Join(", ", items.Take(items.Count - 1)) + " and " + items[items.Count - 1];
            }
        }
    }
}
