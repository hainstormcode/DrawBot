using System;
using System.Collections.Generic;
using System.Linq;

// Color Learn: vocabulary shared by the recorder, the learner (ColorLearner) and the replayer.
// The user selects two (or more) requested colors in their drawing app's color picker while
// DrawBot records the mouse and keyboard. ColorLearner turns those demonstrations into a
// ColorPickerProfile; ColorPickerProfile.Actions(color, previous) then produces concrete input
// for any color. All points are virtual-screen pixels (y down).

namespace DrawBot.Core
{
    [Flags]
    public enum KeyModifiers
    {
        None = 0,
        Shift = 1,
        Control = 2,
        /// <summary>Alt.</summary>
        Option = 4,
        /// <summary>The Windows key.</summary>
        Command = 8,
    }

    public enum PointerButton { Left = 0, Right = 1 }

    /// <summary>One key press (down + up): a Windows virtual-key code plus the characters it produced.</summary>
    public sealed class KeyStroke : IEquatable<KeyStroke>
    {
        public ushort KeyCode;
        public string Characters;
        public KeyModifiers Modifiers;

        public KeyStroke(ushort keyCode, string characters, KeyModifiers modifiers = KeyModifiers.None)
        {
            KeyCode = keyCode; Characters = characters ?? ""; Modifiers = modifiers;
        }

        /// <summary>Ctrl or Win held: a shortcut, not text.</summary>
        public bool IsShortcut => (Modifiers & (KeyModifiers.Control | KeyModifiers.Command)) != 0;

        public bool Equals(KeyStroke o) => o != null && KeyCode == o.KeyCode && Characters == o.Characters && Modifiers == o.Modifiers;
        public override bool Equals(object obj) => Equals(obj as KeyStroke);
        public override int GetHashCode() => KeyCode * 31 + (int)Modifiers;
        public override string ToString() => "key(" + KeyCode + "," + Characters + "," + (int)Modifiers + ")";
    }

    /// <summary>Windows virtual-key codes used by Color Learn.</summary>
    public static class VirtualKey
    {
        public const ushort A = 0x41;
        public const ushort V = 0x56;
        public const ushort Return = 0x0D;
        public const ushort Tab = 0x09;
        public const ushort Space = 0x20;
        /// <summary>Backspace.</summary>
        public const ushort Delete = 0x08;
        public const ushort Escape = 0x1B;
        public const ushort Enter = 0x0D;
        public const ushort ForwardDelete = 0x2E;
        public const ushort Insert = 0x2D;
        /// <summary>A key with no virtual-key code: replayed as a Unicode character.</summary>
        public const ushort Unicode = 0xFFFF;

        /// <summary>Keys that never produce text, even when their characters is non-empty.</summary>
        public static readonly HashSet<ushort> NonText = new HashSet<ushort>(new ushort[] {
            0x08, 0x09, 0x0D, 0x1B, 0x2E, 0x2D, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x14,
            0x10, 0x11, 0x12, 0x5B, 0x5C, 0x5D, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x13, 0x2C, 0x91, 0x90,
        }.Concat(Enumerable.Range(0x70, 24).Select(i => (ushort)i)));

        static readonly Dictionary<char, KeyValuePair<ushort, bool>> UsLayout = BuildUs();

        static Dictionary<char, KeyValuePair<ushort, bool>> BuildUs()
        {
            var m = new Dictionary<char, KeyValuePair<ushort, bool>>();
            for (char c = 'a'; c <= 'z'; c++)
            {
                m[c] = new KeyValuePair<ushort, bool>((ushort)char.ToUpperInvariant(c), false);
                m[char.ToUpperInvariant(c)] = new KeyValuePair<ushort, bool>((ushort)char.ToUpperInvariant(c), true);
            }
            for (char c = '0'; c <= '9'; c++) m[c] = new KeyValuePair<ushort, bool>((ushort)c, false);
            Action<char, ushort, bool> add = (ch, code, shift) => m[ch] = new KeyValuePair<ushort, bool>(code, shift);
            add('#', 0x33, true);
            add('%', 0x35, true);
            add('.', 0xBE, false);
            add(',', 0xBC, false);
            add('-', 0xBD, false);
            add(' ', 0x20, false);
            add('/', 0xBF, false);
            add(';', 0xBA, false);
            add(':', 0xBA, true);
            add('(', 0x39, true);
            add(')', 0x30, true);
            return m;
        }

