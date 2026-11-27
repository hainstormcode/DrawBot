using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using DrawBot.Core;

namespace DrawBot.App
{
    /// <summary>How quickly Color Learn selects each color while drawing.</summary>
    public enum SelectionSpeed { Slow, Normal, Fast, Ludicrous }

    /// <summary>How each color gets selected in the drawing app.</summary>
    public enum ColorSelectionMode
    {
        /// <summary>DrawBot shows the color and the user selects it, then presses Continue.</summary>
        Manual,
        /// <summary>Color Learn: DrawBot replays what it learned from the user's demonstrations.</summary>
        Automatic,
    }

    public static class SettingEnums
    {
        /// <summary>Quiet time before replaying a learned color picker.</summary>
        public const double PickerQuietPeriod = 1.5;

        public static string DisplayName(this SelectionSpeed s)
        {
            switch (s)
            {
                case SelectionSpeed.Slow: return "Slow (laggy apps)";
                case SelectionSpeed.Normal: return "Normal";
                case SelectionSpeed.Fast: return "Fast";
                default: return "Ludicrous";
            }
        }

        /// <summary>Multiplies the pauses between the replayed clicks and keystrokes.</summary>
        public static double Pace(this SelectionSpeed s)
        {
            switch (s) { case SelectionSpeed.Slow: return 1.8; case SelectionSpeed.Normal: return 1; case SelectionSpeed.Fast: return 0.5; default: return 0.25; }
        }

        /// <summary>How long there must have been no click or key press before DrawBot touches the picker.</summary>
        public static double QuietPeriod(this SelectionSpeed s)
        {
            switch (s) { case SelectionSpeed.Slow: return 2; case SelectionSpeed.Normal: return PickerQuietPeriod; case SelectionSpeed.Fast: return 0.5; default: return 0.15; }
        }

        /// <summary>Pause after bringing the drawing app to the front.</summary>
        public static double Settle(this SelectionSpeed s)
        {
            switch (s) { case SelectionSpeed.Slow: return 0.4; case SelectionSpeed.Normal: return 0.25; case SelectionSpeed.Fast: return 0.1; default: return 0.03; }
        }

        /// <summary>Whether the countdown runs before every automatically selected color, or only before the first.</summary>
        public static bool CountdownEveryColor(this SelectionSpeed s) => s == SelectionSpeed.Slow || s == SelectionSpeed.Normal;

        public static string DisplayName(this ColorSelectionMode m) =>
            m == ColorSelectionMode.Manual ? "Ask me to select each color" : "Select colors automatically (Color Learn)";
    }

    /// <summary>User-adjustable drawing settings, persisted as JSON. Missing keys fall back to the defaults.</summary>
    public sealed class DrawSettings : IEquatable<DrawSettings>
    {
        public int MaxColors = 8;
        public double MergeDistance = 6;
        /// <summary>Grid spacing in screen pixels.</summary>
        public double PenSize = 4;
        public SpeedPreset Speed = SpeedPreset.Normal;
        public ColorOrder Order = ColorOrder.LightToDark;
        public StrokeStyle StrokeStyle = StrokeStyle.Paths;
        public int CountdownSeconds = 1;
        public bool PauseOnMouseMove = true;
        public bool SkipNearWhite = true;
        public ColorSelectionMode ColorSelection = ColorSelectionMode.Manual;
        public SelectionSpeed SelectionSpeed = SelectionSpeed.Normal;

        public const int MinColors = 1, MaxColorsLimit = 32;
        public const double MinMerge = 0, MaxMerge = 30, MinPen = 1, MaxPen = 40;
        public const int MinCountdown = 0, MaxCountdown = 5;

        public DrawSettings Copy() => (DrawSettings)MemberwiseClone();

        public DrawSettings Clamped()
        {
            var s = Copy();
            s.MaxColors = Math.Min(Math.Max(s.MaxColors, MinColors), MaxColorsLimit);
            s.MergeDistance = Math.Min(Math.Max(double.IsNaN(s.MergeDistance) || double.IsInfinity(s.MergeDistance) ? 6 : s.MergeDistance, MinMerge), MaxMerge);
            s.PenSize = Math.Min(Math.Max(double.IsNaN(s.PenSize) || double.IsInfinity(s.PenSize) ? 4 : s.PenSize, MinPen), MaxPen);
            s.CountdownSeconds = Math.Min(Math.Max(s.CountdownSeconds, MinCountdown), MaxCountdown);
            return s;
        }

        public QuantizeOptions QuantizeOptions => new QuantizeOptions(MaxColors, MergeDistance);

