using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace DrawBot.Core
{
    /// <summary>
    /// Minimal JSON: objects are Dictionary&lt;string, object&gt;, arrays List&lt;object&gt;, numbers double,
    /// plus string, bool and null. Enough for settings, learned profiles and lesson logs.
    /// </summary>
    public static class Json
    {
        public static string Write(object value, bool pretty = true)
        {
            var sb = new StringBuilder();
            WriteValue(sb, value, pretty, 0);
            return sb.ToString();
        }

        static void Indent(StringBuilder sb, bool pretty, int level)
        {
            if (!pretty) return;
            sb.Append('\n');
            sb.Append(' ', level * 2);
        }

        static void WriteValue(StringBuilder sb, object v, bool pretty, int level)
        {
            if (v == null) { sb.Append("null"); return; }
            if (v is string s) { WriteString(sb, s); return; }
            if (v is bool b) { sb.Append(b ? "true" : "false"); return; }
            if (v is double d) { sb.Append(double.IsNaN(d) || double.IsInfinity(d) ? "null" : d.ToString("R", CultureInfo.InvariantCulture)); return; }
            if (v is float f) { WriteValue(sb, (double)f, pretty, level); return; }
            if (v is int || v is long || v is uint || v is ushort || v is byte || v is ulong || v is short)
            {
                sb.Append(Convert.ToString(v, CultureInfo.InvariantCulture)); return;
            }
            if (v is IDictionary<string, object> dict)
            {
                sb.Append('{');
                bool first = true;
                foreach (var kv in dict)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    Indent(sb, pretty, level + 1);
                    WriteString(sb, kv.Key);
                    sb.Append(pretty ? ": " : ":");
                    WriteValue(sb, kv.Value, pretty, level + 1);
                }
                if (!first) Indent(sb, pretty, level);
                sb.Append('}');
                return;
            }
            if (v is System.Collections.IEnumerable list)
            {
                sb.Append('[');
                bool first = true;
                foreach (var item in list)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    Indent(sb, pretty, level + 1);
                    WriteValue(sb, item, pretty, level + 1);
                }
                if (!first) Indent(sb, pretty, level);
                sb.Append(']');
                return;
            }
            WriteString(sb, v.ToString());
        }

        static void WriteString(StringBuilder sb, string s)
        {
            sb.Append('"');
            foreach (var c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }

        public static object Parse(string text)
        {
            int i = 0;
            var v = ParseValue(text, ref i);
            SkipWs(text, ref i);
            if (i != text.Length) throw new FormatException("Trailing characters in JSON at " + i);
            return v;
        }

        static void SkipWs(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

        static object ParseValue(string s, ref int i)
        {
            SkipWs(s, ref i);
            if (i >= s.Length) throw new FormatException("Unexpected end of JSON");
            char c = s[i];
            if (c == '{')
            {
                i++;
                var d = new Dictionary<string, object>();
                SkipWs(s, ref i);
                if (i < s.Length && s[i] == '}') { i++; return d; }
                while (true)
                {
                    SkipWs(s, ref i);
                    var key = ParseString(s, ref i);
                    SkipWs(s, ref i);
                    if (i >= s.Length || s[i] != ':') throw new FormatException("Expected ':' at " + i);
                    i++;
                    d[key] = ParseValue(s, ref i);
                    SkipWs(s, ref i);
                    if (i < s.Length && s[i] == ',') { i++; continue; }
                    if (i < s.Length && s[i] == '}') { i++; return d; }
                    throw new FormatException("Expected ',' or '}' at " + i);
                }
            }
            if (c == '[')
            {
                i++;
                var l = new List<object>();
                SkipWs(s, ref i);
                if (i < s.Length && s[i] == ']') { i++; return l; }
                while (true)
                {
                    l.Add(ParseValue(s, ref i));
                    SkipWs(s, ref i);
                    if (i < s.Length && s[i] == ',') { i++; continue; }
                    if (i < s.Length && s[i] == ']') { i++; return l; }
                    throw new FormatException("Expected ',' or ']' at " + i);
                }
            }
            if (c == '"') return ParseString(s, ref i);
            if (s.Length - i >= 4 && string.CompareOrdinal(s, i, "true", 0, 4) == 0) { i += 4; return true; }
            if (s.Length - i >= 5 && string.CompareOrdinal(s, i, "false", 0, 5) == 0) { i += 5; return false; }
            if (s.Length - i >= 4 && string.CompareOrdinal(s, i, "null", 0, 4) == 0) { i += 4; return null; }
            int start = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            if (start == i) throw new FormatException("Unexpected character '" + c + "' at " + i);
            return double.Parse(s.Substring(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture);
        }

        static string ParseString(string s, ref int i)
        {
            if (s[i] != '"') throw new FormatException("Expected string at " + i);
            i++;
            var sb = new StringBuilder();
            while (i < s.Length)
            {
                char c = s[i++];
                if (c == '"') return sb.ToString();
                if (c != '\\') { sb.Append(c); continue; }
                char e = s[i++];
                switch (e)
                {
                    case '"': sb.Append('"'); break;
                    case '\\': sb.Append('\\'); break;
                    case '/': sb.Append('/'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case 'u': sb.Append((char)int.Parse(s.Substring(i, 4), NumberStyles.HexNumber)); i += 4; break;
                    default: throw new FormatException("Bad escape at " + i);
                }
            }
            throw new FormatException("Unterminated string");
        }

        // Typed accessors (lenient: missing / wrong-typed values give the fallback).

        public static Dictionary<string, object> Obj(object o) => o as Dictionary<string, object>;
        public static List<object> Arr(object o) => o as List<object> ?? new List<object>();
        public static object Get(Dictionary<string, object> d, string key) { object v; return d != null && d.TryGetValue(key, out v) ? v : null; }
        public static double Num(Dictionary<string, object> d, string key, double fallback = 0) => Get(d, key) is double v ? v : fallback;
        public static int Int(Dictionary<string, object> d, string key, int fallback = 0) => Get(d, key) is double v ? (int)v : fallback;
        public static bool Bool(Dictionary<string, object> d, string key, bool fallback = false) => Get(d, key) is bool v ? v : fallback;
        public static string Str(Dictionary<string, object> d, string key, string fallback = null) => Get(d, key) as string ?? fallback;

        public static T Enum<T>(Dictionary<string, object> d, string key, T fallback) where T : struct
        {
            var s = Str(d, key);
            T v;
            return s != null && System.Enum.TryParse(s, true, out v) ? v : fallback;
        }
    }

    /// <summary>JSON encoding of Color Learn types (profiles, demos, lesson logs).</summary>
    public static class LearnJson
    {
        static Dictionary<string, object> D(params object[] kv)
        {
            var d = new Dictionary<string, object>();
            for (int i = 0; i + 1 < kv.Length; i += 2) if (kv[i + 1] != null) d[(string)kv[i]] = kv[i + 1];
            return d;
        }

        public static object Point(PointD p) => new List<object> { p.X, p.Y };
        public static PointD Point(object o)
        {
            var l = Json.Arr(o);
            return l.Count >= 2 && l[0] is double x && l[1] is double y ? new PointD(x, y) : PointD.Zero;
        }
        public static object Rect(RectD r) => new List<object> { r.X, r.Y, r.Width, r.Height };
        public static RectD? Rect(object o)
        {
            var l = Json.Arr(o);
            if (l.Count < 4 || !l.All(v => v is double)) return null;
            return new RectD((double)l[0], (double)l[1], (double)l[2], (double)l[3]);
        }
        public static object Color(RGB c) => c.HexNoHash;
        public static RGB Color(object o) { RGB c; return RGB.TryParseHex(o as string, out c) ? c : new RGB(0, 0, 0); }

        public static object Stroke(KeyStroke k) => D("keyCode", (int)k.KeyCode, "characters", k.Characters, "modifiers", (int)k.Modifiers);
        public static KeyStroke Stroke(object o)
        {
            var d = Json.Obj(o);
            return new KeyStroke((ushort)Json.Int(d, "keyCode"), Json.Str(d, "characters", ""), (KeyModifiers)Json.Int(d, "modifiers"));
        }

        public static object Input(RecordedInput e) => D("kind", e.Kind.ToString(), "time", e.Time, "point", Point(e.Point), "button", e.Button.ToString(),
            "clickCount", e.ClickCount, "keyCode", (int)e.KeyCode, "characters", e.Characters, "modifiers", (int)e.Modifiers, "pasteText", e.PasteText);
        public static RecordedInput Input(object o)
        {
            var d = Json.Obj(o);
            return new RecordedInput
            {
                Kind = Json.Enum(d, "kind", InputKind.MouseDown), Time = Json.Num(d, "time"), Point = Point(Json.Get(d, "point")),
                Button = Json.Enum(d, "button", PointerButton.Left), ClickCount = Json.Int(d, "clickCount", 1), KeyCode = (ushort)Json.Int(d, "keyCode"),
                Characters = Json.Str(d, "characters", ""), Modifiers = (KeyModifiers)Json.Int(d, "modifiers"), PasteText = Json.Str(d, "pasteText"),
            };
        }

        public static object Demo(ColorDemo demo) => D("color", Color(demo.Color), "previousColor", demo.PreviousColor.HasValue ? Color(demo.PreviousColor.Value) : null,
            "inputs", demo.Inputs.Select(Input).ToList<object>());
        public static ColorDemo Demo(object o)
        {
            var d = Json.Obj(o);
            var prev = Json.Get(d, "previousColor") as string;
            return new ColorDemo(Color(Json.Get(d, "color")), prev != null ? Color(prev) : (RGB?)null, Json.Arr(Json.Get(d, "inputs")).Select(Input));
        }

        static object Slot(ValueSlot s) => s.IsHex ? D("hex", s.Uppercase) : D("param", s.Param.ToString(), "fullScale", s.FullScale, "decimals", s.Decimals);
        static ValueSlot Slot(Dictionary<string, object> d)
        {
            if (Json.Get(d, "hex") is bool up) return ValueSlot.Hex(up);
            return ValueSlot.Number(Json.Enum(d, "param", ColorParam.Red), Json.Num(d, "fullScale", 255), Json.Int(d, "decimals"));
        }

        static object Template(TextTemplate t) => t.Parts.Select(p => p.IsSlot ? (object)D("slot", Slot(p.Slot)) : D("literal", p.Literal)).ToList<object>();
        static TextTemplate Template(object o) => new TextTemplate(Json.Arr(o).Select(x =>
        {
            var d = Json.Obj(x);
            var slot = Json.Obj(Json.Get(d, "slot"));
            return slot != null ? TextPart.Of(Slot(slot)) : TextPart.Lit(Json.Str(d, "literal", ""));
        }));

        static object Linear(LinearMap m) => D("param", m.Param.ToString(), "offset", m.Offset, "slope", m.Slope);
        static LinearMap Linear(object o) { var d = Json.Obj(o); return new LinearMap(Json.Enum(d, "param", ColorParam.Hue), Json.Num(d, "offset"), Json.Num(d, "slope")); }

        static object Mapping(ControlMapping m)
        {
            switch (m.Kind)
            {
                case MappingKind.Fixed: return D("fixed", Point(m.FixedPoint));
                case MappingKind.Axis: return D("axis", m.Axis.ToString(), "map", Linear(m.Map), "other", m.Other);
                case MappingKind.Plane: return D("planeX", Linear(m.MapX), "planeY", Linear(m.MapY));
                default:
                    var p = m.PolarM;
                    return D("polar", D("radius", p.Radius.HasValue ? p.Radius.Value.ToString() : null, "centerX", p.CenterX, "centerY", p.CenterY,
                        "wRe", p.WRe, "wIm", p.WIm, "direction", p.Direction));
            }
        }

        static ControlMapping Mapping(object o)
        {
            var d = Json.Obj(o);
            if (Json.Get(d, "fixed") != null) return ControlMapping.Fixed(Point(Json.Get(d, "fixed")));
            if (Json.Get(d, "axis") != null) return ControlMapping.AxisMap(Json.Enum(d, "axis", ScreenAxis.X), Linear(Json.Get(d, "map")), Json.Num(d, "other"));
            if (Json.Get(d, "planeX") != null) return ControlMapping.Plane(Linear(Json.Get(d, "planeX")), Linear(Json.Get(d, "planeY")));
            var p = Json.Obj(Json.Get(d, "polar"));
            if (p == null) throw new FormatException("Unknown control mapping");
            var rs = Json.Str(p, "radius");
            ColorParam rp;
            ColorParam? radius = rs != null && System.Enum.TryParse(rs, out rp) ? rp : (ColorParam?)null;
            return ControlMapping.Polar(new PolarMap(radius, Json.Num(p, "centerX"), Json.Num(p, "centerY"), Json.Num(p, "wRe"), Json.Num(p, "wIm"), Json.Num(p, "direction", 1)));
        }

        static object Step(PickerStep s)
        {
            if (s.Pointer != null)
            {
                var p = s.Pointer;
                return D("pointer", D("mapping", Mapping(p.Mapping), "button", p.Button.ToString(), "clickCount", p.ClickCount, "modifiers", (int)p.Modifiers,
                    "isDrag", p.IsDrag, "dragStart", p.DragStart.HasValue ? Point(p.DragStart.Value) : null, "grabsKnob", p.GrabsKnob, "delayBefore", p.DelayBefore));
            }
            var t = s.Typing;
            return D("typing", D("delayBefore", t.DelayBefore, "pieces", t.Pieces.Select(pc =>
                pc.Kind == TypingPieceKind.Key ? (object)D("key", Stroke(pc.Stroke))
                : pc.Kind == TypingPieceKind.Text ? D("text", Template(pc.Template))
                : D("paste", Template(pc.Template), "shortcut", Stroke(pc.Stroke))).ToList<object>()));
        }

        static PickerStep Step(object o)
        {
            var d = Json.Obj(o);
            var p = Json.Obj(Json.Get(d, "pointer"));
            if (p != null)
            {
                var ds = Json.Get(p, "dragStart");
                return PickerStep.Of(new PointerStep
                {
                    Mapping = Mapping(Json.Get(p, "mapping")), Button = Json.Enum(p, "button", PointerButton.Left), ClickCount = Json.Int(p, "clickCount", 1),
                    Modifiers = (KeyModifiers)Json.Int(p, "modifiers"), IsDrag = Json.Bool(p, "isDrag"), DragStart = ds != null ? Point(ds) : (PointD?)null,
                    GrabsKnob = Json.Bool(p, "grabsKnob"), DelayBefore = Json.Num(p, "delayBefore"),
                });
            }
            var t = Json.Obj(Json.Get(d, "typing"));
            if (t == null) throw new FormatException("Unknown picker step");
            var pieces = Json.Arr(Json.Get(t, "pieces")).Select(x =>
            {
                var pd = Json.Obj(x);
                if (Json.Get(pd, "key") != null) return TypingPiece.KeyPiece(Stroke(Json.Get(pd, "key")));
                if (Json.Get(pd, "text") != null) return TypingPiece.TextPiece(Template(Json.Get(pd, "text")));
                return TypingPiece.PastePiece(Template(Json.Get(pd, "paste")), Stroke(Json.Get(pd, "shortcut")));
            }).ToList();
            return PickerStep.Of(new TypingStep { Pieces = pieces, DelayBefore = Json.Num(t, "delayBefore") });
        }

        public static object Profile(ColorPickerProfile p) => D(
            "appKey", p.AppKey, "appName", p.AppName, "steps", p.Steps.Select(Step).ToList<object>(),
            "keyMap", p.KeyMap.ToDictionary(kv => kv.Key, kv => Stroke(kv.Value)),
            "space", p.Space.HasValue ? p.Space.Value.ToString() : null, "summary", p.Summary,
            "learnedAt", p.LearnedAt.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture), "hypothesisKey", p.HypothesisKey,
            "pointerBounds", p.PointerBounds.HasValue ? Rect(p.PointerBounds.Value) : null, "isExact", p.IsExact,
            "swatches", p.Swatches != null ? p.Swatches.Select(s => (object)D("point", Point(s.Point), "color", Color(s.Color), "clickCount", s.ClickCount)).ToList() : null);

        public static ColorPickerProfile Profile(object o)
        {
            var d = Json.Obj(o);
            if (d == null) throw new FormatException("Profile is not an object");
            var km = Json.Obj(Json.Get(d, "keyMap")) ?? new Dictionary<string, object>();
            var spaceS = Json.Str(d, "space");
            PickerColorSpace sp;
            DateTime at;
            var sw = Json.Get(d, "swatches");
            return new ColorPickerProfile
            {
                AppKey = Json.Str(d, "appKey", ""), AppName = Json.Str(d, "appName", ""),
                Steps = Json.Arr(Json.Get(d, "steps")).Select(Step).ToList(),
                KeyMap = km.ToDictionary(kv => kv.Key, kv => Stroke(kv.Value)),
                Space = spaceS != null && System.Enum.TryParse(spaceS, out sp) ? sp : (PickerColorSpace?)null,
                Summary = Json.Str(d, "summary", ""),
                LearnedAt = DateTime.TryParse(Json.Str(d, "learnedAt", ""), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out at) ? at : DateTime.UtcNow,
                HypothesisKey = Json.Str(d, "hypothesisKey", ""), PointerBounds = Rect(Json.Get(d, "pointerBounds")), IsExact = Json.Bool(d, "isExact"),
                Swatches = sw == null ? null : Json.Arr(sw).Select(x =>
                {
                    var sd = Json.Obj(x);
                    return new PaletteSwatch(Point(Json.Get(sd, "point")), Color(Json.Get(sd, "color")), Json.Int(sd, "clickCount", 1));
                }).ToList(),
            };
        }

        /// <summary>Profiles keyed by app; one unreadable profile does not lose the others.</summary>
        public static Dictionary<string, ColorPickerProfile> Profiles(string json)
        {
            var result = new Dictionary<string, ColorPickerProfile>();
            Dictionary<string, object> d;
            try { d = Json.Obj(Json.Parse(json)); } catch (Exception) { return result; }
            if (d == null) return result;
            foreach (var kv in d)
            {
                try { result[kv.Key] = Profile(kv.Value); } catch (Exception) { }
            }
            return result;
        }

        public static string Profiles(Dictionary<string, ColorPickerProfile> profiles)
            => Json.Write(profiles.ToDictionary(kv => kv.Key, kv => Profile(kv.Value)));
    }
}
