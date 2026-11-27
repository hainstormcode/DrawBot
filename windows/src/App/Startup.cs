using System;
using System.Threading;
using System.Windows.Forms;
using DrawBot.Win;

namespace DrawBot.App
{
    public static class Startup
    {
        static bool done;

        public static void Init()
        {
            if (done) return;
            done = true;
            // Physical pixels everywhere: SendInput, GetCursorPos, window rectangles and hooks agree.
            try { if (!Native.SetProcessDpiAwarenessContext(new IntPtr(-4))) throw new Exception(); }
            catch (Exception)
            {
                try { if (Native.SetProcessDpiAwareness(2) != 0) Native.SetProcessDPIAware(); }
                catch (Exception) { try { Native.SetProcessDPIAware(); } catch (Exception) { } }
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        }
    }
}