        /// <summary>A keystroke that types ch on a US layout (the replayer prefers the active layout and Unicode input).</summary>
        public static KeyStroke Stroke(char ch)
        {
            KeyValuePair<ushort, bool> v;
            if (UsLayout.TryGetValue(ch, out v))
                return new KeyStroke(v.Key, ch.ToString(), v.Value ? KeyModifiers.Shift : KeyModifiers.None);
            return new KeyStroke(Unicode, ch.ToString());
        }
    }

    // MARK: - Recording

    public enum InputKind { MouseDown, MouseDragged, MouseUp, KeyDown }

    /// <summary>One recorded input event.</summary>
    public sealed class RecordedInput : IEquatable<RecordedInput>
    {
        public InputKind Kind;
        /// <summary>Seconds (any monotonic clock; only differences matter).</summary>
        public double Time;
        /// <summary>For key events: wherever the cursor was.</summary>
        public PointD Point;
        public PointerButton Button;
        /// <summary>1 for a single click, 2 for the second press of a double-click, …</summary>
        public int ClickCount = 1;
        public ushort KeyCode;
        /// <summary>Characters produced (for shortcuts: the characters ignoring modifiers).</summary>
        public string Characters = "";
        public KeyModifiers Modifiers;
        /// <summary>For a paste shortcut (Ctrl+V): the clipboard text at that moment.</summary>
        public string PasteText;

        public static RecordedInput Mouse(InputKind kind, PointD point, double time, PointerButton button = PointerButton.Left,
                                          int clickCount = 1, KeyModifiers modifiers = KeyModifiers.None)
            => new RecordedInput { Kind = kind, Point = point, Time = time, Button = button, ClickCount = clickCount, Modifiers = modifiers };

        public static RecordedInput Key(ushort keyCode, string characters, double time, KeyModifiers modifiers = KeyModifiers.None, string pasteText = null)
            => new RecordedInput { Kind = InputKind.KeyDown, KeyCode = keyCode, Characters = characters ?? "", Time = time, Modifiers = modifiers, PasteText = pasteText };

        public bool Equals(RecordedInput o) => o != null && Kind == o.Kind && Time == o.Time && Point == o.Point && Button == o.Button
            && ClickCount == o.ClickCount && KeyCode == o.KeyCode && Characters == o.Characters && Modifiers == o.Modifiers && PasteText == o.PasteText;
        public override bool Equals(object obj) => Equals(obj as RecordedInput);
        public override int GetHashCode() => Time.GetHashCode();
    }

    /// <summary>The user selecting one requested color.</summary>
    public sealed class ColorDemo
    {
        public RGB Color;
        /// <summary>The color the picker showed before this demo, when known.</summary>
        public RGB? PreviousColor;
        public List<RecordedInput> Inputs;
        public ColorDemo(RGB color, RGB? previousColor, IEnumerable<RecordedInput> inputs)
        {
            Color = color; PreviousColor = previousColor; Inputs = inputs.ToList();
        }
    }

    // MARK: - Color parameters

    public enum ColorParam { Red, Green, Blue, Hue, HsbSaturation, HsbBrightness, HslSaturation, HslLightness }

    public static class ColorParams
    {
        public static readonly ColorParam[] All = EnumNames.All<ColorParam>();

        /// <summary>Natural full range: 255 for RGB, 360 for hue, 100 for the rest.</summary>
        public static double Range(this ColorParam p)
        {
            switch (p)
            {
                case ColorParam.Red: case ColorParam.Green: case ColorParam.Blue: return 255;
                case ColorParam.Hue: return 360;
                default: return 100;
            }
        }

