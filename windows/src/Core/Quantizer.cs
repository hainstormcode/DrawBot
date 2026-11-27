using System;
using System.Collections.Generic;
using System.Linq;

namespace DrawBot.Core
{
    /// <summary>Small, fast, deterministic RNG (SplitMix64).</summary>
    public struct SplitMix64
    {
        ulong state;
        public SplitMix64(ulong seed) { state = seed; }
        public ulong Next()
        {
            unchecked
            {
                state += 0x9E3779B97F4A7C15UL;
                ulong z = state;
                z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
                z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
                return z ^ (z >> 31);
            }
        }
        /// <summary>Uniform double in [0, 1).</summary>
        public double NextUnit() => (Next() >> 11) * (1.0 / 9007199254740992.0);
    }

    public static class Quantizer
    {
        public const int MaxSamplePixels = 60000;
        const int MaxIterations = 25;
        const float ConvergenceDelta = 0.1f;

        /// <summary>
        /// Reduces image to at most MaxColors colors (k-means in CIELAB, k-means++ seeding, near
        /// duplicates merged). Pixels with alpha &lt; AlphaThreshold get label -1. With MaxColors == 1
        /// the result is a doodle: two colors, and the lighter one is dropped.
        /// </summary>
        public static QuantizedImage Quantize(RGBAImage image, QuantizeOptions options)
        {
            if (options.MaxColors <= 1) return Ink(image, options);
            return QuantizeColors(image, options);
        }

        /// <summary>One-color doodle: two colors without merging, then the lighter (by CIELAB L) is dropped.</summary>
        public static QuantizedImage Ink(RGBAImage image, QuantizeOptions options)
        {
            var two = options.Copy();
            two.MaxColors = 2;
            two.MergeDistance = 0;
            var q = QuantizeColors(image, two);
            if (q.Palette.Length != 2) return q;
            int light = ColorMath.Lab(q.Palette[0]).L >= ColorMath.Lab(q.Palette[1]).L ? 0 : 1;
            int keep = 1 - light;
            var labels = q.Labels.Select(l => l == keep ? 0 : -1).ToArray();
            return new QuantizedImage(q.Width, q.Height, labels, new[] { q.Palette[keep] }, new[] { q.Counts[keep] });
        }

