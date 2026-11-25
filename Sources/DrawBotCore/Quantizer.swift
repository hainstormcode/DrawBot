import Foundation

/// Small, fast, deterministic RNG (SplitMix64).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform double in [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

public enum Quantizer {
    /// Maximum number of pixels used to fit the k-means centers.
    public static let maxSamplePixels = 60_000
    static let maxIterations = 25
    static let convergenceDelta: Float = 0.1

    /// Reduces `image` to at most `options.maxColors` colors (k-means in CIELAB, k-means++
    /// seeding with a deterministic RNG from `options.seed`, near-duplicate clusters merged per
    /// `options.mergeDistance`). Pixels with alpha < `options.alphaThreshold` get label -1.
    /// Palette entries are mean sRGB colors of their members; empty clusters are removed and
    /// labels re-indexed so palette indices are 0..<palette.count and every count > 0.
    /// An image with no opaque pixels yields an empty palette and all labels -1.
    ///
    /// If the opaque pixels contain at most `maxColors` distinct colors they are used exactly
    /// (no k-means), in order of first appearance (before merging).
    public static func quantize(_ image: RGBAImage, options: QuantizeOptions) -> QuantizedImage {
        let w = image.width, h = image.height
        let n = w * h
        let k = min(64, max(1, options.maxColors))
        let threshold = options.alphaThreshold
        var labels = [Int32](repeating: -1, count: n)
        guard n > 0 else {
            return QuantizedImage(width: w, height: h, labels: labels, palette: [], counts: [])
        }

        // 1. Opaque pixel indices + packed colors.
        var opaque: [Int32] = []
        opaque.reserveCapacity(n)
        image.data.withUnsafeBufferPointer { px in
            for i in 0..<n where px[i * 4 + 3] >= threshold {
                opaque.append(Int32(i))
            }
        }
        let m = opaque.count
        guard m > 0 else {
            return QuantizedImage(width: w, height: h, labels: labels, palette: [], counts: [])
        }

        // 2. Initial clustering → per-pixel cluster ids (in `labels`) and cluster count.
        var clusterCount = 0
        if let exact = exactColors(image, opaque: opaque, limit: k) {
            // Exact path: each distinct color is its own cluster.
            clusterCount = exact.colorCount
            for (j, p) in opaque.enumerated() { labels[Int(p)] = exact.labels[j] }
        } else {
            clusterCount = kMeans(image, opaque: opaque, k: k, seed: options.seed, labels: &labels)
        }

        // 3. Per-cluster stats: counts, sRGB sums, Lab sums.
        var counts = [Int](repeating: 0, count: clusterCount)
        var sumR = [Int](repeating: 0, count: clusterCount)
        var sumG = [Int](repeating: 0, count: clusterCount)
        var sumB = [Int](repeating: 0, count: clusterCount)
        image.data.withUnsafeBufferPointer { px in
            for p in opaque {
                let i = Int(p)
                let c = Int(labels[i])
                counts[c] += 1
                sumR[c] += Int(px[i * 4])
                sumG[c] += Int(px[i * 4 + 1])
                sumB[c] += Int(px[i * 4 + 2])
            }
        }

        // 4. Merge clusters whose (mean-color) Lab centers are closer than mergeDistance.
        //    Repeatedly merge the closest pair; stats are count-weighted sums.
        var target = Array(0..<clusterCount)  // cluster → surviving cluster
        var alive = counts.map { $0 > 0 }
        func center(_ c: Int) -> LabColor {
            let cnt = Double(counts[c])
            return ColorMath.lab(RGB(r: UInt8((Double(sumR[c]) / cnt).rounded()),
                                     g: UInt8((Double(sumG[c]) / cnt).rounded()),
                                     b: UInt8((Double(sumB[c]) / cnt).rounded())))
        }
        if options.mergeDistance > 0 && clusterCount > 1 {
            var centers = (0..<clusterCount).map { alive[$0] ? center($0) : LabColor(L: 0, a: 0, b: 0) }
            while true {
                var best = Double.infinity, bi = -1, bj = -1
                for i in 0..<clusterCount where alive[i] {
                    for j in (i + 1)..<clusterCount where alive[j] {
                        let d = ColorMath.deltaE(centers[i], centers[j])
                        if d < best { best = d; bi = i; bj = j }
                    }
                }
                guard bi >= 0, best < options.mergeDistance else { break }
                counts[bi] += counts[bj]; sumR[bi] += sumR[bj]; sumG[bi] += sumG[bj]; sumB[bi] += sumB[bj]
                counts[bj] = 0
                alive[bj] = false
                for c in 0..<clusterCount where target[c] == bj { target[c] = bi }
                centers[bi] = center(bi)
            }
        }

        // 5. Re-index surviving, non-empty clusters (stable order).
        var newIndex = [Int32](repeating: -1, count: clusterCount)
        var palette: [RGB] = []
        var finalCounts: [Int] = []
        for c in 0..<clusterCount where alive[c] && counts[c] > 0 {
            newIndex[c] = Int32(palette.count)
            let cnt = counts[c]
            palette.append(RGB(r: UInt8((sumR[c] + cnt / 2) / cnt),
                               g: UInt8((sumG[c] + cnt / 2) / cnt),
                               b: UInt8((sumB[c] + cnt / 2) / cnt)))
            finalCounts.append(cnt)
        }
        let remap = (0..<clusterCount).map { newIndex[target[$0]] }
        labels.withUnsafeMutableBufferPointer { lb in
            for p in opaque {
                let i = Int(p)
                lb[i] = remap[Int(lb[i])]
            }
        }
        return QuantizedImage(width: w, height: h, labels: labels, palette: palette, counts: finalCounts)
    }

