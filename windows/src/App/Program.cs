using System;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using DrawBot.Win;

namespace DrawBot.App
{
    public static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            Startup.Init();
            if (args.Any(a => a.StartsWith("--selftest")))
                return SelfTest.Run(args);

            bool first;
            using (var mutex = new Mutex(true, "Local\\DrawBot.SingleInstance", out first))
            using (var show = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\DrawBot.ShowPanel"))
            {
                if (!first)
                {
                    show.Set();   // the running DrawBot shows its panel
                    return 0;
                }
                var context = new DrawBotContext();
                var waiter = new Thread(() =>
                {
                    while (true)
                    {
                        show.WaitOne();
                        try { context.ShowPanelFromAnyThread(); } catch (Exception) { return; }
                    }
                }) { IsBackground = true };
                waiter.Start();
                Application.Run(context);
            }
            return 0;
        }
    }

    /// <summary>DrawBot lives in the notification area; closing the panel only hides it, so the hotkeys keep working.</summary>
    public sealed class DrawBotContext : ApplicationContext
    {
        public readonly AppController Controller;
        readonly NotifyIcon tray;
        readonly ToolStripMenuItem startItem;

        public DrawBotContext()
        {
            Controller = new AppController();
            var panel = new ControlPanel(Controller);
            Controller.ControlPanel = panel;
            Controller.RegisterGlobalHotkeys();

            var menu = new ContextMenuStrip();
            menu.Items.Add(new ToolStripMenuItem("Show DrawBot", null, (s, e) => Controller.ShowControlPanel()) { ShortcutKeyDisplayString = Ui.HotkeyPrefix + "P" });
            menu.Items.Add(new ToolStripMenuItem("Select Canvas…", null, (s, e) => Controller.SelectCanvas()) { ShortcutKeyDisplayString = Ui.HotkeyPrefix + "S" });
            startItem = new ToolStripMenuItem("Start / Continue", null, (s, e) => Controller.StartOrContinue()) { ShortcutKeyDisplayString = Ui.ContinueKey };
            menu.Items.Add(startItem);
            menu.Items.Add(new ToolStripMenuItem("Stop", null, (s, e) => Controller.Stop()) { ShortcutKeyDisplayString = "Esc / " + Ui.HotkeyPrefix + "." });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Open Test Canvas", null, (s, e) => Controller.OpenTestCanvas()));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Quit DrawBot", null, (s, e) => Quit()));

            tray = new NotifyIcon { Icon = Ui.MakeIcon(), Text = "DrawBot", ContextMenuStrip = menu, Visible = true };
            tray.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) Controller.ShowControlPanel(); };
            Controller.Changed += () => { var t = "DrawBot · " + Controller.PhaseDescription; tray.Text = t.Length > 63 ? t.Substring(0, 63) : t; };
            panel.Show();
        }

        public void ShowPanelFromAnyThread()
        {
            var panel = Controller.ControlPanel;
            if (panel == null || panel.IsDisposed) return;
            panel.BeginInvoke((Action)(() => Controller.ShowControlPanel()));
        }

        void Quit()
        {
            Controller.PrepareForTermination(() =>
            {
                tray.Visible = false;
                tray.Dispose();
                HotKeyCenter.Shared.Dispose();
                ExitThread();
            });
        }
    }
}