        public static string RawName(this ColorParam p)
        {
            var s = p.ToString();
            return char.ToLowerInvariant(s[0]) + s.Substring(1);
        }

        public static string DisplayName(this ColorParam p)
        {
            switch (p)
            {
                case ColorParam.Red: return "red";
                case ColorParam.Green: return "green";
                case ColorParam.Blue: return "blue";
                case ColorParam.Hue: return "hue";
                case ColorParam.HsbSaturation: return "saturation";
                case ColorParam.HsbBrightness: return "brightness";
                case ColorParam.HslSaturation: return "saturation (HSL)";
                default: return "lightness";
            }
        }

        public static double Value(this ColorParam p, RGB c)
        {
            switch (p)
            {
                case ColorParam.Red: return c.R;
                case ColorParam.Green: return c.G;
                case ColorParam.Blue: return c.B;
                case ColorParam.Hue: return ColorMath.Hsb(c)[0];
                case ColorParam.HsbSaturation: return ColorMath.Hsb(c)[1];
                case ColorParam.HsbBrightness: return ColorMath.Hsb(c)[2];
                case ColorParam.HslSaturation: return ColorMath.Hsl(c)[1];
                default: return ColorMath.Hsl(c)[2];
            }
        }
    }

    public enum PickerColorSpace { Hsb, Hsl, Rgb }

    public static class PickerColorSpaces
    {
        public static readonly PickerColorSpace[] All = { PickerColorSpace.Hsb, PickerColorSpace.Hsl, PickerColorSpace.Rgb };

        public static ColorParam[] Params(this PickerColorSpace s)
        {
            switch (s)
            {
                case PickerColorSpace.Hsb: return new[] { ColorParam.Hue, ColorParam.HsbSaturation, ColorParam.HsbBrightness };
                case PickerColorSpace.Hsl: return new[] { ColorParam.Hue, ColorParam.HslSaturation, ColorParam.HslLightness };
                default: return new[] { ColorParam.Red, ColorParam.Green, ColorParam.Blue };
            }
        }

        public static string RawName(this PickerColorSpace s) => s.ToString().ToLowerInvariant();

        /// <summary>True when knowing params pins down the whole color.</summary>
        public static bool Determines(ISet<ColorParam> ps) => All.Any(s => ps.IsSupersetOf(s.Params()));
    }

    // MARK: - Typed values

    /// <summary>A color-dependent value the user typed (or pasted): a hex code, or one parameter at some scale.</summary>
    public sealed class ValueSlot : IEquatable<ValueSlot>
    {
        public readonly bool IsHex;
        public readonly bool Uppercase;
        public readonly ColorParam Param;
        public readonly double FullScale;
        public readonly int Decimals;

        ValueSlot(bool isHex, bool upper, ColorParam p, double scale, int decimals)
        {
            IsHex = isHex; Uppercase = upper; Param = p; FullScale = scale; Decimals = decimals;
        }

        public static ValueSlot Hex(bool uppercase) => new ValueSlot(true, uppercase, ColorParam.Red, 0, 0);
        public static ValueSlot Number(ColorParam param, double fullScale, int decimals) => new ValueSlot(false, false, param, fullScale, decimals);

        public string Format(RGB c)
        {
            if (IsHex) return Uppercase ? c.HexNoHash : c.HexNoHash.ToLowerInvariant();
            double v = Param.Value(c) / Param.Range() * FullScale;
            if (Decimals == 0)
            {
                int i = (int)Num.Round(v);
                if (Param == ColorParam.Hue && i >= FullScale) i = 0;
                return i.ToString();
            }
            if (Param == ColorParam.Hue && v >= FullScale) v = 0;
            return Num.F(v, Decimals);
        }

        public ISet<ColorParam> Params => IsHex
            ? new HashSet<ColorParam> { ColorParam.Red, ColorParam.Green, ColorParam.Blue }
            : new HashSet<ColorParam> { Param };

