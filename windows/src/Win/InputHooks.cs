using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using DrawBot.Core;

namespace DrawBot.Win
{
    /// <summary>A mouse or key event seen by the low-level hooks.</summary>
    public sealed class HookEvent
    {
        public int Message;
        public PointD Point;
        public double Time;
        public ushort VirtualKey;
        public uint ScanCode;
        public bool Extended;
        /// <summary>Injected by DrawBot itself (its replays and drawing).</summary>
        public bool FromDrawBot;
        public bool Injected;
    }

    /// <summary>
    /// Low-level mouse and keyboard hooks (WH_MOUSE_LL / WH_KEYBOARD_LL), installed on the UI
    /// thread while anyone listens. Need no permissions. Handlers must be quick: Windows waits for
    /// them before delivering input to any app.
    /// </summary>
    public static class GlobalInputHook
    {
        static IntPtr mouseHook, keyHook;
        static Native.HookProc mouseProc, keyProc;   // kept alive for the hooks' lifetime
        static readonly List<Action<HookEvent>> listeners = new List<Action<HookEvent>>();

        public static bool IsInstalled => mouseHook != IntPtr.Zero;

        public static void Add(Action<HookEvent> listener)
        {
            listeners.Add(listener);
            if (mouseHook == IntPtr.Zero) Install();
        }

        public static void Remove(Action<HookEvent> listener)
        {
            listeners.Remove(listener);
            if (listeners.Count == 0) Uninstall();
        }

