using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using DrawBot.Core;

namespace DrawBot.Win
{
    internal enum ReplayMouse { Move, LeftDown, LeftUp, LeftDrag, RightDown, RightUp, RightDrag }

    /// <summary>Where the replayer's events go. The live implementation uses SendInput; tests record them.</summary>
    internal interface IReplayEventSink
    {
        void PostMouse(ReplayMouse type, PointD p, PointerButton button, int clickState, KeyModifiers modifiers);
        void PostKey(KeyStroke stroke, bool down);
        void SetClipboard(string s);
        PointD? CursorLocation();
        bool EscapePressed();
        bool IsTrusted();
        void Sleep(double seconds);
    }

    internal sealed class LiveReplaySink : IReplayEventSink
    {
        static readonly int InputSize = Marshal.SizeOf(typeof(Native.INPUT));
        readonly SynchronizationContext ui;
        KeyModifiers heldForMouse;

        public LiveReplaySink(SynchronizationContext ui) { this.ui = ui; }

        static Native.INPUT KeyInput(ushort vk, bool down, bool unicode = false, char ch = '\0')
        {
            var input = new Native.INPUT { type = Native.INPUT_KEYBOARD };
            if (unicode)
            {
                input.u.ki = new Native.KEYBDINPUT { wVk = 0, wScan = ch, dwFlags = Native.KEYEVENTF_UNICODE | (down ? 0 : Native.KEYEVENTF_KEYUP), dwExtraInfo = Native.DrawBotSignature };
                return input;
            }
            uint flags = down ? 0 : Native.KEYEVENTF_KEYUP;
            if (IsExtended(vk)) flags |= Native.KEYEVENTF_EXTENDEDKEY;
            input.u.ki = new Native.KEYBDINPUT { wVk = vk, wScan = (ushort)Native.MapVirtualKey(vk, 0), dwFlags = flags, dwExtraInfo = Native.DrawBotSignature };
            return input;
        }

        static bool IsExtended(ushort vk) =>
            (vk >= 0x21 && vk <= 0x28) || vk == 0x2D || vk == 0x2E || vk == 0x5B || vk == 0x5C || vk == 0x6F || vk == 0x90 || vk == 0xA3 || vk == 0xA5;

        static IEnumerable<ushort> ModifierKeys(KeyModifiers m)
        {
            if ((m & KeyModifiers.Control) != 0) yield return Native.VK_CONTROL;
            if ((m & KeyModifiers.Option) != 0) yield return Native.VK_MENU;
            if ((m & KeyModifiers.Shift) != 0) yield return Native.VK_SHIFT;
            if ((m & KeyModifiers.Command) != 0) yield return Native.VK_LWIN;
        }

        void Send(List<Native.INPUT> inputs)
        {
            if (inputs.Count > 0) Native.SendInput((uint)inputs.Count, inputs.ToArray(), InputSize);
        }

        public void PostMouse(ReplayMouse type, PointD p, PointerButton button, int clickState, KeyModifiers modifiers)
        {
            var inputs = new List<Native.INPUT>();
            bool isDown = type == ReplayMouse.LeftDown || type == ReplayMouse.RightDown;
            bool isUp = type == ReplayMouse.LeftUp || type == ReplayMouse.RightUp;
            // Windows mouse events carry no modifier flags: hold the keys around the press.
            if (isDown && modifiers != KeyModifiers.None)
            {
                foreach (var vk in ModifierKeys(modifiers)) inputs.Add(KeyInput(vk, true));
                heldForMouse = modifiers;
            }
            int nx, ny;
            ScreenSpace.Absolute(p, out nx, out ny);
            uint flags = Native.MOUSEEVENTF_MOVE | Native.MOUSEEVENTF_ABSOLUTE | Native.MOUSEEVENTF_VIRTUALDESK;
            switch (type)
            {
                case ReplayMouse.LeftDown: flags |= Native.MOUSEEVENTF_LEFTDOWN; break;
                case ReplayMouse.LeftUp: flags |= Native.MOUSEEVENTF_LEFTUP; break;
                case ReplayMouse.RightDown: flags |= Native.MOUSEEVENTF_RIGHTDOWN; break;
                case ReplayMouse.RightUp: flags |= Native.MOUSEEVENTF_RIGHTUP; break;
            }
            var mi = new Native.INPUT { type = Native.INPUT_MOUSE };
            mi.u.mi = new Native.MOUSEINPUT { dx = nx, dy = ny, dwFlags = flags, dwExtraInfo = Native.DrawBotSignature };
            inputs.Add(mi);
            if (isUp && heldForMouse != KeyModifiers.None)
            {
                foreach (var vk in ModifierKeys(heldForMouse)) inputs.Add(KeyInput(vk, false));
                heldForMouse = KeyModifiers.None;
            }
            Send(inputs);
        }