        /// <summary>Lower = preferred when several interpretations fit every demo.</summary>
        public int Priority
        {
            get
            {
                if (IsHex) return 0;
                if ((Param == ColorParam.Red || Param == ColorParam.Green || Param == ColorParam.Blue) && FullScale == 255) return 1;
                if (Param == ColorParam.Hue && FullScale == 360) return 2;
                if ((Param == ColorParam.HsbSaturation || Param == ColorParam.HsbBrightness) && FullScale == 100) return 3;
                if ((Param == ColorParam.HslSaturation || Param == ColorParam.HslLightness) && FullScale == 100) return 4;
                if (FullScale == 1) return 5;
                return 6;
            }
        }

        public string DisplayName => IsHex ? "hex code" : Param.DisplayName() + " value";

        public bool Equals(ValueSlot o) => o != null && IsHex == o.IsHex && (IsHex ? Uppercase == o.Uppercase
            : Param == o.Param && FullScale == o.FullScale && Decimals == o.Decimals);
        public override bool Equals(object obj) => Equals(obj as ValueSlot);
        public override int GetHashCode() => IsHex ? (Uppercase ? 1 : 2) : ((int)Param * 1000 + (int)FullScale) * 10 + Decimals;
        public override string ToString() => IsHex ? "hex(uppercase: " + (Uppercase ? "true" : "false") + ")"
            : "number(param: " + Param.RawName() + ", fullScale: " + Num.Inv(FullScale) + ", decimals: " + Decimals + ")";
    }

    public sealed class TextPart : IEquatable<TextPart>
    {
        public readonly string Literal;
        public readonly ValueSlot Slot;
        TextPart(string literal, ValueSlot slot) { Literal = literal; Slot = slot; }
        public static TextPart Lit(string s) => new TextPart(s, null);
        public static TextPart Of(ValueSlot s) => new TextPart(null, s);
        public bool IsSlot => Slot != null;
        public bool Equals(TextPart o) => o != null && Literal == o.Literal && Equals(Slot, o.Slot);
        public override bool Equals(object obj) => Equals(obj as TextPart);
        public override int GetHashCode() => Literal != null ? Literal.GetHashCode() : Slot.GetHashCode();
    }

    /// <summary>Text with color-dependent holes, e.g. "#" + hex, or red + ", " + green + ", " + blue.</summary>
    public sealed class TextTemplate : IEquatable<TextTemplate>
    {
        public List<TextPart> Parts;
        public TextTemplate(IEnumerable<TextPart> parts) { Parts = parts.ToList(); }
        public string Format(RGB c) => string.Concat(Parts.Select(p => p.IsSlot ? p.Slot.Format(c) : p.Literal));
        public List<ValueSlot> Slots => Parts.Where(p => p.IsSlot).Select(p => p.Slot).ToList();
        public bool Equals(TextTemplate o) => o != null && Parts.SequenceEqual(o.Parts);
        public override bool Equals(object obj) => Equals(obj as TextTemplate);
        public override int GetHashCode() => Parts.Count;
    }

    // MARK: - Pointer mappings

    public enum ScreenAxis { X, Y }

    /// <summary>coordinate = offset + slope × param value.</summary>
    public sealed class LinearMap : IEquatable<LinearMap>
    {
        public ColorParam Param;
        public double Offset;
        public double Slope;
        public LinearMap(ColorParam param, double offset, double slope) { Param = param; Offset = offset; Slope = slope; }

        /// <summary>push moves values at the very ends of the range outward (&gt; 0) or inward (&lt; 0).</summary>
        public double Coordinate(RGB c, double push)
        {
            double v = Param.Value(c);
            double pos = Offset + Slope * v;
            double frac = v / Param.Range();
            double dir = Slope >= 0 ? 1 : -1;
            if (frac <= 0.004) pos -= dir * push;
            else if (frac >= 0.996) pos += dir * push;
            return pos;
        }

        /// <summary>Margin kept from the estimated ends when pressing.</summary>
        public double SafeInset => Math.Max(5, 0.06 * Extent);

