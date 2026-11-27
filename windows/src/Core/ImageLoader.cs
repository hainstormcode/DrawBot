using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace DrawBot.Core
{
    public sealed class ImageLoaderException : Exception
    {
        public ImageLoaderException(string message) : base(message) { }
    }

    public static class ImageLoader
    {
        /// <summary>Images with more pixels than this are reduced (keeping detail far beyond any grid) while decoding.</summary>
        public const long MaxDecodePixels = 40000000;

        /// <summary>
        /// Loads the first frame of a PNG, JPEG, BMP, GIF, TIFF or ICO file (and, through Windows
        /// Imaging Component codecs, WebP / HEIC when they are installed) with the EXIF orientation
        /// applied, as straight-alpha RGBA.
        /// </summary>
        public static RGBAImage Load(string path)
        {
            byte[] bytes;
            try { bytes = File.ReadAllBytes(path); }
            catch (Exception) { throw new ImageLoaderException("Could not open " + Path.GetFileName(path) + "."); }
            var img = Load(bytes);
            if (img == null) throw new ImageLoaderException(Path.GetFileName(path) + " is not a readable image.");
            return img;
        }

        /// <summary>Decodes in-memory image data (e.g. a pasted or dropped image). Null if unreadable.</summary>
        public static RGBAImage Load(byte[] data)
        {
            try
            {
                using (var ms = new MemoryStream(data))
                using (var image = Image.FromStream(ms, true, true))
                {
                    ApplyOrientation(image);
                    return FromImage(image);
                }
            }
            catch (Exception)
            {
                return WicDecode(data);
            }
        }

        /// <summary>Converts any GDI+ image to straight-alpha RGBA (reduced if enormous).</summary>
        public static RGBAImage FromImage(Image image)
        {
            int w = image.Width, h = image.Height;
            if (w <= 0 || h <= 0) return null;
            if ((long)w * h > MaxDecodePixels)
            {
                double k = Math.Sqrt((double)MaxDecodePixels / ((long)w * h));
                w = Math.Max(1, (int)(w * k)); h = Math.Max(1, (int)(h * k));
            }
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.Clear(Color.Transparent);
                    g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                    g.DrawImage(image, new Rectangle(0, 0, w, h));
                }
                return FromBitmap(bmp);
            }
        }

        /// <summary>Reads a 32bpp ARGB bitmap (BGRA in memory) into RGBA.</summary>
        public static RGBAImage FromBitmap(Bitmap bmp)
        {
            int w = bmp.Width, h = bmp.Height;
            var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                var row = new byte[w * 4];
                var outp = new byte[w * h * 4];
                for (int y = 0; y < h; y++)
                {
                    Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, w * 4);
                    int o = y * w * 4;
                    for (int x = 0; x < w; x++)
                    {
                        int i = x * 4;
                        outp[o + i] = row[i + 2];
                        outp[o + i + 1] = row[i + 1];
                        outp[o + i + 2] = row[i];
                        outp[o + i + 3] = row[i + 3];
                    }
                }
                return new RGBAImage(w, h, outp);
            }
            finally { bmp.UnlockBits(data); }
        }

        /// <summary>RGBA → a 32bpp ARGB bitmap (for previews and the UI).</summary>
        public static Bitmap ToBitmap(RGBAImage img)
        {
            var bmp = new Bitmap(Math.Max(1, img.Width), Math.Max(1, img.Height), PixelFormat.Format32bppArgb);
            if (img.Width == 0 || img.Height == 0) return bmp;
            var data = bmp.LockBits(new Rectangle(0, 0, img.Width, img.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            try
            {
                var row = new byte[img.Width * 4];
                for (int y = 0; y < img.Height; y++)
                {
                    int o = y * img.Width * 4;
                    for (int x = 0; x < img.Width; x++)
                    {
                        int i = x * 4;
                        row[i] = img.Data[o + i + 2];
                        row[i + 1] = img.Data[o + i + 1];
                        row[i + 2] = img.Data[o + i];
                        row[i + 3] = img.Data[o + i + 3];
                    }
                    Marshal.Copy(row, 0, data.Scan0 + y * data.Stride, row.Length);
                }
            }
            finally { bmp.UnlockBits(data); }
            return bmp;
        }

        static void ApplyOrientation(Image image)
        {
            const int orientationId = 0x0112;
            try
            {
                if (Array.IndexOf(image.PropertyIdList, orientationId) < 0) return;
                var prop = image.GetPropertyItem(orientationId);
                int o = prop.Value[0];
                RotateFlipType t;
                switch (o)
                {
                    case 2: t = RotateFlipType.RotateNoneFlipX; break;
                    case 3: t = RotateFlipType.Rotate180FlipNone; break;
                    case 4: t = RotateFlipType.Rotate180FlipX; break;
                    case 5: t = RotateFlipType.Rotate90FlipX; break;
                    case 6: t = RotateFlipType.Rotate90FlipNone; break;
                    case 7: t = RotateFlipType.Rotate270FlipX; break;
                    case 8: t = RotateFlipType.Rotate270FlipNone; break;
                    default: return;
                }
                image.RotateFlip(t);
            }
            catch (Exception) { }
        }

        /// <summary>Windows Imaging Component (WPF) fallback for formats GDI+ can't read (WebP, HEIC…).</summary>
        static RGBAImage WicDecode(byte[] data)
        {
            try
            {
                using (var ms = new MemoryStream(data))
                {
                    var decoder = System.Windows.Media.Imaging.BitmapDecoder.Create(ms,
                        System.Windows.Media.Imaging.BitmapCreateOptions.PreservePixelFormat,
                        System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
                    if (decoder.Frames.Count == 0) return null;
                    System.Windows.Media.Imaging.BitmapSource frame = decoder.Frames[0];
                    var conv = new System.Windows.Media.Imaging.FormatConvertedBitmap(frame, System.Windows.Media.PixelFormats.Bgra32, null, 0);
                    int w = conv.PixelWidth, h = conv.PixelHeight;
                    if (w <= 0 || h <= 0) return null;
                    var px = new byte[w * h * 4];
                    conv.CopyPixels(px, w * 4, 0);
                    for (int i = 0; i < px.Length; i += 4) { var t = px[i]; px[i] = px[i + 2]; px[i + 2] = t; }
                    return new RGBAImage(w, h, px);
                }
            }
            catch (Exception) { return null; }
        }

        // MARK: Rasterizing

        /// <summary>
        /// Scales image to fit inside width×height (aspect preserved, centered). Area not covered
        /// by the image has alpha 0. Output alpha is straight. Downscales by more than 2× use an
        /// exact area-average (box) filter; upscales of images with few colors (pixel art, logos)
        /// use nearest-neighbor; everything else is bilinear.
        /// </summary>
        public static RGBAImage Rasterize(RGBAImage image, int width, int height)
        {
            int w = Math.Max(1, width), h = Math.Max(1, height);
            int iw = image.Width, ih = image.Height;
            if (iw <= 0 || ih <= 0) return new RGBAImage(w, h);
            double scale = Math.Min((double)w / iw, (double)h / ih);
            int dw = Math.Min(w, Math.Max(1, (int)Num.Round(iw * scale)));
            int dh = Math.Min(h, Math.Max(1, (int)Num.Round(ih * scale)));
            int ox = (w - dw) / 2, oy = (h - dh) / 2;

            float[] src = Premultiplied(image);
            float[] fitted;
            double sx = (double)iw / dw, sy = (double)ih / dh;
            if (sx > 2 || sy > 2)
                fitted = BoxDownsample(src, iw, ih, dw, dh);
            else if (scale > 1 && HasFewColors(image.Data, 64))
                fitted = Nearest(src, iw, ih, dw, dh);
            else
                fitted = Bilinear(src, iw, ih, dw, dh);

            var outp = new byte[w * h * 4];
            for (int y = 0; y < dh; y++)
            {
                for (int x = 0; x < dw; x++)
                {
                    int si = (y * dw + x) * 4, di = ((y + oy) * w + (x + ox)) * 4;
                    float a = fitted[si + 3];
                    if (a <= 0.5f) continue;
                    float k = 255 / a;
                    outp[di] = Num.ClampByte(fitted[si] * k);
                    outp[di + 1] = Num.ClampByte(fitted[si + 1] * k);
                    outp[di + 2] = Num.ClampByte(fitted[si + 2] * k);
                    outp[di + 3] = Num.ClampByte(a);
                }
            }
            return new RGBAImage(w, h, outp);
        }

        static float[] Premultiplied(RGBAImage img)
        {
            var d = img.Data;
            var f = new float[d.Length];
            for (int i = 0; i < d.Length; i += 4)
            {
                float a = d[i + 3];
                float k = a / 255f;
                f[i] = d[i] * k; f[i + 1] = d[i + 1] * k; f[i + 2] = d[i + 2] * k; f[i + 3] = a;
            }
            return f;
        }

        public static bool HasFewColors(byte[] rgba, int limit)
        {
            var seen = new HashSet<uint>();
            uint last = uint.MaxValue;
            for (int i = 0; i < rgba.Length; i += 4)
            {
                uint key = (uint)rgba[i] << 24 | (uint)rgba[i + 1] << 16 | (uint)rgba[i + 2] << 8 | rgba[i + 3];
                if (key != last)
                {
                    seen.Add(key);
                    if (seen.Count > limit) return false;
                    last = key;
                }
            }
            return true;
        }

        static float[] Nearest(float[] src, int sw, int sh, int dw, int dh)
        {
            var o = new float[dw * dh * 4];
            for (int y = 0; y < dh; y++)
            {
                int syy = Math.Min(sh - 1, (int)((y + 0.5) * sh / dh));
                for (int x = 0; x < dw; x++)
                {
                    int sxx = Math.Min(sw - 1, (int)((x + 0.5) * sw / dw));
                    Array.Copy(src, (syy * sw + sxx) * 4, o, (y * dw + x) * 4, 4);
                }
            }
            return o;
        }

        static float[] Bilinear(float[] src, int sw, int sh, int dw, int dh)
        {
            var o = new float[dw * dh * 4];
            for (int y = 0; y < dh; y++)
            {
                double fy = (y + 0.5) * sh / dh - 0.5;
                int y0 = (int)Math.Floor(fy); double ty = fy - y0;
                int ya = Math.Min(sh - 1, Math.Max(0, y0)), yb = Math.Min(sh - 1, Math.Max(0, y0 + 1));
                for (int x = 0; x < dw; x++)
                {
                    double fx = (x + 0.5) * sw / dw - 0.5;
                    int x0 = (int)Math.Floor(fx); double tx = fx - x0;
                    int xa = Math.Min(sw - 1, Math.Max(0, x0)), xb = Math.Min(sw - 1, Math.Max(0, x0 + 1));
                    int i00 = (ya * sw + xa) * 4, i01 = (ya * sw + xb) * 4, i10 = (yb * sw + xa) * 4, i11 = (yb * sw + xb) * 4;
                    int di = (y * dw + x) * 4;
                    for (int c = 0; c < 4; c++)
                    {
                        double top = src[i00 + c] * (1 - tx) + src[i01 + c] * tx;
                        double bot = src[i10 + c] * (1 - tx) + src[i11 + c] * tx;
                        o[di + c] = (float)(top * (1 - ty) + bot * ty);
                    }
                }
            }
            return o;
        }

        /// <summary>Exact area-average resample of a premultiplied RGBA buffer (separable, fractional weights).</summary>
        public static float[] BoxDownsample(float[] src, int srcW, int srcH, int dstW, int dstH)
        {
            var wx = Weights(srcW, dstW);
            var wy = Weights(srcH, dstH);
            var tmp = new float[srcH * dstW * 4];
            for (int y = 0; y < srcH; y++)
            {
                int sRow = y * srcW * 4, tRow = y * dstW * 4;
                for (int x = 0; x < dstW; x++)
                {
                    int first = wx[x].Key; var ws = wx[x].Value;
                    float r = 0, g = 0, b = 0, a = 0;
                    for (int k = 0; k < ws.Length; k++)
                    {
                        int si = sRow + (first + k) * 4; float wt = ws[k];
                        r += src[si] * wt; g += src[si + 1] * wt; b += src[si + 2] * wt; a += src[si + 3] * wt;
                    }
                    int ti = tRow + x * 4;
                    tmp[ti] = r; tmp[ti + 1] = g; tmp[ti + 2] = b; tmp[ti + 3] = a;
                }
            }
            var outp = new float[dstH * dstW * 4];
            for (int y = 0; y < dstH; y++)
            {
                int first = wy[y].Key; var ws = wy[y].Value;
                int oRow = y * dstW * 4;
                for (int k = 0; k < ws.Length; k++)
                {
                    int tRow = (first + k) * dstW * 4; float wt = ws[k];
                    for (int i = 0; i < dstW * 4; i++) outp[oRow + i] += tmp[tRow + i] * wt;
                }
            }
            return outp;
        }

        static KeyValuePair<int, float[]>[] Weights(int src, int dst)
        {
            double ratio = (double)src / dst;
            var result = new KeyValuePair<int, float[]>[dst];
            for (int d = 0; d < dst; d++)
            {
                double a = d * ratio, b = (d + 1) * ratio;
                int first = (int)Math.Floor(a);
                int last = Math.Min(src - 1, (int)Math.Ceiling(b) - 1);
                var ws = new List<float>();
                for (int s = first; s <= last; s++)
                {
                    double cover = Math.Min(b, s + 1) - Math.Max(a, s);
                    ws.Add((float)(Math.Max(0, cover) / ratio));
                }
                result[d] = new KeyValuePair<int, float[]>(first, ws.ToArray());
            }
            return result;
        }
    }
}