        public Dictionary<string, object> ToJson() => new Dictionary<string, object>
        {
            { "maxColors", MaxColors }, { "mergeDistance", MergeDistance }, { "penSize", PenSize }, { "speed", Speed.ToString() },
            { "order", Order.ToString() }, { "strokeStyle", StrokeStyle.ToString() }, { "countdownSeconds", CountdownSeconds },
            { "pauseOnMouseMove", PauseOnMouseMove }, { "skipNearWhite", SkipNearWhite }, { "colorSelection", ColorSelection.ToString() },
            { "selectionSpeed", SelectionSpeed.ToString() },
        };

        public static DrawSettings FromJson(Dictionary<string, object> d)
        {
            var def = new DrawSettings();
            if (d == null) return def;
            return new DrawSettings
            {
                MaxColors = Json.Int(d, "maxColors", def.MaxColors), MergeDistance = Json.Num(d, "mergeDistance", def.MergeDistance),
                PenSize = Json.Num(d, "penSize", def.PenSize), Speed = Json.Enum(d, "speed", def.Speed), Order = Json.Enum(d, "order", def.Order),
                StrokeStyle = Json.Enum(d, "strokeStyle", def.StrokeStyle), CountdownSeconds = Json.Int(d, "countdownSeconds", def.CountdownSeconds),
                PauseOnMouseMove = Json.Bool(d, "pauseOnMouseMove", def.PauseOnMouseMove), SkipNearWhite = Json.Bool(d, "skipNearWhite", def.SkipNearWhite),
                ColorSelection = Json.Enum(d, "colorSelection", def.ColorSelection), SelectionSpeed = Json.Enum(d, "selectionSpeed", def.SelectionSpeed),
            }.Clamped();
        }

        public bool Equals(DrawSettings o) => o != null && Json.Write(ToJson(), false) == Json.Write(o.ToJson(), false);
        public override bool Equals(object obj) => Equals(obj as DrawSettings);
        public override int GetHashCode() => MaxColors;
    }

    /// <summary>Settings, the last image and canvas, and learned profiles in %APPDATA%\DrawBot.</summary>
    public static class SettingsStore
    {
        public static string Folder
        {
            get
            {
                var dir = Environment.GetEnvironmentVariable("DRAWBOT_DATA_DIR");
                if (string.IsNullOrEmpty(dir)) dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DrawBot");
                Directory.CreateDirectory(dir);
                return dir;
            }
        }

        static string StatePath => Path.Combine(Folder, "settings.json");
        static string ProfilesPath => Path.Combine(Folder, "color-pickers.json");
        public static string LessonsFolder { get { var d = Path.Combine(Folder, "Lessons"); Directory.CreateDirectory(d); return d; } }

        static Dictionary<string, object> state;

        static Dictionary<string, object> State
        {
            get
            {
                if (state != null) return state;
                try { state = Json.Obj(Json.Parse(File.ReadAllText(StatePath))); } catch (Exception) { }
                if (state == null) state = new Dictionary<string, object>();
                return state;
            }
        }

        static void SaveState()
        {
            try
            {
                var tmp = StatePath + ".tmp";
                File.WriteAllText(tmp, Json.Write(State));
                if (File.Exists(StatePath)) File.Replace(tmp, StatePath, null); else File.Move(tmp, StatePath);
            }
            catch (Exception) { }
        }

        public static DrawSettings LoadSettings() => DrawSettings.FromJson(Json.Obj(Json.Get(State, "settings")));

        public static void Save(DrawSettings s) { State["settings"] = s.ToJson(); SaveState(); }

        public static string LastImagePath
        {
            get => Json.Str(State, "lastImagePath");
            set { if (value == null) State.Remove("lastImagePath"); else State["lastImagePath"] = value; SaveState(); }
        }

        /// <summary>Last canvas rectangle (virtual-screen pixels).</summary>
        public static RectD? LastCanvas
        {
            get
            {
                var r = LearnJson.Rect(Json.Get(State, "lastCanvas"));
                return r.HasValue && r.Value.Width >= 8 && r.Value.Height >= 8 ? r : null;
            }
            set { if (value == null) State.Remove("lastCanvas"); else State["lastCanvas"] = LearnJson.Rect(value.Value); SaveState(); }
        }

        public static Dictionary<string, ColorPickerProfile> LoadProfiles()
        {
            try { return File.Exists(ProfilesPath) ? LearnJson.Profiles(File.ReadAllText(ProfilesPath)) : new Dictionary<string, ColorPickerProfile>(); }
            catch (Exception) { return new Dictionary<string, ColorPickerProfile>(); }
        }

        public static void SaveProfiles(Dictionary<string, ColorPickerProfile> profiles)
        {
            try { File.WriteAllText(ProfilesPath, LearnJson.Profiles(profiles)); } catch (Exception) { }
        }
    }
}