        static QuantizedImage QuantizeColors(RGBAImage image, QuantizeOptions options)
        {
            int w = image.Width, h = image.Height, n = w * h;
            int k = Math.Min(64, Math.Max(1, options.MaxColors));
            byte threshold = options.AlphaThreshold;
            var labels = new int[n];
            for (int i = 0; i < n; i++) labels[i] = -1;
            if (n == 0) return new QuantizedImage(w, h, labels, new RGB[0], new int[0]);

            var px = image.Data;
            var opaqueList = new List<int>(n);
            for (int i = 0; i < n; i++) if (px[i * 4 + 3] >= threshold) opaqueList.Add(i);
            var opaque = opaqueList.ToArray();
            int m = opaque.Length;
            if (m == 0) return new QuantizedImage(w, h, labels, new RGB[0], new int[0]);

            int clusterCount;
            int[] exactLabels; int exactCount;
            if (ExactColors(image, opaque, k, out exactLabels, out exactCount))
            {
                clusterCount = exactCount;
                for (int j = 0; j < m; j++) labels[opaque[j]] = exactLabels[j];
            }
            else
            {
                clusterCount = KMeans(image, opaque, k, options.Seed, labels);
            }

            var counts = new int[clusterCount];
            var sumR = new long[clusterCount]; var sumG = new long[clusterCount]; var sumB = new long[clusterCount];
            foreach (var i in opaque)
            {
                int c = labels[i];
                counts[c]++;
                sumR[c] += px[i * 4]; sumG[c] += px[i * 4 + 1]; sumB[c] += px[i * 4 + 2];
            }

            var target = Enumerable.Range(0, clusterCount).ToArray();
            var alive = counts.Select(c => c > 0).ToArray();
            Func<int, LabColor> center = c =>
            {
                double cnt = counts[c];
                return ColorMath.Lab(new RGB(Num.ClampByte(sumR[c] / cnt), Num.ClampByte(sumG[c] / cnt), Num.ClampByte(sumB[c] / cnt)));
            };
            if (options.MergeDistance > 0 && clusterCount > 1)
            {
                var centers = Enumerable.Range(0, clusterCount).Select(c => alive[c] ? center(c) : new LabColor(0, 0, 0)).ToArray();
                while (true)
                {
                    double best = double.PositiveInfinity; int bi = -1, bj = -1;
                    for (int i = 0; i < clusterCount; i++)
                    {
                        if (!alive[i]) continue;
                        for (int j = i + 1; j < clusterCount; j++)
                        {
                            if (!alive[j]) continue;
                            double d = ColorMath.DeltaE(centers[i], centers[j]);
                            if (d < best) { best = d; bi = i; bj = j; }
                        }
                    }
                    if (bi < 0 || !(best < options.MergeDistance)) break;
                    counts[bi] += counts[bj]; sumR[bi] += sumR[bj]; sumG[bi] += sumG[bj]; sumB[bi] += sumB[bj];
                    counts[bj] = 0;
                    alive[bj] = false;
                    for (int c = 0; c < clusterCount; c++) if (target[c] == bj) target[c] = bi;
                    centers[bi] = center(bi);
                }
            }

            var newIndex = new int[clusterCount];
            for (int i = 0; i < clusterCount; i++) newIndex[i] = -1;
            var palette = new List<RGB>();
            var finalCounts = new List<int>();
            for (int c = 0; c < clusterCount; c++)
            {
                if (!alive[c] || counts[c] <= 0) continue;
                newIndex[c] = palette.Count;
                long cnt = counts[c];
                palette.Add(new RGB((byte)((sumR[c] + cnt / 2) / cnt), (byte)((sumG[c] + cnt / 2) / cnt), (byte)((sumB[c] + cnt / 2) / cnt)));
                finalCounts.Add(counts[c]);
            }
            var remap = Enumerable.Range(0, clusterCount).Select(c => newIndex[target[c]]).ToArray();
            foreach (var i in opaque) labels[i] = remap[labels[i]];
            return new QuantizedImage(w, h, labels, palette.ToArray(), finalCounts.ToArray());
        }

        /// <summary>Distinct colors of the opaque pixels, in order of first appearance, if there are at most limit of them.</summary>
        static bool ExactColors(RGBAImage image, int[] opaque, int limit, out int[] outLabels, out int count)
        {
            var map = new Dictionary<uint, int>(limit * 2);
            outLabels = new int[opaque.Length];
            count = 0;
            uint lastKey = uint.MaxValue; int lastLabel = 0;
            var px = image.Data;
            for (int j = 0; j < opaque.Length; j++)
            {
                int i = opaque[j] * 4;
                uint key = (uint)px[i] << 16 | (uint)px[i + 1] << 8 | px[i + 2];
                if (key != lastKey)
                {
                    int l;
                    if (map.TryGetValue(key, out l)) lastLabel = l;
                    else
                    {
                        if (map.Count >= limit) return false;
                        lastLabel = map.Count;
                        map[key] = lastLabel;
                    }
                    lastKey = key;
                }
                outLabels[j] = lastLabel;
            }
            count = map.Count;
            return true;
        }