        public double SafeCoordinate(RGB c)
        {
            double lo, hi; Interval(out lo, out hi);
            double pos = Offset + Slope * Param.Value(c);
            double m = Math.Min(SafeInset, (hi - lo) / 2);
            return Math.Min(Math.Max(pos, lo + m), hi - m);
        }

        public void Interval(out double lo, out double hi)
        {
            double a = Offset, b = Offset + Slope * Param.Range();
            lo = Math.Min(a, b); hi = Math.Max(a, b);
        }

        public double Extent => Math.Abs(Slope) * Param.Range();

        public bool Equals(LinearMap o) => o != null && Param == o.Param && Offset == o.Offset && Slope == o.Slope;
        public override bool Equals(object obj) => Equals(obj as LinearMap);
        public override int GetHashCode() => (int)Param ^ Offset.GetHashCode() ^ Slope.GetHashCode();
    }

    /// <summary>Point = center + w × r × e^(i·direction·hue), with r = radius param / range (1 for a hue ring).</summary>
    public sealed class PolarMap : IEquatable<PolarMap>
    {
        public ColorParam? Radius;
        public double CenterX, CenterY, WRe, WIm, Direction;

        public PolarMap(ColorParam? radius, double centerX, double centerY, double wRe, double wIm, double direction)
        {
            Radius = radius; CenterX = centerX; CenterY = centerY; WRe = wRe; WIm = wIm; Direction = direction;
        }

        public double Scale => Math.Sqrt(WRe * WRe + WIm * WIm);

        public PointD SafePoint(RGB c)
        {
            if (!Radius.HasValue) return Point(c, 0);
            var rp = Radius.Value;
            double limit = Math.Max(0, 1 - Math.Max(5, 0.06 * Scale) / Math.Max(1, Scale));
            double h = ColorParam.Hue.Value(c) * Math.PI / 180 * Direction;
            double r = Math.Min(rp.Value(c) / rp.Range(), limit);
            double zr = r * Math.Cos(h), zi = r * Math.Sin(h);
            return new PointD(CenterX + WRe * zr - WIm * zi, CenterY + WRe * zi + WIm * zr);
        }

        public PointD Point(RGB c, double push)
        {
            double h = ColorParam.Hue.Value(c) * Math.PI / 180 * Direction;
            double r = 1.0;
            if (Radius.HasValue)
            {
                var rp = Radius.Value;
                r = rp.Value(c) / rp.Range();
                if (r >= 0.996) r += push / Math.Max(1, Scale);
                if (r <= 0.004) r = 0;
            }
            double zr = r * Math.Cos(h), zi = r * Math.Sin(h);
            return new PointD(CenterX + WRe * zr - WIm * zi, CenterY + WRe * zi + WIm * zr);
        }

        public bool Equals(PolarMap o) => o != null && Radius == o.Radius && CenterX == o.CenterX && CenterY == o.CenterY
            && WRe == o.WRe && WIm == o.WIm && Direction == o.Direction;
        public override bool Equals(object obj) => Equals(obj as PolarMap);
        public override int GetHashCode() => CenterX.GetHashCode() ^ CenterY.GetHashCode();
    }

    public enum MappingKind { Fixed, Axis, Plane, Polar }

    /// <summary>Where a pointer step clicks, as a function of the color.</summary>
    public sealed class ControlMapping : IEquatable<ControlMapping>
    {
        public readonly MappingKind Kind;
        public readonly PointD FixedPoint;
        public readonly ScreenAxis Axis;
        public readonly LinearMap Map;
        public readonly double Other;
        public readonly LinearMap MapX, MapY;
        public readonly PolarMap PolarM;

        ControlMapping(MappingKind kind, PointD p = default(PointD), ScreenAxis axis = ScreenAxis.X, LinearMap map = null, double other = 0,
                       LinearMap mx = null, LinearMap my = null, PolarMap pm = null)
        {
            Kind = kind; FixedPoint = p; Axis = axis; Map = map; Other = other; MapX = mx; MapY = my; PolarM = pm;
        }