    /// Distinct colors of the opaque pixels if there are at most `limit` of them.
    private static func exactColors(_ image: RGBAImage, opaque: [Int32], limit: Int)
        -> (labels: [Int32], colorCount: Int)? {
        var map: [UInt32: Int32] = [:]
        map.reserveCapacity(limit * 2)
        var out = [Int32](repeating: 0, count: opaque.count)
        var lastKey: UInt32 = .max
        var lastLabel: Int32 = 0
        let ok: Bool = image.data.withUnsafeBufferPointer { px in
            for (j, p) in opaque.enumerated() {
                let i = Int(p) * 4
                let key = UInt32(px[i]) << 16 | UInt32(px[i + 1]) << 8 | UInt32(px[i + 2])
                if key != lastKey {
                    if let l = map[key] {
                        lastLabel = l
                    } else {
                        if map.count >= limit { return false }
                        lastLabel = Int32(map.count)
                        map[key] = lastLabel
                    }
                    lastKey = key
                }
                out[j] = lastLabel
            }
            return true
        }
        return ok ? (out, map.count) : nil
    }

    /// k-means in Lab. Writes a cluster id (0..<returned count) into `labels` for every opaque
    /// pixel and returns the number of clusters (centers) used.
    private static func kMeans(_ image: RGBAImage, opaque: [Int32], k: Int, seed: UInt64,
                               labels: inout [Int32]) -> Int {
        let m = opaque.count
        // Lab of every opaque pixel, structure-of-arrays, Float. A tiny cache skips repeats.
        var Ls = [Float](repeating: 0, count: m)
        var As = [Float](repeating: 0, count: m)
        var Bs = [Float](repeating: 0, count: m)
        image.data.withUnsafeBufferPointer { px in
            var lastKey: UInt32 = .max
            var l: Float = 0, a: Float = 0, b: Float = 0
            for j in 0..<m {
                let i = Int(opaque[j]) * 4
                let key = UInt32(px[i]) << 16 | UInt32(px[i + 1]) << 8 | UInt32(px[i + 2])
                if key != lastKey {
                    let v = ColorMath.lab(r: px[i], g: px[i + 1], b: px[i + 2])
                    l = Float(v.L); a = Float(v.a); b = Float(v.b)
                    lastKey = key
                }
                Ls[j] = l; As[j] = a; Bs[j] = b
            }
        }

        // Deterministic sample (stride with seeded phase).
        var rng = SplitMix64(seed: seed)
        var sample: [Int] = []
        if m <= maxSamplePixels {
            sample = Array(0..<m)
        } else {
            let step = Double(m) / Double(maxSamplePixels)
            let phase = rng.nextUnit() * step
            sample.reserveCapacity(maxSamplePixels)
            for s in 0..<maxSamplePixels {
                sample.append(min(m - 1, Int(phase + Double(s) * step)))
            }
        }
        let sn = sample.count
        var sL = [Float](repeating: 0, count: sn), sA = sL, sB = sL
        for (t, j) in sample.enumerated() { sL[t] = Ls[j]; sA[t] = As[j]; sB[t] = Bs[j] }

        // k-means++ seeding.
        var cL: [Float] = [], cA: [Float] = [], cB: [Float] = []
        let first = Int(rng.next() % UInt64(sn))
        cL.append(sL[first]); cA.append(sA[first]); cB.append(sB[first])
        var d2 = [Float](repeating: 0, count: sn)
        for t in 0..<sn {
            let dl = sL[t] - cL[0], da = sA[t] - cA[0], db = sB[t] - cB[0]
            d2[t] = dl * dl + da * da + db * db
        }
        while cL.count < k {
            var total = 0.0
            for t in 0..<sn { total += Double(d2[t]) }
            if total <= 0 { break }  // fewer distinct colors than k in the sample
            let r = rng.nextUnit() * total
            var acc = 0.0
            var pick = sn - 1
            for t in 0..<sn {
                acc += Double(d2[t])
                if acc > r && d2[t] > 0 { pick = t; break }
            }
            if d2[pick] <= 0 {
                // Numerical edge: take the farthest point instead.
                var bestD: Float = -1
                for t in 0..<sn where d2[t] > bestD { bestD = d2[t]; pick = t }
            }
            let nl = sL[pick], na = sA[pick], nb = sB[pick]
            cL.append(nl); cA.append(na); cB.append(nb)
            for t in 0..<sn {
                let dl = sL[t] - nl, da = sA[t] - na, db = sB[t] - nb
                let d = dl * dl + da * da + db * db
                if d < d2[t] { d2[t] = d }
            }
        }
        let kk = cL.count

        // Lloyd iterations on the sample.
        var assign = [Int32](repeating: 0, count: sn)
        var accL = [Double](repeating: 0, count: kk), accA = accL, accB = accL
        var accN = [Int](repeating: 0, count: kk)
        for _ in 0..<maxIterations {
            for c in 0..<kk { accL[c] = 0; accA[c] = 0; accB[c] = 0; accN[c] = 0 }
            cL.withUnsafeBufferPointer { cl in
            cA.withUnsafeBufferPointer { ca in
            cB.withUnsafeBufferPointer { cb in
                for t in 0..<sn {
                    let l = sL[t], a = sA[t], b = sB[t]
                    var best: Float = .infinity
                    var bi = 0
                    for c in 0..<kk {
                        let dl = l - cl[c], da = a - ca[c], db = b - cb[c]
                        let d = dl * dl + da * da + db * db
                        if d < best { best = d; bi = c }
                    }
                    assign[t] = Int32(bi)
                    accL[bi] += Double(l); accA[bi] += Double(a); accB[bi] += Double(b); accN[bi] += 1
                }
            }}}
            var maxMove: Float = 0
            for c in 0..<kk where accN[c] > 0 {
                let inv = 1.0 / Double(accN[c])
                let nl = Float(accL[c] * inv), na = Float(accA[c] * inv), nb = Float(accB[c] * inv)
                let dl = nl - cL[c], da = na - cA[c], db = nb - cB[c]
                maxMove = max(maxMove, (dl * dl + da * da + db * db).squareRoot())
                cL[c] = nl; cA[c] = na; cB[c] = nb
            }
            if maxMove < convergenceDelta { break }
        }

        // Assign ALL opaque pixels to the nearest center.
        cL.withUnsafeBufferPointer { cl in
        cA.withUnsafeBufferPointer { ca in
        cB.withUnsafeBufferPointer { cb in
        labels.withUnsafeMutableBufferPointer { lb in
            var lastL: Float = .nan, lastA: Float = .nan, lastB: Float = .nan
            var lastC: Int32 = 0
            for j in 0..<m {
                let l = Ls[j], a = As[j], b = Bs[j]
                if l == lastL && a == lastA && b == lastB {
                    lb[Int(opaque[j])] = lastC
                    continue
                }
                var best: Float = .infinity
                var bi = 0
                for c in 0..<kk {
                    let dl = l - cl[c], da = a - ca[c], db = b - cb[c]
                    let d = dl * dl + da * da + db * db
                    if d < best { best = d; bi = c }
                }
                lastL = l; lastA = a; lastB = b; lastC = Int32(bi)
                lb[Int(opaque[j])] = lastC
            }
        }}}}
        return kk
    }