        /// <summary>k-means in Lab. Writes a cluster id for every opaque pixel; returns the number of clusters.</summary>
        static int KMeans(RGBAImage image, int[] opaque, int k, ulong seed, int[] labels)
        {
            int m = opaque.Length;
            var Ls = new float[m]; var As = new float[m]; var Bs = new float[m];
            var px = image.Data;
            {
                uint lastKey = uint.MaxValue; float l = 0, a = 0, b = 0;
                for (int j = 0; j < m; j++)
                {
                    int i = opaque[j] * 4;
                    uint key = (uint)px[i] << 16 | (uint)px[i + 1] << 8 | px[i + 2];
                    if (key != lastKey)
                    {
                        double L, A, B;
                        ColorMath.Lab(px[i], px[i + 1], px[i + 2], out L, out A, out B);
                        l = (float)L; a = (float)A; b = (float)B;
                        lastKey = key;
                    }
                    Ls[j] = l; As[j] = a; Bs[j] = b;
                }
            }

            var rng = new SplitMix64(seed);
            int[] sample;
            if (m <= MaxSamplePixels) sample = Enumerable.Range(0, m).ToArray();
            else
            {
                double step = (double)m / MaxSamplePixels;
                double phase = rng.NextUnit() * step;
                sample = new int[MaxSamplePixels];
                for (int s = 0; s < MaxSamplePixels; s++) sample[s] = Math.Min(m - 1, (int)(phase + s * step));
            }
            int sn = sample.Length;
            var sL = new float[sn]; var sA = new float[sn]; var sB = new float[sn];
            for (int t = 0; t < sn; t++) { sL[t] = Ls[sample[t]]; sA[t] = As[sample[t]]; sB[t] = Bs[sample[t]]; }

            var cL = new List<float>(); var cA = new List<float>(); var cB = new List<float>();
            int first = (int)(rng.Next() % (ulong)sn);
            cL.Add(sL[first]); cA.Add(sA[first]); cB.Add(sB[first]);
            var d2 = new float[sn];
            for (int t = 0; t < sn; t++)
            {
                float dl = sL[t] - cL[0], da = sA[t] - cA[0], db = sB[t] - cB[0];
                d2[t] = dl * dl + da * da + db * db;
            }
            while (cL.Count < k)
            {
                double total = 0;
                for (int t = 0; t < sn; t++) total += d2[t];
                if (total <= 0) break;
                double r = rng.NextUnit() * total;
                double acc = 0;
                int pick = sn - 1;
                for (int t = 0; t < sn; t++)
                {
                    acc += d2[t];
                    if (acc > r && d2[t] > 0) { pick = t; break; }
                }
                if (d2[pick] <= 0)
                {
                    float bestD = -1;
                    for (int t = 0; t < sn; t++) if (d2[t] > bestD) { bestD = d2[t]; pick = t; }
                }
                float nl = sL[pick], na = sA[pick], nb = sB[pick];
                cL.Add(nl); cA.Add(na); cB.Add(nb);
                for (int t = 0; t < sn; t++)
                {
                    float dl = sL[t] - nl, da = sA[t] - na, db = sB[t] - nb;
                    float d = dl * dl + da * da + db * db;
                    if (d < d2[t]) d2[t] = d;
                }
            }
            int kk = cL.Count;
            var cl = cL.ToArray(); var ca = cA.ToArray(); var cb = cB.ToArray();

            var accL = new double[kk]; var accA = new double[kk]; var accB = new double[kk]; var accN = new int[kk];
            for (int iter = 0; iter < MaxIterations; iter++)
            {
                Array.Clear(accL, 0, kk); Array.Clear(accA, 0, kk); Array.Clear(accB, 0, kk); Array.Clear(accN, 0, kk);
                for (int t = 0; t < sn; t++)
                {
                    float l = sL[t], a = sA[t], b = sB[t];
                    float best = float.PositiveInfinity; int bi = 0;
                    for (int c = 0; c < kk; c++)
                    {
                        float dl = l - cl[c], da = a - ca[c], db = b - cb[c];
                        float d = dl * dl + da * da + db * db;
                        if (d < best) { best = d; bi = c; }
                    }
                    accL[bi] += l; accA[bi] += a; accB[bi] += b; accN[bi]++;
                }
                float maxMove = 0;
                for (int c = 0; c < kk; c++)
                {
                    if (accN[c] == 0) continue;
                    double inv = 1.0 / accN[c];
                    float nl = (float)(accL[c] * inv), na = (float)(accA[c] * inv), nb = (float)(accB[c] * inv);
                    float dl = nl - cl[c], da = na - ca[c], db = nb - cb[c];
                    maxMove = Math.Max(maxMove, (float)Math.Sqrt(dl * dl + da * da + db * db));
                    cl[c] = nl; ca[c] = na; cb[c] = nb;
                }
                if (maxMove < ConvergenceDelta) break;
            }

            {
                float lastL = float.NaN, lastA = float.NaN, lastB = float.NaN; int lastC = 0;
                for (int j = 0; j < m; j++)
                {
                    float l = Ls[j], a = As[j], b = Bs[j];
                    if (l == lastL && a == lastA && b == lastB) { labels[opaque[j]] = lastC; continue; }
                    float best = float.PositiveInfinity; int bi = 0;
                    for (int c = 0; c < kk; c++)
                    {
                        float dl = l - cl[c], da = a - ca[c], db = b - cb[c];
                        float d = dl * dl + da * da + db * db;
                        if (d < best) { best = d; bi = c; }
                    }
                    lastL = l; lastA = a; lastB = b; lastC = bi;
                    labels[opaque[j]] = bi;
                }
            }
            return kk;
        }

