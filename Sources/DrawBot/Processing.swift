import CoreGraphics
import DrawBotCore
import Foundation

/// Everything that determines a quantization result. Results are only used while their key
/// equals the controller's current key.
struct ProcessingKey: Equatable {
    var imageToken: Int
    var layout: GridLayout
    var options: QuantizeOptions
    /// True when there is no canvas yet: the layout is an aspect-ratio preview grid, and no
    /// strokes are planned.
    var isPreviewLayout: Bool
    /// Apps with only fixed swatches: the image's colors are moved to the nearest of these.
    var snapPalette: [RGB]? = nil
    var strokeStyle: StrokeStyle = .paths
}

struct ProcessedResult {
    let key: ProcessingKey
    let quantized: QuantizedImage
    let preview: CGImage?
    /// strokes[paletteIndex] (empty for preview layouts).
    let strokes: [[ScreenStroke]]
    /// estimates[preset][paletteIndex] in seconds (empty for preview layouts).
    let estimates: [SpeedPreset: [TimeInterval]]
}

/// Background quantization with coalescing: rapid requests (slider drags) collapse into one,
/// and results of superseded requests are dropped via a generation counter.
final class ImageProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.drawbot.processing", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var pending: DispatchWorkItem?

    private func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// Cancels any in-flight work (its completion will not be called).
    func cancel() {
        lock.lock()
        generation += 1
        pending?.cancel()
        pending = nil
        lock.unlock()
    }

    /// Schedules processing. `completion` runs on the main queue, only if this is still the
    /// latest request when it finishes.
    func process(image: CGImage, key: ProcessingKey, debounce: TimeInterval = 0.12,
                 completion: @escaping (ProcessedResult) -> Void) {
        lock.lock()
        generation += 1
        let gen = generation
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let result = self.compute(image: image, key: key, generation: gen) else { return }
            DispatchQueue.main.async {
                guard self.currentGeneration() == gen else { return }
                completion(result)
            }
        }
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func compute(image: CGImage, key: ProcessingKey, generation gen: Int) -> ProcessedResult? {
        func stale() -> Bool { currentGeneration() != gen }
        if stale() { return nil }
        let layout = key.layout
        let raster = ImageLoader.rasterize(image, width: layout.columns, height: layout.rows)
        if stale() { return nil }
        var q = Quantizer.quantize(raster, options: key.options)
        if let palette = key.snapPalette { q = Quantizer.snap(q, to: palette) }
        if stale() { return nil }
        let preview = ImageLoader.makeCGImage(Quantizer.previewImage(q))
        var strokes: [[ScreenStroke]] = []
        var estimates: [SpeedPreset: [TimeInterval]] = [:]
        if !key.isPreviewLayout {
            strokes.reserveCapacity(q.palette.count)
            for i in q.palette.indices {
                if stale() { return nil }
                strokes.append(StrokePlanner.strokes(for: i, in: q, layout: layout, style: key.strokeStyle))
            }
            for preset in SpeedPreset.allCases {
                estimates[preset] = strokes.map { TimeEstimator.estimate($0, speed: preset.settings) }
            }
        }
        if stale() { return nil }
        return ProcessedResult(key: key, quantized: q, preview: preview, strokes: strokes, estimates: estimates)
    }

    /// Preview with skipped colors removed, rendered off-main. Latest request wins.
    private let previewQueue = DispatchQueue(label: "local.drawbot.preview", qos: .userInitiated)
    private var previewGeneration = 0

    func renderPreview(_ q: QuantizedImage, removing skip: Set<Int>, completion: @escaping (CGImage?) -> Void) {
        lock.lock()
        previewGeneration += 1
        let gen = previewGeneration
        lock.unlock()
        previewQueue.async { [weak self] in
            guard let self else { return }
            let img = ImageLoader.makeCGImage(Quantizer.previewImage(skip.isEmpty ? q : Quantizer.removing(skip, from: q)))
            DispatchQueue.main.async {
                self.lock.lock()
                let current = self.previewGeneration == gen
                self.lock.unlock()
                if current { completion(img) }
            }
        }
    }

    /// Preview grid used before a canvas exists: the image's aspect ratio, ~240 cells on the long side.
    static func previewLayout(for image: CGImage) -> GridLayout {
        let w = Double(max(1, image.width)), h = Double(max(1, image.height))
        let long = 240.0
        let cols = w >= h ? long : max(1, (long * w / h).rounded())
        let rows = w >= h ? max(1, (long * h / w).rounded()) : long
        return GridLayout(canvas: CGRect(x: 0, y: 0, width: cols, height: rows), penSize: 1)
    }
}