        /// <summary>
        /// Shortcuts and non-text keys are sent as virtual keys with their modifiers. Text is sent
        /// as the key that types it on the active keyboard layout (so apps see real key presses),
        /// or as a Unicode character when no plain key types it.
        /// </summary>
        public void PostKey(KeyStroke stroke, bool down)
        {
            var inputs = new List<Native.INPUT>();
            bool isText = !stroke.IsShortcut && stroke.Characters.Length == 1 && !VirtualKey.NonText.Contains(stroke.KeyCode);
            if (isText)
            {
                char ch = stroke.Characters[0];
                var hkl = Native.GetKeyboardLayout(ForegroundThread());
                short scan = Native.VkKeyScanEx(ch, hkl);
                int shiftState = scan == -1 ? -1 : (scan >> 8) & 0xFF;
                if (scan != -1 && (shiftState == 0 || shiftState == 1))
                {
                    ushort vk = (ushort)(scan & 0xFF);
                    if (down && shiftState == 1) inputs.Add(KeyInput(Native.VK_SHIFT, true));
                    inputs.Add(KeyInput(vk, down));
                    if (!down && shiftState == 1) inputs.Add(KeyInput(Native.VK_SHIFT, false));
                }
                else inputs.Add(KeyInput(0, down, true, ch));
                Send(inputs);
                return;
            }
            if (stroke.KeyCode == VirtualKey.Unicode)
            {
                foreach (var ch in stroke.Characters) inputs.Add(KeyInput(0, down, true, ch));
                Send(inputs);
                return;
            }
            if (down) foreach (var vk in ModifierKeys(stroke.Modifiers)) inputs.Add(KeyInput(vk, true));
            inputs.Add(KeyInput(stroke.KeyCode, down));
            if (!down) foreach (var vk in ModifierKeys(stroke.Modifiers)) inputs.Add(KeyInput(vk, false));
            Send(inputs);
        }

        static uint ForegroundThread()
        {
            int pid;
            return Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out pid);
        }

        public void SetClipboard(string s)
        {
            SendOrPostCallback work = _ => { try { System.Windows.Forms.Clipboard.SetText(s); } catch (Exception) { } };
            if (ui != null) ui.Send(work, null); else work(null);
        }

