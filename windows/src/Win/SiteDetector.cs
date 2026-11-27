using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Automation;

namespace DrawBot.Win
{
    /// <summary>
    /// Works out which website a browser window shows, so Color Learn can keep a separate color
    /// picker per site (every web paint app in one browser shares the browser's executable).
    /// 1. The address bar's text, through UI Automation (Chrome, Edge, Brave, Firefox…), reduced
    ///    to its host, e.g. "paintz.app";
    /// 2. failing that, the window title minus the browser's own name, e.g. "PaintZ".
    /// </summary>
    public static class SiteDetector
    {
        public static readonly HashSet<string> KnownBrowsers = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe", "opera_gx.exe", "vivaldi.exe", "zen.exe",
            "arc.exe", "librewolf.exe", "waterfox.exe", "floorp.exe", "chromium.exe", "iexplore.exe", "thorium.exe", "yandex.exe",
            "browser.exe", "comet.exe", "tor.exe",
        };

        public sealed class Site : IEquatable<Site>
        {
            /// <summary>Stable key part: "paintz.app", or "title:paintz" when only the title was available.</summary>
            public string Key;
            /// <summary>For display: "paintz.app" or "PaintZ".</summary>
            public string Name;
            public bool Equals(Site o) => o != null && Key == o.Key && Name == o.Name;
            public override bool Equals(object obj) => Equals(obj as Site);
            public override int GetHashCode() => Key.GetHashCode();
        }

        public static bool IsBrowser(TargetApp app) => app?.ExeName != null && KnownBrowsers.Contains(app.ExeName);

        /// <summary>The site shown in app's window, or null if it isn't a browser window.</summary>
        public static Site SiteOf(TargetApp app)
        {
            if (!IsBrowser(app)) return null;
            var url = AddressBarText(app.Window, 700);
            var host = url != null ? HostFromUrl(url) : null;
            if (host != null) return new Site { Key = host, Name = host };
            var name = SiteName(WindowInspector.Title(app.Window), app.Name ?? "");
            if (name == null) return null;
            return new Site { Key = "title:" + name.ToLowerInvariant(), Name = name };
        }

        /// <summary>Reads the first editable text that looks like an address, bounded in time.</summary>
        static string AddressBarText(IntPtr hwnd, int timeoutMs)
        {
            var task = Task.Run(() =>
            {
                try
                {
                    var root = AutomationElement.FromHandle(hwnd);
                    var cond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit);
                    var edits = root.FindAll(TreeScope.Descendants, cond);
                    foreach (AutomationElement e in edits)
                    {
                        object pattern;
                        if (!e.TryGetCurrentPattern(ValuePattern.Pattern, out pattern)) continue;
                        var v = ((ValuePattern)pattern).Current.Value;
                        if (string.IsNullOrWhiteSpace(v)) continue;
                        if (v.Contains(" ") || !v.Contains(".")) continue;
                        return v.Contains("://") ? v : "https://" + v;
                    }
                }
                catch (Exception) { }
                return null;
            });
            return task.Wait(timeoutMs) ? task.Result : null;
        }

        /// <summary>"https://www.paint.sumo.app/x?y" → "paint.sumo.app". Null for non-web URLs.</summary>
        public static string HostFromUrl(string s)
        {
            Uri uri;
            if (!Uri.TryCreate(s, UriKind.Absolute, out uri)) return null;
            var scheme = uri.Scheme.ToLowerInvariant();
            if (scheme != "http" && scheme != "https") return null;
            var host = uri.Host.ToLowerInvariant();
            if (host.Length == 0) return null;
            if (host.StartsWith("www.")) host = host.Substring(4);
            return host;
        }

        /// <summary>
        /// "untitled.png - PaintZ — Google Chrome" → "PaintZ"; "Paint" → "Paint". Drops the browser's
        /// own name, then keeps the last part (sites usually put their name last).
        /// </summary>
        public static string SiteName(string title, string appName)
        {
            var separators = new[] { " — ", " – ", " - ", " | ", " · " };
            var parts = new List<string> { title ?? "" };
            foreach (var sep in separators) parts = parts.SelectMany(p => p.Split(new[] { sep }, StringSplitOptions.None)).ToList();
            parts = parts.Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
            var browserWords = new[] { "zen", "firefox", "chrome", "chromium", "safari", "edge", "brave", "arc", "opera", "vivaldi",
                                       "browser", "mozilla", "waterfox", "librewolf", "private browsing", "inprivate", "incognito" };
            var app = (appName ?? "").ToLowerInvariant();
            while (parts.Count > 1)
            {
                var l = parts[parts.Count - 1].ToLowerInvariant();
                if ((app.Length > 0 && (l == app || l.Contains(app))) || browserWords.Any(w => l.Contains(w))) parts.RemoveAt(parts.Count - 1);
                else break;
            }
            if (parts.Count == 0) return null;
            var name = parts[parts.Count - 1];
            return name.Length == 0 ? null : name;
        }
    }
}