        /// <summary>Always the same spot (a button, a swatch, a text field).</summary>
        public static ControlMapping Fixed(PointD p) => new ControlMapping(MappingKind.Fixed, p);
        /// <summary>A slider along one screen axis.</summary>
        public static ControlMapping AxisMap(ScreenAxis axis, LinearMap map, double other) => new ControlMapping(MappingKind.Axis, axis: axis, map: map, other: other);
        /// <summary>A 2-D area, e.g. a saturation × brightness square.</summary>
        public static ControlMapping Plane(LinearMap x, LinearMap y) => new ControlMapping(MappingKind.Plane, mx: x, my: y);
        /// <summary>A color wheel (hue = angle, radius = saturation) or a hue ring.</summary>
        public static ControlMapping Polar(PolarMap pm) => new ControlMapping(MappingKind.Polar, pm: pm);

        public PointD Point(RGB c, double push = 0)
        {
            switch (Kind)
            {
                case MappingKind.Fixed: return FixedPoint;
                case MappingKind.Axis:
                    {
                        double v = Map.Coordinate(c, push);
                        return Axis == ScreenAxis.X ? new PointD(v, Other) : new PointD(Other, v);
                    }
                case MappingKind.Plane: return new PointD(MapX.Coordinate(c, push), MapY.Coordinate(c, push));
                default: return PolarM.Point(c, push);
            }
        }

        /// <summary>Where to press for c: on target, but never within the safety margin of the control's estimated edges.</summary>
        public PointD SafePoint(RGB c)
        {
            switch (Kind)
            {
                case MappingKind.Fixed: return FixedPoint;
                case MappingKind.Axis:
                    {
                        double v = Map.SafeCoordinate(c);
                        return Axis == ScreenAxis.X ? new PointD(v, Other) : new PointD(Other, v);
                    }
                case MappingKind.Plane: return new PointD(MapX.SafeCoordinate(c), MapY.SafeCoordinate(c));
                default: return PolarM.SafePoint(c);
            }
        }

        public string Describe
        {
            get
            {
                switch (Kind)
                {
                    case MappingKind.Fixed: return "a fixed spot";
                    case MappingKind.Axis: return "a " + Map.Param.DisplayName() + " slider";
                    case MappingKind.Plane: return "a " + MapX.Param.DisplayName() + " × " + MapY.Param.DisplayName() + " area";
                    default:
                        return PolarM.Radius.HasValue ? "a color wheel (hue × " + PolarM.Radius.Value.DisplayName() + ")" : "a hue ring";
                }
            }
        }

        public bool Equals(ControlMapping o) => o != null && Kind == o.Kind && FixedPoint == o.FixedPoint && Axis == o.Axis
            && Equals(Map, o.Map) && Other == o.Other && Equals(MapX, o.MapX) && Equals(MapY, o.MapY) && Equals(PolarM, o.PolarM);
        public override bool Equals(object obj) => Equals(obj as ControlMapping);
        public override int GetHashCode() => (int)Kind;
    }

    // MARK: - Profile

    public sealed class PointerStep
    {
        public ControlMapping Mapping;
        public PointerButton Button;
        public int ClickCount = 1;
        public KeyModifiers Modifiers;
        /// <summary>The user dragged (rather than clicked).</summary>
        public bool IsDrag;
        /// <summary>Fixed drags: where the drag started.</summary>
        public PointD? DragStart;
        /// <summary>The user grabbed the control's knob where the previous color had left it and dragged it.</summary>
        public bool GrabsKnob;
        /// <summary>Pause before this step, seconds.</summary>
        public double DelayBefore;

        public ReplayAction Replay(RGB c, RGB? previous)
        {
            if (Mapping.Kind == MappingKind.Fixed)
            {
                if (IsDrag && DragStart.HasValue) return ReplayAction.Drag(DragStart.Value, Mapping.FixedPoint, Button, Modifiers);
                return ReplayAction.Click(Mapping.FixedPoint, Button, Math.Max(1, ClickCount), Modifiers);
            }
            // Press safely inside the control (the fitted edges are only approximate), then drag
            // onto the target; overshoot slightly at an edge so the picker clamps onto the extreme.
            var target = Mapping.Point(c, 4);
            PointD? knob = GrabsKnob && previous.HasValue ? Mapping.Point(previous.Value) : (PointD?)null;
            var start = knob ?? Mapping.SafePoint(c);
            return ReplayAction.Drag(start, target, Button, Modifiers);
        }
    }