        /// <summary>A copy where every label in indices becomes -1 (and its count 0).</summary>
        public static QuantizedImage Removing(ICollection<int> indices, QuantizedImage q)
        {
            if (indices.Count == 0) return q;
            int pc = q.Palette.Length;
            var drop = new bool[pc];
            foreach (var i in indices) if (i >= 0 && i < pc) drop[i] = true;
            var labels = (int[])q.Labels.Clone();
            for (int i = 0; i < labels.Length; i++)
            {
                int l = labels[i];
                if (l >= 0 && l < pc && drop[l]) labels[i] = -1;
            }
            var counts = (int[])q.Counts.Clone();
            for (int i = 0; i < counts.Length; i++) if (i < pc && drop[i]) counts[i] = 0;
            return new QuantizedImage(q.Width, q.Height, labels, q.Palette, counts);
        }

        /// <summary>Renders labels to an RGBA preview (palette colors, transparent where label == -1).</summary>
        public static RGBAImage PreviewImage(QuantizedImage q)
        {
            int n = q.Width * q.Height;
            var data = new byte[n * 4];
            int pc = q.Palette.Length;
            for (int i = 0; i < Math.Min(n, q.Labels.Length); i++)
            {
                int l = q.Labels[i];
                if (l < 0 || l >= pc) continue;
                var c = q.Palette[l];
                data[i * 4] = c.R; data[i * 4 + 1] = c.G; data[i * 4 + 2] = c.B; data[i * 4 + 3] = 255;
            }
            return new RGBAImage(q.Width, q.Height, data);
        }

        /// <summary>Moves every color of q to its closest color in palette (by CIE ΔE), merging colors that land on the same one.</summary>
        public static QuantizedImage Snap(QuantizedImage q, IList<RGB> palette)
        {
            if (palette.Count == 0 || q.Palette.Length == 0) return q;
            var labs = palette.Select(ColorMath.Lab).ToArray();
            var newIndexForSwatch = new Dictionary<int, int>();
            var newPalette = new List<RGB>();
            var map = new int[q.Palette.Length];
            for (int i = 0; i < q.Palette.Length; i++)
            {
                var l = ColorMath.Lab(q.Palette[i]);
                int bestJ = 0; double bestD = double.PositiveInfinity;
                for (int j = 0; j < labs.Length; j++)
                {
                    double d = ColorMath.DeltaE(l, labs[j]);
                    if (d < bestD) { bestD = d; bestJ = j; }
                }
                if (!newIndexForSwatch.ContainsKey(bestJ)) { newIndexForSwatch[bestJ] = newPalette.Count; newPalette.Add(palette[bestJ]); }
                map[i] = newIndexForSwatch[bestJ];
            }
            var labels = q.Labels.Select(x => x < 0 ? -1 : map[x]).ToArray();
            var counts = new int[newPalette.Count];
            for (int i = 0; i < q.Counts.Length; i++) if (map[i] >= 0) counts[map[i]] += q.Counts[i];
            return new QuantizedImage(q.Width, q.Height, labels, newPalette.ToArray(), counts);
        }
    }
}