        public PointD? CursorLocation() => ScreenSpace.Cursor();
        public bool EscapePressed() => (Native.GetAsyncKeyState(Native.VK_ESCAPE) & 0x8000) != 0;
        public bool IsTrusted() => InputDesktop.IsAvailable();
        public void Sleep(double seconds) => PreciseClock.Sleep(seconds);
    }

    /// <summary>
    /// Plays Color Learn ReplayActions (clicks, drags, keystrokes) on a worker thread. Call Run from
    /// the UI thread; completion runs there exactly once. Stops early on Escape, RequestStop, or
    /// (when StopOnUserMouseMove) when the user moves the mouse away from where DrawBot put it.
    /// The mouse button is always released.
    /// </summary>
    public sealed class InputReplayer
    {
        public enum OutcomeKind { Completed, Stopped }
        public sealed class Outcome
        {
            public OutcomeKind Kind; public string Reason;
            public static Outcome Completed() => new Outcome { Kind = OutcomeKind.Completed };
            public static Outcome Stopped(string r) => new Outcome { Kind = OutcomeKind.Stopped, Reason = r };
            public override string ToString() => Kind == OutcomeKind.Completed ? "completed" : "stopped(" + Reason + ")";
        }

        public bool IsRunning { get; private set; }
        public bool StopOnUserMouseMove = true;
        /// <summary>Multiplies every pause between replayed events (and every learned wait).</summary>
        public double Pace = 1;
        public bool Careful { get => Pace > 1; set => Pace = value ? 1.8 : 1; }

        readonly Func<IReplayEventSink> makeSink;
        readonly SynchronizationContext ui;
        readonly object l = new object();
        string stopReason;

        public InputReplayer()
        {
            ui = SynchronizationContext.Current;
            makeSink = () => InputOverrides.Replay != null ? InputOverrides.Replay() : new LiveReplaySink(ui);
        }

        internal InputReplayer(Func<IReplayEventSink> sink, SynchronizationContext context = null)
        {
            makeSink = sink;
            ui = context;
        }

        public void Run(IList<ReplayAction> actions, Action<Outcome> completion)
        {
            if (IsRunning) return;
            IsRunning = true;
            lock (l) stopReason = null;
            var sink = makeSink();
            bool detectMove = StopOnUserMouseMove;
            double pace = !double.IsNaN(Pace) && !double.IsInfinity(Pace) && Pace > 0 ? Pace : 1.0;
            var list = new List<ReplayAction>(actions);
            var thread = new Thread(() =>
            {
                Outcome outcome;
                using (new PreciseClock.HighResolution())
                {
                    var worker = new ReplayWorker(sink, detectMove, pace, () => { lock (l) return stopReason; });
                    outcome = worker.Run(list);
                }
                Action done = () => { IsRunning = false; completion(outcome); };
                if (ui != null) ui.Post(_ => done(), null); else done();
            });
            thread.Name = "DrawBot.InputReplayer";
            thread.IsBackground = true;
            thread.Priority = ThreadPriority.Highest;
            thread.Start();
        }

        /// <summary>How long replaying actions at pace takes (the replayer runs against a sink that only adds up its pauses).</summary>
        public static double EstimatedDuration(IList<ReplayAction> actions, double pace = 1)
        {
            var sink = new TimingSink();
            double p = !double.IsNaN(pace) && !double.IsInfinity(pace) && pace > 0 ? pace : 1;
            new ReplayWorker(sink, false, p, () => null) { Clock = () => sink.Total }.Run(actions);
            return sink.Total;
        }

        public void RequestStop(string reason = "Stopped")
        {
            lock (l) if (stopReason == null) stopReason = reason;
        }
    }

    internal sealed class ReplayInterrupt : Exception { public string Reason; public ReplayInterrupt(string r) { Reason = r; } }

    internal sealed class ReplayWorker
    {
        readonly IReplayEventSink sink;
        readonly bool detectMove;
        readonly double pace;
        readonly Func<string> stopRequested;
        PointD? lastPosted;
        PointerButton? buttonDown;
        KeyModifiers buttonMods;
        double ignoreEscapeUntil;
        const double MoveThreshold = 14.0;
        public Func<double> Clock = PreciseClock.Now;

        public ReplayWorker(IReplayEventSink sink, bool detectMove, double pace, Func<string> stopRequested)
        {
            this.sink = sink; this.detectMove = detectMove; this.pace = pace; this.stopRequested = stopRequested;
        }

        public InputReplayer.Outcome Run(IList<ReplayAction> actions)
        {
            if (!sink.IsTrusted()) return InputReplayer.Outcome.Stopped(DrawingEngine.Reason.PermissionMissing);
            try
            {
                foreach (var action in actions)
                {
                    Checkpoint();
                    switch (action.Kind)
                    {
                        case ReplayKind.Wait:
                            Wait(action.Seconds * pace);
                            break;
                        case ReplayKind.Click:
                            {
                                var p = action.At;
                                MoveTo(p);
                                Wait(0.04 * pace);
                                int count = Math.Max(1, Math.Min(action.Count, 3));
                                for (int i = 1; i <= count; i++)
                                {
                                    Post(action.Button == PointerButton.Right ? ReplayMouse.RightDown : ReplayMouse.LeftDown, p, action.Button, i, action.Modifiers);
                                    buttonDown = action.Button; buttonMods = action.Modifiers;
                                    sink.Sleep(0.025 * pace);
                                    Post(action.Button == PointerButton.Right ? ReplayMouse.RightUp : ReplayMouse.LeftUp, p, action.Button, i, action.Modifiers);
                                    buttonDown = null;
                                    sink.Sleep(0.03 * pace);
                                }
                                break;
                            }
                        case ReplayKind.Drag:
                            {
                                PointD from = action.At, to = action.To;
                                var button = action.Button; var mods = action.Modifiers;
                                MoveTo(from);
                                Wait(0.04 * pace);
                                Post(button == PointerButton.Right ? ReplayMouse.RightDown : ReplayMouse.LeftDown, from, button, 1, mods);
                                buttonDown = button; buttonMods = mods;
                                sink.Sleep(0.03 * pace);
                                var dragType = button == PointerButton.Right ? ReplayMouse.RightDrag : ReplayMouse.LeftDrag;
                                double len = PointD.Distance(from, to);
                                if (len < 0.5)
                                {
                                    Post(dragType, new PointD(from.X + 1, from.Y), button, 1, mods);
                                    sink.Sleep(0.01 * pace);
                                    Post(dragType, to, button, 1, mods);
                                }
                                else
                                {
                                    // 3-px steps, then 1-px steps for the last 10 px: pickers that stop tracking once
                                    // the pointer leaves the control keep the last position inside it.
                                    foreach (var d in DragDistances(len))
                                    {
                                        double f = d / len;
                                        Post(dragType, new PointD(from.X + (to.X - from.X) * f, from.Y + (to.Y - from.Y) * f), button, 1, mods);
                                        sink.Sleep(0.006 * pace);
                                        var reason = stopRequested();
                                        if (reason != null) throw new ReplayInterrupt(reason);
                                    }
                                }
                                sink.Sleep(0.03 * pace);
                                Post(button == PointerButton.Right ? ReplayMouse.RightUp : ReplayMouse.LeftUp, to, button, 1, mods);
                                buttonDown = null;
                                sink.Sleep(0.04 * pace);
                                break;
                            }
                        case ReplayKind.Key:
                            if (action.Stroke.KeyCode == VirtualKey.Escape) ignoreEscapeUntil = Clock() + 0.4;
                            sink.PostKey(action.Stroke, true);
                            sink.Sleep(0.012 * pace);
                            sink.PostKey(action.Stroke, false);
                            sink.Sleep(0.03 * pace);
                            break;
                        case ReplayKind.SetClipboard:
                            sink.SetClipboard(action.Text);
                            sink.Sleep(0.05);
                            break;
                        case ReplayKind.Move:
                            MoveTo(action.At);
                            sink.Sleep(0.03 * pace);
                            break;
                    }
                }
                return InputReplayer.Outcome.Completed();
            }
            catch (ReplayInterrupt i)
            {
                Release();
                return InputReplayer.Outcome.Stopped(i.Reason);
            }
            catch (Exception)
            {
                Release();
                return InputReplayer.Outcome.Stopped("Stopped");
            }
        }

        /// <summary>Distances along a drag of length at which to post drag events (the last one is length).</summary>
        public static List<double> DragDistances(double length)
        {
            var outp = new List<double>();
            if (!(length > 0)) return outp;
            double fineFrom = Math.Max(0, length - 10);
            double d = 0;
            while (d + 3 < fineFrom) { d += 3; outp.Add(d); }
            if (d < fineFrom) { d = fineFrom; outp.Add(d); }
            while (d + 1 < length) { d += 1; outp.Add(d); }
            outp.Add(length);
            return outp;
        }

        void Release()
        {
            if (!buttonDown.HasValue) return;
            var b = buttonDown.Value;
            Post(b == PointerButton.Right ? ReplayMouse.RightUp : ReplayMouse.LeftUp, lastPosted ?? sink.CursorLocation() ?? PointD.Zero, b, 1, buttonMods);
            buttonDown = null;
        }

        void Post(ReplayMouse type, PointD p, PointerButton button, int clickState, KeyModifiers mods)
        {
            sink.PostMouse(type, p, button, clickState, mods);
            lastPosted = p;
        }

        void MoveTo(PointD p)
        {
            CheckUserMovement();
            Post(ReplayMouse.Move, p, PointerButton.Left, 0, KeyModifiers.None);
        }

        void Wait(double t)
        {
            double left = t;
            while (left > 0)
            {
                double slice = Math.Min(0.01, left);
                sink.Sleep(slice);
                left -= slice;
                Checkpoint();
            }
        }

        void Checkpoint()
        {
            var reason = stopRequested();
            if (reason != null) throw new ReplayInterrupt(reason);
            if (Clock() >= ignoreEscapeUntil && sink.EscapePressed()) throw new ReplayInterrupt(DrawingEngine.Reason.Escape);
            if (!sink.IsTrusted()) throw new ReplayInterrupt(DrawingEngine.Reason.PermissionLost);
        }

        /// <summary>The cursor should still be where we last put it (re-checked a few times for lag).</summary>
        void CheckUserMovement()
        {
            if (!detectMove || !lastPosted.HasValue) return;
            var expected = lastPosted.Value;
            for (int attempt = 0; attempt < 4; attempt++)
            {
                var cur = sink.CursorLocation();
                if (!cur.HasValue) return;
                if (PointD.Distance(cur.Value, expected) <= MoveThreshold) return;
                if (attempt < 3) sink.Sleep(0.04);
            }
            throw new ReplayInterrupt(DrawingEngine.Reason.MouseMoved);
        }
    }

    /// <summary>Adds up the pauses of a replay without posting anything.</summary>
    internal sealed class TimingSink : IReplayEventSink
    {
        public double Total;
        public void PostMouse(ReplayMouse type, PointD p, PointerButton button, int clickState, KeyModifiers modifiers) { }
        public void PostKey(KeyStroke stroke, bool down) { }
        public void SetClipboard(string s) { }
        public PointD? CursorLocation() => null;
        public bool EscapePressed() => false;
        public bool IsTrusted() => true;
        public void Sleep(double seconds) { Total += seconds; }
    }
}