    public enum TypingPieceKind { Key, Text, Paste }

    public sealed class TypingPiece
    {
        public TypingPieceKind Kind;
        public KeyStroke Stroke;          // Key; Paste: the shortcut
        public TextTemplate Template;     // Text, Paste
        public static TypingPiece KeyPiece(KeyStroke k) => new TypingPiece { Kind = TypingPieceKind.Key, Stroke = k };
        public static TypingPiece TextPiece(TextTemplate t) => new TypingPiece { Kind = TypingPieceKind.Text, Template = t };
        public static TypingPiece PastePiece(TextTemplate t, KeyStroke shortcut) => new TypingPiece { Kind = TypingPieceKind.Paste, Template = t, Stroke = shortcut };
    }

    public sealed class TypingStep
    {
        public List<TypingPiece> Pieces = new List<TypingPiece>();
        public double DelayBefore;
    }

    public sealed class PickerStep
    {
        public PointerStep Pointer;
        public TypingStep Typing;
        public static PickerStep Of(PointerStep p) => new PickerStep { Pointer = p };
        public static PickerStep Of(TypingStep t) => new PickerStep { Typing = t };
    }

    public enum ReplayKind { Click, Drag, Key, SetClipboard, Wait, Move }

    /// <summary>Concrete input for the replayer.</summary>
    public sealed class ReplayAction : IEquatable<ReplayAction>
    {
        public ReplayKind Kind;
        public PointD At;         // Click, Move; Drag: from
        public PointD To;         // Drag
        public PointerButton Button;
        public int Count = 1;
        public KeyModifiers Modifiers;
        public KeyStroke Stroke;
        public string Text;
        public double Seconds;

        public static ReplayAction Click(PointD at, PointerButton button, int count, KeyModifiers mods)
            => new ReplayAction { Kind = ReplayKind.Click, At = at, Button = button, Count = count, Modifiers = mods };
        /// <summary>Press at from, drag to to, release. from == to: press, wiggle by half a pixel, release.</summary>
        public static ReplayAction Drag(PointD from, PointD to, PointerButton button, KeyModifiers mods)
            => new ReplayAction { Kind = ReplayKind.Drag, At = from, To = to, Button = button, Modifiers = mods };
        public static ReplayAction Key(KeyStroke k) => new ReplayAction { Kind = ReplayKind.Key, Stroke = k };
        public static ReplayAction SetClipboard(string s) => new ReplayAction { Kind = ReplayKind.SetClipboard, Text = s };
        public static ReplayAction Wait(double t) => new ReplayAction { Kind = ReplayKind.Wait, Seconds = t };
        /// <summary>Move the pointer without pressing (test tooling; profiles never produce it).</summary>
        public static ReplayAction Move(PointD p) => new ReplayAction { Kind = ReplayKind.Move, At = p };

        public bool Equals(ReplayAction o) => o != null && Kind == o.Kind && At == o.At && To == o.To && Button == o.Button && Count == o.Count
            && Modifiers == o.Modifiers && Equals(Stroke, o.Stroke) && Text == o.Text && Seconds == o.Seconds;
        public override bool Equals(object obj) => Equals(obj as ReplayAction);
        public override int GetHashCode() => (int)Kind;
        public override string ToString()
        {
            switch (Kind)
            {
                case ReplayKind.Click: return "click(" + At + " ×" + Count + ")";
                case ReplayKind.Drag: return "drag(" + At + " → " + To + ")";
                case ReplayKind.Key: return Stroke.ToString();
                case ReplayKind.SetClipboard: return "clipboard(" + Text + ")";
                case ReplayKind.Wait: return "wait(" + Num.F(Seconds, 2) + ")";
                default: return "move(" + At + ")";
            }
        }
    }