        static void Install()
        {
            mouseProc = MouseProc;
            keyProc = KeyProc;
            var module = Native.GetModuleHandle(null);
            mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, mouseProc, module, 0);
            keyHook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, keyProc, module, 0);
        }

        static void Uninstall()
        {
            if (mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(mouseHook);
            if (keyHook != IntPtr.Zero) Native.UnhookWindowsHookEx(keyHook);
            mouseHook = keyHook = IntPtr.Zero;
        }

        /// <summary>Delivers e to the listeners as if the hooks had seen it (the virtual self test).</summary>
        internal static void Simulate(HookEvent e) => Dispatch(e);

        static void Dispatch(HookEvent e)
        {
            foreach (var l in listeners.ToArray())
            {
                try { l(e); } catch (Exception ex) { Debug.WriteLine(ex); }
            }
        }

        static IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                var s = (Native.MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(Native.MSLLHOOKSTRUCT));
                Dispatch(new HookEvent
                {
                    Message = wParam.ToInt32(), Point = new PointD(s.pt.X, s.pt.Y), Time = s.time / 1000.0,
                    FromDrawBot = s.dwExtraInfo == Native.DrawBotSignature, Injected = (s.flags & Native.LLMHF_INJECTED) != 0,
                });
            }
            return Native.CallNextHookEx(mouseHook, nCode, wParam, lParam);
        }

        static IntPtr KeyProc(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                var s = (Native.KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(Native.KBDLLHOOKSTRUCT));
                Native.POINT pt;
                Native.GetCursorPos(out pt);
                Dispatch(new HookEvent
                {
                    Message = wParam.ToInt32(), Point = new PointD(pt.X, pt.Y), Time = s.time / 1000.0, VirtualKey = (ushort)s.vkCode,
                    ScanCode = s.scanCode, Extended = (s.flags & Native.LLKHF_EXTENDED) != 0,
                    FromDrawBot = s.dwExtraInfo == Native.DrawBotSignature, Injected = (s.flags & Native.LLKHF_INJECTED) != 0,
                });
            }
            return Native.CallNextHookEx(keyHook, nCode, wParam, lParam);
        }

        public static bool IsDown(int vk) => (Native.GetAsyncKeyState(vk) & 0x8000) != 0;

        /// <summary>Modifiers physically (or synthetically) held right now.</summary>
        public static KeyModifiers HeldModifiers()
        {
            var m = KeyModifiers.None;
            if (IsDown(Native.VK_SHIFT)) m |= KeyModifiers.Shift;
            if (IsDown(Native.VK_CONTROL)) m |= KeyModifiers.Control;
            if (IsDown(Native.VK_MENU)) m |= KeyModifiers.Option;
            if (IsDown(Native.VK_LWIN) || IsDown(Native.VK_RWIN)) m |= KeyModifiers.Command;
            return m;
        }
    }

    /// <summary>When the last mouse button or key event happened anywhere (DrawBot's own included).</summary>
    public sealed class ActivityMonitor : IDisposable
    {
        readonly Stopwatch clock = Stopwatch.StartNew();
        double last;
        readonly Action<HookEvent> handler;

        public ActivityMonitor()
        {
            handler = e => { if (e.Message != Native.WM_MOUSEMOVE) last = clock.Elapsed.TotalSeconds; };
            GlobalInputHook.Add(handler);
            last = 0;
        }

        public double SecondsSinceLastClickOrKey => clock.Elapsed.TotalSeconds - last;

        public void Dispose() => GlobalInputHook.Remove(handler);
    }

    /// <summary>
    /// Records the user's mouse buttons, drags and key presses while they demonstrate a color
    /// (Color Learn). DrawBot's own windows are not recorded, except those RecordsLocalWindow
    /// accepts (the Test Canvas). DrawBot's own injected input is never recorded.
    /// </summary>
    public sealed class InputRecorder
    {
        public List<RecordedInput> Inputs { get; private set; } = new List<RecordedInput>();
        public Func<IntPtr, bool> RecordsLocalWindow = _ => false;
        public Action OnChange = () => { };

        Action<HookEvent> handler;
        PointerButton? openButton;
        bool ignoringGesture;
        PointD lastDownPoint;
        double lastDownTime = -10;
        int clickRun;
        static readonly int OwnPid = Process.GetCurrentProcess().Id;

        public bool IsRecording => handler != null;

        public void Start()
        {
            Stop();
            Inputs = new List<RecordedInput>();
            openButton = null;
            handler = Handle;
            GlobalInputHook.Add(handler);
            OnChange();
        }

        public void Stop()
        {
            if (handler != null) GlobalInputHook.Remove(handler);
            handler = null;
        }

        public void Clear()
        {
            Inputs = new List<RecordedInput>();
            OnChange();
        }

        /// <summary>"3 clicks · 7 keys"</summary>
        public string Summary
        {
            get
            {
                int clicks = Inputs.Count(i => i.Kind == InputKind.MouseDown);
                int keys = Inputs.Count(i => i.Kind == InputKind.KeyDown && !ColorLearner.IsHotkey(i));
                if (clicks == 0 && keys == 0) return "Nothing recorded yet";
                var parts = new List<string>();
                if (clicks > 0) parts.Add(clicks + " click" + (clicks == 1 ? "" : "s"));
                if (keys > 0) parts.Add(keys + " key" + (keys == 1 ? "" : "s"));
                return "Recorded " + string.Join(" · ", parts);
            }
        }

        bool IsOwnWindowAt(PointD p)
        {
            var hwnd = Native.WindowFromPoint(new Native.POINT((int)p.X, (int)p.Y));
            var root = Native.GetAncestor(hwnd, Native.GA_ROOT);
            int pid;
            Native.GetWindowThreadProcessId(root, out pid);
            return pid == OwnPid && !RecordsLocalWindow(root);
        }

        static bool ForegroundIsOwn(Func<IntPtr, bool> allowed)
        {
            var fg = Native.GetForegroundWindow();
            int pid;
            Native.GetWindowThreadProcessId(fg, out pid);
            return pid == OwnPid && !allowed(fg);
        }

        void Handle(HookEvent e)
        {
            if (e.FromDrawBot) return;
            var mods = GlobalInputHook.HeldModifiers();
            switch (e.Message)
            {
                case Native.WM_LBUTTONDOWN:
                case Native.WM_RBUTTONDOWN:
                    {
                        var button = e.Message == Native.WM_RBUTTONDOWN ? PointerButton.Right : PointerButton.Left;
                        ignoringGesture = IsOwnWindowAt(e.Point);
                        openButton = button;
                        if (ignoringGesture) return;
                        // Double clicks, as Windows counts them.
                        double dt = e.Time - lastDownTime;
                        bool near = Math.Abs(e.Point.X - lastDownPoint.X) <= Native.GetSystemMetrics(Native.SM_CXDOUBLECLK) / 2.0
                                 && Math.Abs(e.Point.Y - lastDownPoint.Y) <= Native.GetSystemMetrics(Native.SM_CYDOUBLECLK) / 2.0;
                        clickRun = dt >= 0 && dt * 1000 <= Native.GetDoubleClickTime() && near ? clickRun + 1 : 1;
                        lastDownTime = e.Time; lastDownPoint = e.Point;
                        Inputs.Add(RecordedInput.Mouse(InputKind.MouseDown, e.Point, e.Time, button, clickRun, mods));
                        OnChange();
                        return;
                    }
                case Native.WM_MOUSEMOVE:
                    if (!openButton.HasValue || ignoringGesture) return;
                    Inputs.Add(RecordedInput.Mouse(InputKind.MouseDragged, e.Point, e.Time, openButton.Value, 1, mods));
                    return;
                case Native.WM_LBUTTONUP:
                case Native.WM_RBUTTONUP:
                    {
                        var button = e.Message == Native.WM_RBUTTONUP ? PointerButton.Right : PointerButton.Left;
                        bool ignored = ignoringGesture;
                        openButton = null;
                        ignoringGesture = false;
                        if (ignored) return;
                        Inputs.Add(RecordedInput.Mouse(InputKind.MouseUp, e.Point, e.Time, button, Math.Max(1, clickRun), mods));
                        OnChange();
                        return;
                    }
                case Native.WM_KEYDOWN:
                case Native.WM_SYSKEYDOWN:
                    {
                        if (IsModifierKey(e.VirtualKey)) return;
                        if (ForegroundIsOwn(RecordsLocalWindow)) return;
                        string chars = Characters(e, mods, out mods);
                        string paste = null;
                        bool ctrlV = (mods & KeyModifiers.Control) != 0 && e.VirtualKey == VirtualKey.V;
                        bool shiftIns = (mods & KeyModifiers.Shift) != 0 && e.VirtualKey == VirtualKey.Insert;
                        if (ctrlV || shiftIns)
                        {
                            try { if (Clipboard.ContainsText()) paste = Clipboard.GetText(); } catch (Exception) { }
                        }
                        Inputs.Add(RecordedInput.Key(e.VirtualKey, chars, e.Time, mods, paste));
                        OnChange();
                        return;
                    }
            }
        }

        static bool IsModifierKey(ushort vk) =>
            vk == 0x10 || vk == 0x11 || vk == 0x12 || vk == 0x5B || vk == 0x5C || (vk >= 0xA0 && vk <= 0xA5) || vk == 0x14;

        /// <summary>
        /// The characters a key produced. For shortcuts (Ctrl / Win held): the characters ignoring
        /// modifiers, e.g. "a" for Ctrl+A. Ctrl+Alt that produces a character is AltGr: text, so the
        /// modifiers become just Shift.
        /// </summary>
        static string Characters(HookEvent e, KeyModifiers mods, out KeyModifiers effective)
        {
            effective = mods;
            int pid;
            uint thread = Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out pid);
            var hkl = Native.GetKeyboardLayout(thread);
            var state = new byte[256];
            if ((mods & KeyModifiers.Shift) != 0) state[Native.VK_SHIFT] = 0x80;
            if ((Native.GetAsyncKeyState(Native.VK_CAPITAL) & 1) != 0) state[Native.VK_CAPITAL] = 1;
            bool ctrl = (mods & KeyModifiers.Control) != 0, alt = (mods & KeyModifiers.Option) != 0;
            var buf = new StringBuilder(8);
            if (ctrl && alt && (mods & KeyModifiers.Command) == 0)
            {
                var altGr = (byte[])state.Clone();
                altGr[Native.VK_CONTROL] = 0x80; altGr[Native.VK_MENU] = 0x80;
                int n = Native.ToUnicodeEx(e.VirtualKey, e.ScanCode, altGr, buf, buf.Capacity, 0x4, hkl);
                if (n == 1 && buf[0] >= 0x20)
                {
                    effective = mods & KeyModifiers.Shift;
                    return buf.ToString(0, 1);
                }
                buf.Clear();
            }
            int count = Native.ToUnicodeEx(e.VirtualKey, e.ScanCode, state, buf, buf.Capacity, 0x4, hkl);
            if (count <= 0) return "";
            var s = buf.ToString(0, Math.Min(count, buf.Length));
            if (ctrl || (mods & KeyModifiers.Command) != 0) return s.ToLowerInvariant();
            return s;
        }
    }

    /// <summary>
    /// System-wide hotkeys (RegisterHotKey, no permissions). Handlers run on the UI thread. A bare
    /// key (Esc) is swallowed system-wide while registered, so register it only while needed.
    /// </summary>
    public sealed class HotKeyCenter : NativeWindow, IDisposable
    {
        public static readonly HotKeyCenter Shared = new HotKeyCenter();
        readonly Dictionary<int, Action> handlers = new Dictionary<int, Action>();

        HotKeyCenter() { CreateHandle(new CreateParams { Caption = "DrawBot.HotKeys", Parent = new IntPtr(-3) /* HWND_MESSAGE */ }); }

        /// <summary>Registers (or replaces) hotkey id. Returns false if Windows refused (another app owns that combo).</summary>
        public bool Register(int id, Keys key, Keys modifiers, Action handler)
        {
            Unregister(id);
            uint mods = Native.MOD_NOREPEAT;
            if ((modifiers & Keys.Control) != 0) mods |= Native.MOD_CONTROL;
            if ((modifiers & Keys.Alt) != 0) mods |= Native.MOD_ALT;
            if ((modifiers & Keys.Shift) != 0) mods |= Native.MOD_SHIFT;
            if (!Native.RegisterHotKey(Handle, id, mods, (uint)key)) return false;
            handlers[id] = handler;
            return true;
        }

        public void Unregister(int id)
        {
            if (!handlers.ContainsKey(id)) return;
            Native.UnregisterHotKey(Handle, id);
            handlers.Remove(id);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_HOTKEY)
            {
                Action h;
                if (handlers.TryGetValue(m.WParam.ToInt32(), out h)) h();
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            foreach (var id in handlers.Keys.ToList()) Unregister(id);
            DestroyHandle();
        }
    }
}