    /// Returns a copy of `q` where every label in `indices` becomes -1 (used for "skip this color"
    /// previews). Palette and counts are left unchanged except counts of removed indices become 0.
    public static func removing(_ indices: Set<Int>, from q: QuantizedImage) -> QuantizedImage {
        guard !indices.isEmpty else { return q }
        let pc = q.palette.count
        var drop = [Bool](repeating: false, count: pc)
        for i in indices where i >= 0 && i < pc { drop[i] = true }
        var labels = q.labels
        for i in 0..<labels.count {
            let l = Int(labels[i])
            if l >= 0 && l < pc && drop[l] { labels[i] = -1 }
        }
        var counts = q.counts
        for i in 0..<counts.count where i < pc && drop[i] { counts[i] = 0 }
        return QuantizedImage(width: q.width, height: q.height, labels: labels, palette: q.palette, counts: counts)
    }

    /// Renders labels to an RGBA preview (palette colors, transparent where label == -1).
    public static func previewImage(_ q: QuantizedImage) -> RGBAImage {
        let n = q.width * q.height
        var data = [UInt8](repeating: 0, count: n * 4)
        let pc = q.palette.count
        for i in 0..<min(n, q.labels.count) {
            let l = Int(q.labels[i])
            guard l >= 0 && l < pc else { continue }
            let c = q.palette[l]
            data[i * 4] = c.r
            data[i * 4 + 1] = c.g
            data[i * 4 + 2] = c.b
            data[i * 4 + 3] = 255
        }
        return RGBAImage(width: q.width, height: q.height, data: data)
    }
}