    /// <summary>How to select any color in one app's color picker.</summary>
    public sealed class ColorPickerProfile
    {
        /// <summary>Executable (or another stable key) of the app, plus the website for browsers.</summary>
        public string AppKey;
        public string AppName;
        public List<PickerStep> Steps = new List<PickerStep>();
        /// <summary>How the user typed each character (key code + modifiers), for the replayer.</summary>
        public Dictionary<string, KeyStroke> KeyMap = new Dictionary<string, KeyStroke>();
        /// <summary>Pointer-based profiles: the color model the picker uses.</summary>
        public PickerColorSpace? Space;
        public string Summary = "";
        public DateTime LearnedAt;
        /// <summary>Identifies the interpretation (so a rejected one is not offered again).</summary>
        public string HypothesisKey = "";
        /// <summary>Bounding box of every point the profile clicks, so DrawBot can keep its own windows out of the way.</summary>
        public RectD? PointerBounds;
        /// <summary>True when the color is typed (exact); false when it is clicked (approximate).</summary>
        public bool IsExact;
        /// <summary>Apps with only fixed swatches: the swatches and their colors.</summary>
        public List<PaletteSwatch> Swatches;

        public ColorPickerProfile Copy()
        {
            var p = (ColorPickerProfile)MemberwiseClone();
            return p;
        }

        /// <summary>The swatch closest to color (palette profiles only).</summary>
        public PaletteSwatch NearestSwatch(RGB color)
        {
            if (Swatches == null || Swatches.Count == 0) return null;
            var l = ColorMath.Lab(color);
            PaletteSwatch best = null; double bestD = double.PositiveInfinity;
            foreach (var s in Swatches)
            {
                double d = ColorMath.DeltaE(ColorMath.Lab(s.Color), l);
                if (d < bestD) { bestD = d; best = s; }
            }
            return best;
        }

        /// <summary>The color values this profile types or pastes (empty for a click-only profile).</summary>
        public List<ValueSlot> TypedSlots =>
            Steps.Where(s => s.Typing != null).SelectMany(s => s.Typing.Pieces)
                 .Where(p => p.Kind != TypingPieceKind.Key).SelectMany(p => p.Template.Slots).ToList();

        /// <summary>The input that selects color. previous is the color the picker currently shows, if known.</summary>
        public List<ReplayAction> Actions(RGB color, RGB? previous)
        {
            var outp = new List<ReplayAction>();
            var swatch = NearestSwatch(color);
            if (swatch != null)
            {
                outp.Add(ReplayAction.Click(swatch.Point, PointerButton.Left, Math.Max(1, swatch.ClickCount), KeyModifiers.None));
                outp.Add(ReplayAction.Wait(0.3));
                return outp;
            }
            foreach (var step in Steps)
            {
                if (step.Pointer != null)
                {
                    if (step.Pointer.DelayBefore > 0) outp.Add(ReplayAction.Wait(step.Pointer.DelayBefore));
                    outp.Add(step.Pointer.Replay(color, previous));
                }
                else
                {
                    var t = step.Typing;
                    if (t.DelayBefore > 0) outp.Add(ReplayAction.Wait(t.DelayBefore));
                    foreach (var piece in t.Pieces)
                    {
                        if (piece.Kind == TypingPieceKind.Key) outp.Add(ReplayAction.Key(piece.Stroke));
                        else
                            // Pasted values are typed instead, so selecting colors never touches the clipboard.
                            foreach (var ch in piece.Template.Format(color)) outp.Add(ReplayAction.Key(StrokeFor(ch)));
                    }
                }
            }
            outp.Add(ReplayAction.Wait(0.3));   // let the app apply the color
            return outp;
        }

        public KeyStroke StrokeFor(char ch)
        {
            KeyStroke k;
            if (KeyMap != null && KeyMap.TryGetValue(ch.ToString(), out k)) return k;
            return VirtualKey.Stroke(ch);
        }
    }
}
