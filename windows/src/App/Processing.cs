using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using DrawBot.Core;

namespace DrawBot.App
{
    /// <summary>Everything that determines a quantization result.</summary>
    public sealed class ProcessingKey : IEquatable<ProcessingKey>
    {
        public int ImageToken;
        public GridLayout Layout;
        public QuantizeOptions Options;
        /// <summary>True when there is no canvas yet: an aspect-ratio preview grid, no strokes planned.</summary>
        public bool IsPreviewLayout;
        /// <summary>Apps with only fixed swatches: the image's colors are moved to the nearest of these.</summary>
        public RGB[] SnapPalette;
        public StrokeStyle StrokeStyle = StrokeStyle.Paths;

        public bool Equals(ProcessingKey o) => o != null && ImageToken == o.ImageToken && Equals(Layout, o.Layout) && Equals(Options, o.Options)
            && IsPreviewLayout == o.IsPreviewLayout && StrokeStyle == o.StrokeStyle
            && (SnapPalette == null ? o.SnapPalette == null : o.SnapPalette != null && SnapPalette.SequenceEqual(o.SnapPalette));
        public override bool Equals(object obj) => Equals(obj as ProcessingKey);
        public override int GetHashCode() => ImageToken;
    }

    public sealed class ProcessedResult
    {
        public ProcessingKey Key;
        public QuantizedImage Quantized;
        public Bitmap Preview;
        /// <summary>Strokes[paletteIndex] (empty for preview layouts).</summary>
        public List<List<ScreenStroke>> Strokes = new List<List<ScreenStroke>>();
        /// <summary>Estimates[preset][paletteIndex] in seconds (empty for preview layouts).</summary>
        public Dictionary<SpeedPreset, double[]> Estimates = new Dictionary<SpeedPreset, double[]>();
    }

    /// <summary>
    /// Background quantization with coalescing: rapid requests (slider drags) collapse into one,
    /// and results of superseded requests are dropped via a generation counter. Completions run on
    /// the UI thread.
    /// </summary>
    public sealed class ImageProcessor
    {
        readonly SynchronizationContext ui = SynchronizationContext.Current;
        readonly object l = new object();
        int generation, previewGeneration;

        int CurrentGeneration { get { lock (l) return generation; } }

        public void Cancel() { lock (l) generation++; }

        public void Process(RGBAImage image, ProcessingKey key, Action<ProcessedResult> completion, int debounceMs = 120)
        {
            int gen;
            lock (l) gen = ++generation;
            Task.Run(async () =>
            {
                await Task.Delay(debounceMs);
                if (CurrentGeneration != gen) return;
                ProcessedResult r = null;
                try { r = Compute(image, key, () => CurrentGeneration != gen); } catch (Exception) { }
                if (r == null) return;
                Post(() => { if (CurrentGeneration == gen) completion(r); });
            });
        }

        void Post(Action a) { if (ui != null) ui.Post(_ => a(), null); else a(); }

        public static ProcessedResult Compute(RGBAImage image, ProcessingKey key, Func<bool> stale)
        {
            var layout = key.Layout;
            var raster = ImageLoader.Rasterize(image, layout.Columns, layout.Rows);
            if (stale()) return null;
            var options = key.Options.Copy();
            // Only one preset color to choose from: draw it as a doodle too.
            if (key.SnapPalette != null && key.SnapPalette.Length == 1) options.MaxColors = 1;
            var q = Quantizer.Quantize(raster, options);
            if (key.SnapPalette != null) q = Quantizer.Snap(q, key.SnapPalette);
            if (stale()) return null;
            var result = new ProcessedResult { Key = key, Quantized = q, Preview = ImageLoader.ToBitmap(Quantizer.PreviewImage(q)) };
            if (!key.IsPreviewLayout)
            {
                for (int i = 0; i < q.Palette.Length; i++)
                {
                    if (stale()) return null;
                    result.Strokes.Add(StrokePlanner.Strokes(i, q, layout, key.StrokeStyle));
                }
                foreach (var preset in EnumNames.All<SpeedPreset>())
                    result.Estimates[preset] = result.Strokes.Select(s => TimeEstimator.Estimate(s, preset.Settings())).ToArray();
            }
            return stale() ? null : result;
        }

        /// <summary>Preview with skipped colors removed, rendered off the UI thread. Latest request wins.</summary>
        public void RenderPreview(QuantizedImage q, ICollection<int> skip, Action<Bitmap> completion)
        {
            int gen;
            lock (l) gen = ++previewGeneration;
            var skipCopy = skip.ToList();
            Task.Run(() =>
            {
                var bmp = ImageLoader.ToBitmap(Quantizer.PreviewImage(skipCopy.Count == 0 ? q : Quantizer.Removing(skipCopy, q)));
                Post(() => { bool current; lock (l) current = previewGeneration == gen; if (current) completion(bmp); });
            });
        }

        /// <summary>Preview grid used before a canvas exists: the image's aspect ratio, ~240 cells on the long side.</summary>
        public static GridLayout PreviewLayout(RGBAImage image)
        {
            double w = Math.Max(1, image.Width), h = Math.Max(1, image.Height);
            const double longSide = 240;
            double cols = w >= h ? longSide : Math.Max(1, Num.Round(longSide * w / h));
            double rows = w >= h ? Math.Max(1, Num.Round(longSide * h / w)) : longSide;
            return new GridLayout(new RectD(0, 0, cols, rows), 1);
        }
    }
}
