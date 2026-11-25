import CoreGraphics
import Foundation

/// Learns how to drive a color picker from demonstrations (see ColorLearn.swift).
///
/// 1. Each demo's events are segmented into actions: pointer gestures (click, multi-click, drag)
///    and runs of keystrokes. Presses inside the canvas are ignored (test strokes).
/// 2. The demos are aligned action by action (dynamic programming). Only actions present in
///    every demo are kept.
/// 3. Typing: typed / pasted text (pastes are replayed as typing) is split into numbers and hex codes; each is matched against
///    the color's hex, RGB, HSB and HSL values (several scales). An interpretation that fits
///    every demo becomes a slot filled in for new colors.
/// 4. Pointer: a gesture that lands on the same spot in every demo is a fixed click. One that
///    moves is a color control. Every way of explaining those controls with one color model
///    (HSB / HSL / RGB) is tried: sliders (1-D linear), areas (2-D linear), wheels and hue rings
///    (polar). Each is fitted by least squares and scored by fit, plausibility (sizes, on
///    screen), consistency (sliders as long as the square beside them…) and how common the
///    layout is. With two demos many explanations fit exactly, so the layout prior decides;
///    every additional demo (after a failed test) adds a point that the wrong explanations
///    cannot fit.
public enum ColorLearner {
    /// The two colors the user demonstrates first: far apart on any picker (opposite hues,
    /// different saturation and brightness, every RGB channel different).
    public static let demoColors: [RGB] = [
        ColorMath.rgb(hue: 30, saturation: 80, brightness: 90),
        ColorMath.rgb(hue: 210, saturation: 35, brightness: 45),
    ]

    /// Colors DrawBot tries by itself to check what it learned (and asks the user to
    /// demonstrate if the try fails).
    public static let testColors: [RGB] = [
        ColorMath.rgb(hue: 135, saturation: 55, brightness: 70),
        ColorMath.rgb(hue: 290, saturation: 65, brightness: 60),
        ColorMath.rgb(hue: 75, saturation: 30, brightness: 95),
        ColorMath.rgb(hue: 345, saturation: 90, brightness: 35),
    ]

    public struct Failure: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Distance (pt) within which a pointer gesture counts as "the same spot" in every demo.
    static let fixedTolerance = 10.0

    /// Learns a profile from `demos` (≥ 2). `canvas` is where DrawBot will draw: color pickers
    /// often pop up on top of it, so presses there are NOT ignored, but a picker that covers the
    /// canvas must be closed again at the end of every demonstration (otherwise DrawBot would
    /// draw into it). `screens` are the displays' CG frames (for plausibility checks).
    /// Interpretations whose `hypothesisKey` is in `rejected` are skipped.
    public static func learn(demos: [ColorDemo], canvas: CGRect?, screens: [CGRect], appKey: String,
                             appName: String, rejected: Set<String> = [], now: Date = Date()) -> Result<ColorPickerProfile, Failure> {
        guard demos.count >= 2 else { return .failure(Failure("DrawBot needs at least two demonstrations.")) }
        let actionLists = demos.map { segment($0.inputs) }
        for (i, list) in actionLists.enumerated() where list.isEmpty {
            return .failure(Failure("DrawBot didn't see any clicks or typing for color \(i + 1) (\(demos[i].color.hex))."))
        }

        // Reference: the demo with the fewest actions (latest on ties); align the rest to it.
        var ref = 0
        for i in actionLists.indices where actionLists[i].count <= actionLists[ref].count { ref = i }
        let order = [ref] + actionLists.indices.filter { $0 != ref }
        var groups: [[Action]] = actionLists[ref].map { [$0] }
        var keep = Array(repeating: true, count: groups.count)
        var matches: [Int: [Int?]] = [:]
        for d in order.dropFirst() {
            let match = align(actionLists[ref], actionLists[d])
            matches[d] = match
            for i in groups.indices {
                if let j = match[i] { groups[i].append(actionLists[d][j]) } else { keep[i] = false }
            }
        }
        // Which of each demo's actions survive (are part of a kept group).
        var keptIndices: [Int: Set<Int>] = [ref: Set(groups.indices.filter { keep[$0] })]
        for d in order.dropFirst() {
            keptIndices[d] = Set(groups.indices.filter { keep[$0] }.compactMap { matches[d]![$0] })
        }
        let colors = order.map { demos[$0].color }
        let previous = order.map { demos[$0].previousColor }
        let kept = groups.indices.filter { keep[$0] }.map { groups[$0] }
        guard !kept.isEmpty else {
            return .failure(Failure("The demonstrations had nothing in common. Select both colors the same way (same controls, same order)."))
        }
        // Delays: most of the shortest pause the user left before each action, capped. Not much
        // shorter: dialogs and popups often animate open, and a click that arrives early is lost.
        var delays: [Double] = []
        for (k, g) in kept.enumerated() {
            if k == 0 { delays.append(0.1); continue }
            let prev = kept[k - 1]
            let gap = zip(g, prev).map { $0.start - $1.end }.min() ?? 0.2
            var d = min(max(gap * 0.8, 0.15), 1.2)
            if case .keys = g[0], case .gesture = prev[0] { d = max(d, 0.15) }
            delays.append(d)
        }

        // Typing.
        var typingSteps: [Int: TypingAnalysis] = [:]
        var typedParams = Set<ColorParam>()
        var unresolvedTyping: [String] = []
        for (k, g) in kept.enumerated() {
            let runs = g.compactMap { a -> KeyRun? in if case .keys(let r) = a { return r } else { return nil } }
            guard runs.count == g.count else { continue }
            let analysis = analyzeTyping(runs, colors: colors, delay: delays[k])
            typingSteps[k] = analysis
            typedParams.formUnion(analysis.params)
            unresolvedTyping += analysis.unresolved
        }
        let typingDetermines = PickerColorSpace.determines(typedParams)

        // Pointer controls.
        var obsByGroup: [Int: [Obs]] = [:]
        var spreads: [Int: Double] = [:]
        for (k, g) in kept.enumerated() {
            let gestures = g.compactMap { a -> Gesture? in if case .gesture(let x) = a { return x } else { return nil } }
            guard gestures.count == g.count else { continue }
            obsByGroup[k] = gestures.enumerated().map { i, x in
                Obs(color: colors[i], previous: previous[i], down: x.down, up: x.up, isDrag: x.isDrag)
            }
            spreads[k] = maxPairwise(gestures.map(\.up))
        }
        let varying = obsByGroup.keys.filter { (spreads[$0] ?? 0) > fixedTolerance }.sorted()
        // Gestures that land on the canvas in every demo. Color pickers often pop up over the
        // canvas, so these may be picker clicks — or test strokes the user painted.
        let onCanvas = Set(obsByGroup.keys.filter { k in canvas.map { c in obsByGroup[k]!.allSatisfy { c.contains($0.up) } } ?? false })
        // Not using a moving control costs less when it's on the canvas (probably a test stroke).
        let fixedPenalties = varying.map { k in onCanvas.contains(k) ? min(spreads[k]! / 12, 1) : spreads[k]! / 12 }
        let bounds = screens.isEmpty ? nil : screens.dropFirst().reduce(screens[0]) { $0.union($1) }

        var best: Hypothesis?
        if typingDetermines || varying.isEmpty {
            if !typingDetermines {
                if !unresolvedTyping.isEmpty {
                    return .failure(Failure("DrawBot couldn't tell how what you typed (\(unresolvedTyping.prefix(3).joined(separator: ", "))) relates to the color. Type the hex code, RGB or HSB values exactly as DrawBot shows them."))
                }
                return .failure(Failure("Nothing changed between the two colors: every click landed on the same spot and nothing color-related was typed. Select each color inside the picker itself (or type its hex code)."))
            }
            let h = Hypothesis(space: nil, fits: Array(repeating: nil, count: varying.count), score: 0,
                               key: "typed:" + signature(kept, typing: typingSteps))
            if !rejected.contains(h.key) { best = h }
        } else {
            var all: [Hypothesis] = []
            for space in PickerColorSpace.allCases {
                // Typed parameters must belong to this space (unless typing pins the color).
                guard typedParams.isSubset(of: Set(space.params)) else { continue }
                let needed = Set(space.params).subtracting(typedParams)
                let controls = varying.map { obsByGroup[$0]! }
                all += search(controls: controls, fixedPenalties: fixedPenalties, space: space,
                              needed: needed, bounds: bounds, typedCount: typedParams.count)
            }
            for i in all.indices {
                all[i].key = "\(all[i].space?.rawValue ?? "-"):" + all[i].fits.enumerated()
                    .map { "\($0.offset)=\($0.element?.label ?? "fixed")" }.joined(separator: ";")
                    + "|" + signature(kept, typing: typingSteps)
            }
            best = all.filter { !rejected.contains($0.key) }.max { $0.score < $1.score }
        }
        guard let hyp = best else {
            return .failure(Failure("DrawBot couldn't work out how this color picker turns positions into colors. Typing the hex code into the picker's hex field always works, if your app has one."))
        }

        // Canvas gestures that don't set the color and aren't a button clicked on the same spot
        // every time (drags, dabs that moved) are test strokes: never replay them.
        func isColorControl(_ k: Int) -> Bool {
            guard let vi = varying.firstIndex(of: k) else { return false }
            return hyp.fits[vi] != nil
        }
        var testStrokes = Set<Int>()
        for k in onCanvas where !isColorControl(k) {
            let obs = obsByGroup[k]!
            if obs.filter(\.isDrag).count * 2 > obs.count || spreads[k]! > fixedTolerance { testStrokes.insert(k) }
        }
        let pickerOverCanvas = !onCanvas.subtracting(testStrokes).isEmpty
        if pickerOverCanvas, let problem = checkPickerOverCanvas(
            kept: kept, lastIsColorControl: kept.indices.last(where: { !testStrokes.contains($0) }).map(isColorControl) ?? false,
            actionLists: actionLists, order: order, keptIndices: keptIndices, canvas: canvas!) {
            return .failure(Failure(problem))
        }

        // Build the profile in the reference demo's order.
        var steps: [PickerStep] = []
        var describeParts: [String] = []
        var fixedClicks = 0
        var allPoints: [CGPoint] = []
        for (k, g) in kept.enumerated() where !testStrokes.contains(k) {
            if let t = typingSteps[k] {
                steps.append(.typing(t.step))
                continue
            }
            guard let obs = obsByGroup[k], case .gesture(let refGesture) = g[0] else { continue }
            allPoints += obs.flatMap { [$0.down, $0.up] }
            let dragVotes = obs.filter(\.isDrag).count
            let isDrag = dragVotes * 2 > obs.count
            var mapping: ControlMapping = .fixed(mean(obs.map(\.up)))
            var grabs = false
            if let vi = varying.firstIndex(of: k), let fit = hyp.fits[vi] {
                mapping = fit.mapping
                describeParts.append(mapping.describe)
                // Did the user grab the knob where the previous color left it?
                let withPrev = obs.filter { $0.isDrag && $0.previous != nil }
                let grabbed = withPrev.filter { o in
                    distance(mapping.point(for: o.previous!), o.down) <= 14 && distance(o.down, o.up) > 14
                }
                grabs = !grabbed.isEmpty && grabbed.count * 2 >= withPrev.count
            } else {
                fixedClicks += 1
            }
            let fixedDragStart: CGPoint? = isDrag ? mean(obs.map(\.down)) : nil
            steps.append(.pointer(PointerStep(mapping: mapping, button: refGesture.button, clickCount: refGesture.clickCount,
                                              modifiers: refGesture.modifiers, isDrag: isDrag, dragStart: fixedDragStart,
                                              grabsKnob: grabs, delayBefore: delays[k])))
        }

        var summary: String
        let typedSlots = typingSteps.keys.sorted().flatMap { typingSteps[$0]!.slotNames }
        var uniqueSlots: [String] = []
        for s in typedSlots where !uniqueSlots.contains(s) { uniqueSlots.append(s) }
        if !uniqueSlots.isEmpty {
            summary = "Types the color's " + listFormat(uniqueSlots)
            if !describeParts.isEmpty { summary += " and clicks " + listFormat(describeParts) }
        } else {
            summary = "Clicks " + listFormat(describeParts)
            if let space = hyp.space { summary += " (\(space.rawValue.uppercased()))" }
        }
        if fixedClicks > 0 { summary += ", plus \(fixedClicks) fixed click\(fixedClicks == 1 ? "" : "s")" }
        summary += "."

        var keyMap: [String: KeyStroke] = [:]
        for demo in demos {
            for e in demo.inputs where e.kind == .keyDown && isTextKey(e) && e.characters.count == 1 {
                keyMap[e.characters] = KeyStroke(keyCode: e.keyCode, characters: e.characters,
                                                 modifiers: e.modifiers.intersection([.shift, .option]))
            }
        }
        let pointerBounds: CGRect? = allPoints.isEmpty ? nil : allPoints.dropFirst()
            .reduce(CGRect(origin: allPoints[0], size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            .insetBy(dx: -30, dy: -30)

        return .success(ColorPickerProfile(appKey: appKey, appName: appName, steps: steps, keyMap: keyMap,
                                           space: typingDetermines ? nil : hyp.space, summary: summary,
                                           learnedAt: now, hypothesisKey: hyp.key, pointerBounds: pointerBounds,
                                           isExact: typingDetermines))
    }

    // MARK: - Segmentation

    struct Gesture: Equatable {
        var button: PointerButton
        var clickCount: Int
        var modifiers: KeyModifiers
        var down: CGPoint
        var up: CGPoint
        var travel: Double
        var start: TimeInterval
        var end: TimeInterval
        var isDrag: Bool { travel > 3 }
    }

    struct KeyRun: Equatable {
        var keys: [RecordedInput]
        var start: TimeInterval
        var end: TimeInterval
    }

    enum Action: Equatable {
        case gesture(Gesture)
        case keys(KeyRun)

        var start: TimeInterval {
            switch self { case .gesture(let g): return g.start; case .keys(let k): return k.start }
        }
        var end: TimeInterval {
            switch self { case .gesture(let g): return g.end; case .keys(let k): return k.end }
        }
    }

    /// DrawBot's own ⌃⌥⌘ hotkeys.
    static func isHotkey(_ e: RecordedInput) -> Bool {
        e.modifiers.isSuperset(of: [.control, .option, .command])
    }

    static func segment(_ inputs: [RecordedInput]) -> [Action] {
        let sorted = inputs.enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time < b.element.time : a.offset < b.offset
        }.map(\.element)
        var actions: [Action] = []
        var open: Gesture?
        var run: KeyRun?

        func flushRun() {
            if let r = run { actions.append(.keys(r)) }
            run = nil
        }
        func appendGesture(_ g: Gesture) {
            var g = g
            if case .gesture(let p)? = actions.last, p.button == g.button, !p.isDrag, !g.isDrag,
               distance(p.up, g.down) <= 5, g.start - p.end <= 0.5 {
                // Second / third press of a multi-click. Some event sources report every press as
                // a single click, so count quick presses on the same spot ourselves.
                g.clickCount = min(3, max(g.clickCount, p.clickCount + 1))
                actions[actions.count - 1] = .gesture(g)
                return
            }
            if case .gesture(let p)? = actions.last, p.button == g.button, distance(p.up, g.down) <= 5 {
                // Second press of a double/triple click, or re-clicking the same spot: keep the latest.
                if g.clickCount >= 2 && g.start - p.end <= 0.8 {
                    actions[actions.count - 1] = .gesture(g)
                    return
                }
            }
            if case .gesture(let p)? = actions.last, p.button == g.button, g.clickCount == 1,
               distance(p.up, g.down) <= 12 {
                // A small correction of the previous click on the same control.
                actions[actions.count - 1] = .gesture(g)
                return
            }
            actions.append(.gesture(g))
        }

        for e in sorted {
            switch e.kind {
            case .mouseDown:
                if let g = open { appendGesture(g) }
                flushRun()
                open = Gesture(button: e.button, clickCount: max(1, e.clickCount), modifiers: e.modifiers,
                               down: e.point, up: e.point, travel: 0, start: e.time, end: e.time)
            case .mouseDragged:
                guard var g = open, g.button == e.button else { continue }
                g.up = e.point
                g.travel = max(g.travel, distance(g.down, e.point))
                g.end = e.time
                open = g
            case .mouseUp:
                guard var g = open, g.button == e.button else { continue }
                g.up = e.point
                g.travel = max(g.travel, distance(g.down, e.point))
                g.end = e.time
                appendGesture(g)
                open = nil
            case .keyDown:
                if isHotkey(e) { continue }
                if run == nil { run = KeyRun(keys: [], start: e.time, end: e.time) }
                run!.keys.append(e)
                run!.end = e.time
            }
        }
        if let g = open { appendGesture(g) }
        flushRun()
        return actions
    }

    // MARK: - Pickers on top of the canvas

    /// A color picker that pops up over the canvas (a popover, a floating dialog) must be in
    /// the same state at the start and end of every selection, and closed at the end: DrawBot's
    /// obstruction check cannot see a popup inside the drawing app's own window, so it would
    /// draw straight into an open picker. Returns a message for the user when the demonstrations
    /// show that this isn't the case.
    static func checkPickerOverCanvas(kept: [[Action]], lastIsColorControl: Bool, actionLists: [[Action]], order: [Int],
                                      keptIndices: [Int: Set<Int>], canvas: CGRect) -> String? {
        // 1. Every demo must start the same way: no click of its own (off the canvas) before the
        //    shared actions (typically: the picker was opened in one demo but was still open in
        //    the next).
        for d in order {
            guard let firstKept = keptIndices[d]?.min(), firstKept > 0 else { continue }
            let skipped = actionLists[d][0..<firstKept].contains { a in
                if case .gesture(let g) = a { return !canvas.contains(g.up) }
                return false
            }
            if skipped {
                return "Your color picker sits on top of the canvas, so DrawBot has to open it before every color and close it again before drawing. In one demonstration you clicked something first (probably to open the picker) that you didn't click in the other, which usually means the picker was still open. Start over, and for every color: start with the picker closed, open it, choose the color, close it again, then press Done."
            }
        }
        // 2. Every demo must end with the picker closed: the last shared action must be a fixed
        //    click (a close / OK button, the toggle again) or a key (Return, Esc), not a color control.
        if lastIsColorControl {
            return "Your color picker sits on top of the canvas, but it was still open when you pressed Done. DrawBot would draw into it. Start over, and for every color: open the picker, choose the color, close the picker (its close or OK button, or the button that opened it), then press Done."
        }
        return nil
    }

    // MARK: - Alignment

    /// For each action of `a`, the index of the matching action in `b` (or nil).
    static func align(_ a: [Action], _ b: [Action]) -> [Int?] {
        let n = a.count, m = b.count
        let gap = 2.0
        var cost = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = Double(i) * gap }
        for j in 0...m { cost[0][j] = Double(j) * gap }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let c = matchCost(a[i - 1], b[j - 1])
                    cost[i][j] = min(cost[i - 1][j - 1] + c, cost[i - 1][j] + gap, cost[i][j - 1] + gap)
                }
            }
        }
        var result = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 && j > 0 {
            let c = matchCost(a[i - 1], b[j - 1])
            if c.isFinite && abs(cost[i][j] - (cost[i - 1][j - 1] + c)) < 1e-9 {
                result[i - 1] = j - 1
                i -= 1; j -= 1
            } else if abs(cost[i][j] - (cost[i - 1][j] + gap)) < 1e-9 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result
    }

    static func matchCost(_ a: Action, _ b: Action) -> Double {
        switch (a, b) {
        case (.gesture(let x), .gesture(let y)):
            guard x.button == y.button else { return .infinity }
            let extra = x.clickCount == y.clickCount ? 0 : 0.3
            let d = distance(x.up, y.up)
            if d <= fixedTolerance { return extra }
            // A control that moved: sliders keep one coordinate, so prefer pairs that share one.
            let shared = min(abs(x.up.x - y.up.x), abs(x.up.y - y.up.y))
            return 0.6 + min(Double(shared) / 120, 1.2) + extra
        case (.keys(let x), .keys(let y)):
            let sx = pieces(of: x).map(\.signature), sy = pieces(of: y).map(\.signature)
            return sx == sy ? 0.2 : 1.0
        default:
            return .infinity
        }
    }

    // MARK: - Typing

    enum RawPiece: Equatable {
        case key(KeyStroke)
        case text(String)

        var signature: String {
            switch self {
            case .key(let k): return "k\(k.keyCode)/\(k.modifiers.rawValue)"
            case .text: return "t"
            }
        }
    }

    static func isTextKey(_ e: RecordedInput) -> Bool {
        guard e.modifiers.isDisjoint(with: [.command, .control]), !VirtualKey.nonText.contains(e.keyCode),
              !e.characters.isEmpty else { return false }
        return e.characters.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
    }

    static func pieces(of run: KeyRun) -> [RawPiece] {
        var out: [RawPiece] = []
        var text = ""
        func flush() {
            if !text.isEmpty { out.append(.text(text)) }
            text = ""
        }
        for e in run.keys {
            let stroke = KeyStroke(keyCode: e.keyCode, characters: e.characters, modifiers: e.modifiers)
            if isTextKey(e) {
                text += e.characters
            } else if e.keyCode == VirtualKey.delete && e.modifiers.isEmpty && !text.isEmpty {
                text.removeLast()
            } else if e.modifiers.contains(.command), e.characters.lowercased() == "v" || e.keyCode == VirtualKey.v,
                      let pasted = e.pasteText {
                // A pasted value counts as typed: DrawBot knows every color's values, so it types
                // them instead of going through (and filling up) the clipboard.
                text += pasted
            } else {
                flush()
                out.append(.key(stroke))
            }
        }
        flush()
        return out
    }

    struct TypingAnalysis {
        var step: TypingStep
        var params: Set<ColorParam>
        var unresolved: [String]
        var slotNames: [String]
    }

    /// `runs[i]` was typed for `colors[i]`; runs[0] is the reference.
    static func analyzeTyping(_ runs: [KeyRun], colors: [RGB], delay: Double) -> TypingAnalysis {
        let all = runs.map(pieces(of:))
        let ref = all[0]
        let consistent = all.allSatisfy { $0.map(\.signature) == ref.map(\.signature) }
        var out: [TypingPiece] = []
        var params = Set<ColorParam>()
        var unresolved: [String] = []
        var names: [String] = []
        for (idx, piece) in ref.enumerated() {
            switch piece {
            case .key(let k):
                out.append(.key(k))
            case .text(let s):
                var template = TextTemplate(parts: [.literal(s)])
                if consistent {
                    let strings = all.map { p -> String in
                        switch p[idx] {
                        case .text(let t): return t
                        case .key: return ""
                        }
                    }
                    let (t, bad) = buildTemplate(strings, colors: colors)
                    template = t
                    unresolved += bad
                } else if all.contains(where: { $0 != ref }) {
                    unresolved.append("“\(s)”")
                }
                for slot in template.slots {
                    params.formUnion(slot.params)
                    names.append(slot.displayName)
                }
                out.append(.text(template))
            }
        }
        return TypingAnalysis(step: TypingStep(pieces: out, delayBefore: delay), params: params,
                              unresolved: unresolved, slotNames: names)
    }

    /// Splits each string into tokens (runs of hex digits / '.') and literals; tokens that differ
    /// between demos become slots when one interpretation fits every demo.
    static func buildTemplate(_ strings: [String], colors: [RGB]) -> (TextTemplate, [String]) {
        let toks = strings.map(tokenize)
        let ref = toks[0]
        let sameShape = toks.allSatisfy { t in
            t.count == ref.count && zip(t, ref).allSatisfy { $0.1 == $1.1 && ($0.1 || $0.0 == $1.0) }
        }
        guard sameShape else {
            if strings.allSatisfy({ $0 == strings[0] }) { return (TextTemplate(parts: [.literal(strings[0])]), []) }
            return (TextTemplate(parts: [.literal(strings[0])]), ["“\(strings[0])”"])
        }
        var parts: [TextPart] = []
        var unresolved: [String] = []
        for i in ref.indices {
            let (text, isToken) = ref[i]
            let texts = toks.map { $0[i].0 }
            if !isToken || texts.allSatisfy({ $0 == text }) {
                parts.append(.literal(text))
                continue
            }
            var common = candidates(texts[0], for: colors[0])
            for k in 1..<texts.count { common.formIntersection(candidates(texts[k], for: colors[k])) }
            if let slot = common.min(by: { ($0.priority, "\($0)") < ($1.priority, "\($1)") }) {
                parts.append(.slot(slot))
            } else {
                parts.append(.literal(text))
                unresolved.append("“\(text)”")
            }
        }
        // Merge adjacent literals.
        var merged: [TextPart] = []
        for p in parts {
            if case .literal(let s) = p, case .literal(let prev)? = merged.last {
                merged[merged.count - 1] = .literal(prev + s)
            } else {
                merged.append(p)
            }
        }
        return (TextTemplate(parts: merged), unresolved)
    }

    static func tokenize(_ s: String) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        var cur = ""
        var curIsToken = false
        for ch in s {
            let t = ch.isHexDigit || ch == "."
            if t != curIsToken && !cur.isEmpty {
                out.append((cur, curIsToken))
                cur = ""
            }
            curIsToken = t
            cur.append(ch)
        }
        if !cur.isEmpty { out.append((cur, curIsToken)) }
        return out
    }

    static func scales(for p: ColorParam) -> [Double] {
        switch p {
        case .red, .green, .blue: return [255, 100, 1]
        case .hue: return [360, 100, 1, 240]
        default: return [100, 255, 1, 240]
        }
    }

    /// Every interpretation of `token` that matches color `c`.
    static func candidates(_ token: String, for c: RGB) -> Set<ValueSlot> {
        var out = Set<ValueSlot>()
        if token.count == 6, token.allSatisfy(\.isHexDigit), let v = Int(token, radix: 16) {
            let r = (v >> 16) & 255, g = (v >> 8) & 255, b = v & 255
            if abs(r - Int(c.r)) <= 1 && abs(g - Int(c.g)) <= 1 && abs(b - Int(c.b)) <= 1 {
                out.insert(.hex(uppercase: token.uppercased() == token))
            }
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, token.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
              token.contains(where: \.isNumber), let v = Double(token) else { return out }
        let decimals = parts.count == 2 ? parts[1].count : 0
        for p in ColorParam.allCases {
            for scale in scales(for: p) {
                if decimals == 0 && scale < 50 { continue }
                let expected = p.value(of: c) / p.range * scale
                let tol = max(decimals == 0 ? 1.01 : 1.01 * pow(10, -Double(decimals)), scale * 0.004)
                var diff = abs(v - expected)
                if p == .hue { diff = min(diff, abs(diff - scale)) }
                if diff <= tol { out.insert(.number(param: p, fullScale: scale, decimals: decimals)) }
            }
        }
        return out
    }

    // MARK: - Pointer models

    struct Obs {
        var color: RGB
        var previous: RGB?
        var down: CGPoint
        var up: CGPoint
        var isDrag: Bool
    }

    enum Form: Hashable {
        case axis(ColorParam)
        case plane(ColorParam, ColorParam)
        case polar(ColorParam)
        case ring

        var params: Set<ColorParam> {
            switch self {
            case .axis(let p): return [p]
            case .plane(let a, let b): return [a, b]
            case .polar(let r): return [.hue, r]
            case .ring: return [.hue]
            }
        }
    }

    struct ControlFit {
        var form: Form
        var mapping: ControlMapping
        var score: Double
        var linear: [(ScreenAxis, LinearMap)]
        var diameter: Double?
        var label: String
    }

    struct Hypothesis {
        var space: PickerColorSpace?
        /// One entry per varying control; nil = treated as a fixed click.
        var fits: [ControlFit?]
        var score: Double
        var key: String
    }

    static func fitLinear(_ values: [Double], _ coords: [Double]) -> (offset: Double, slope: Double, rms: Double)? {
        guard values.count >= 2 else { return nil }
        let mv = mean(values), mc = mean(coords)
        var sxx = 0.0, sxy = 0.0
        for (v, c) in zip(values, coords) {
            sxx += (v - mv) * (v - mv)
            sxy += (v - mv) * (c - mc)
        }
        guard sxx > 1e-9 else { return nil }
        let slope = sxy / sxx
        let offset = mc - slope * mv
        let sse = zip(values, coords).reduce(0.0) { s, vc in
            let r = vc.1 - (offset + slope * vc.0)
            return s + r * r
        }
        return (offset, slope, (sse / Double(values.count)).squareRoot())
    }

    /// Least squares for P = c + w·z over complex numbers. Returns (c, w, rms).
    static func fitComplex(_ z: [(Double, Double)], _ p: [CGPoint]) -> (cx: Double, cy: Double, wr: Double, wi: Double, rms: Double)? {
        let n = Double(z.count)
        guard z.count >= 2 else { return nil }
        let zr = z.map(\.0).reduce(0, +) / n, zi = z.map(\.1).reduce(0, +) / n
        let pr = p.map { Double($0.x) }.reduce(0, +) / n, pi = p.map { Double($0.y) }.reduce(0, +) / n
        var numR = 0.0, numI = 0.0, den = 0.0
        for (zk, pk) in zip(z, p) {
            let ar = zk.0 - zr, ai = zk.1 - zi
            let br = Double(pk.x) - pr, bi = Double(pk.y) - pi
            numR += ar * br + ai * bi      // conj(a) * b
            numI += ar * bi - ai * br
            den += ar * ar + ai * ai
        }
        guard den > 1e-9 else { return nil }
        let wr = numR / den, wi = numI / den
        let cx = pr - (wr * zr - wi * zi), cy = pi - (wr * zi + wi * zr)
        var sse = 0.0
        for (zk, pk) in zip(z, p) {
            let ex = cx + wr * zk.0 - wi * zk.1, ey = cy + wr * zk.1 + wi * zk.0
            sse += (Double(pk.x) - ex) * (Double(pk.x) - ex) + (Double(pk.y) - ey) * (Double(pk.y) - ey)
        }
        return (cx, cy, wr, wi, (sse / n).squareRoot())
    }

    static func plausible(_ m: LinearMap, axis: ScreenAxis, bounds: CGRect?) -> Bool {
        let e = m.extent
        guard e >= 24, e <= 3000 else { return false }
        guard let b = bounds?.insetBy(dx: -60, dy: -60) else { return true }
        let iv = m.interval
        let (lo, hi) = axis == .x ? (Double(b.minX), Double(b.maxX)) : (Double(b.minY), Double(b.maxY))
        return iv.lo >= lo && iv.hi <= hi
    }

    static let residualWeight = 1.0 / 3.0

    /// Every way one control could set parameters of `space`.
    static func fits(for obs: [Obs], space: PickerColorSpace, bounds: CGRect?) -> [ControlFit] {
        var out: [ControlFit] = []
        let xs = obs.map { Double($0.up.x) }, ys = obs.map { Double($0.up.y) }
        let params = space.params.filter { p in
            let vs = obs.map { p.value(of: $0.color) }
            return (vs.max()! - vs.min()!) >= 0.08 * p.range
        }
        var linearFits: [ColorParam: [ScreenAxis: (offset: Double, slope: Double, rms: Double)]] = [:]
        for p in params {
            let vs = obs.map { p.value(of: $0.color) }
            linearFits[p] = [:]
            if let f = fitLinear(vs, xs) { linearFits[p]![.x] = f }
            if let f = fitLinear(vs, ys) { linearFits[p]![.y] = f }
        }
        // Sliders.
        for p in params {
            for axis in [ScreenAxis.x, .y] {
                guard let f = linearFits[p]?[axis] else { continue }
                let map = LinearMap(param: p, offset: f.offset, slope: f.slope)
                guard plausible(map, axis: axis, bounds: bounds) else { continue }
                let perp = axis == .x ? ys : xs
                let pm = mean(perp)
                let perpRMS = (perp.reduce(0.0) { $0 + ($1 - pm) * ($1 - pm) } / Double(perp.count)).squareRoot()
                let rms = (f.rms * f.rms + perpRMS * perpRMS).squareRoot()
                out.append(ControlFit(form: .axis(p), mapping: .axis(axis, map, other: pm), score: -rms * residualWeight,
                                      linear: [(axis, map)], diameter: nil, label: "axis-\(axis.rawValue)(\(p.rawValue))"))
            }
        }
        // Areas.
        for px in params {
            for py in params where py != px {
                guard let fx = linearFits[px]?[.x], let fy = linearFits[py]?[.y] else { continue }
                let mx = LinearMap(param: px, offset: fx.offset, slope: fx.slope)
                let my = LinearMap(param: py, offset: fy.offset, slope: fy.slope)
                guard plausible(mx, axis: .x, bounds: bounds), plausible(my, axis: .y, bounds: bounds) else { continue }
                let rms = (fx.rms * fx.rms + fy.rms * fy.rms).squareRoot()
                let aspect = abs(log(mx.extent / my.extent))
                out.append(ControlFit(form: .plane(px, py), mapping: .plane(x: mx, y: my),
                                      score: -rms * residualWeight - 0.8 * aspect,
                                      linear: [(.x, mx), (.y, my)], diameter: nil,
                                      label: "plane(\(px.rawValue),\(py.rawValue))"))
            }
        }
        // Wheels and rings.
        if params.contains(.hue) {
            let hues = obs.map { ColorParam.hue.value(of: $0.color) * .pi / 180 }
            let pts = obs.map(\.up)
            var radii: [ColorParam?] = [nil]
            radii += params.filter { $0 != .hue }.map { Optional($0) }
            for rp in radii {
                for dir in [1.0, -1.0] {
                    let z = obs.indices.map { i -> (Double, Double) in
                        let r = rp.map { $0.value(of: obs[i].color) / $0.range } ?? 1
                        return (r * cos(dir * hues[i]), r * sin(dir * hues[i]))
                    }
                    guard let f = fitComplex(z, pts) else { continue }
                    let scale = (f.wr * f.wr + f.wi * f.wi).squareRoot()
                    guard scale >= (rp == nil ? 15 : 20), scale <= 1200 else { continue }
                    if let b = bounds?.insetBy(dx: -60, dy: -60), !b.contains(CGPoint(x: f.cx, y: f.cy)) { continue }
                    let pm = PolarMap(radius: rp, centerX: f.cx, centerY: f.cy, wRe: f.wr, wIm: f.wi, direction: dir)
                    let label = rp.map { "polar(\($0.rawValue),\(Int(dir)))" } ?? "ring(\(Int(dir)))"
                    out.append(ControlFit(form: rp.map { .polar($0) } ?? .ring, mapping: .polar(pm),
                                          score: -f.rms * residualWeight, linear: [],
                                          diameter: rp == nil ? nil : 2 * scale, label: label))
                }
            }
        }
        return out
    }

    /// Assigns the needed parameters to controls in every possible way and scores each.
    static func search(controls: [[Obs]], fixedPenalties: [Double], space: PickerColorSpace, needed: Set<ColorParam>,
                       bounds: CGRect?, typedCount: Int) -> [Hypothesis] {
        let options = controls.map { fits(for: $0, space: space, bounds: bounds).filter { $0.form.params.isSubset(of: needed) } }
        var out: [Hypothesis] = []
        var chosen: [ControlFit?] = []

        func recurse(_ i: Int, _ remaining: Set<ColorParam>) {
            if i == controls.count {
                guard remaining.isEmpty else { return }
                let used = chosen.compactMap { $0 }
                var score = prior(space: space, fits: used, typed: typedCount > 0) + consistency(used)
                for (k, f) in chosen.enumerated() {
                    score += f?.score ?? -fixedPenalties[k]
                }
                out.append(Hypothesis(space: space, fits: chosen, score: score, key: ""))
                return
            }
            chosen.append(nil)
            recurse(i + 1, remaining)
            chosen.removeLast()
            for f in options[i] where f.form.params.isSubset(of: remaining) {
                chosen.append(f)
                recurse(i + 1, remaining.subtracting(f.form.params))
                chosen.removeLast()
            }
        }
        recurse(0, needed)
        return out
    }

    /// How common a layout is (log-odds-ish). Pickers in the wild:
    /// HSB square + hue strip (Photoshop, Krita, GIMP, Affinity, web pickers), wheel + brightness
    /// slider (macOS, Procreate), hue ring + square (Krita, SAI), slider stacks (RGB / HSB),
    /// hue × saturation area + lightness slider (Windows, MS Paint).
    static func prior(space: PickerColorSpace, fits: [ControlFit], typed: Bool) -> Double {
        var axes = Set<ColorParam>()
        var planes: [(ColorParam, ColorParam)] = []
        var polars: [ColorParam] = []
        var rings = 0
        for f in fits {
            switch f.form {
            case .axis(let p): axes.insert(p)
            case .plane(let a, let b): planes.append((a, b))
            case .polar(let r): polars.append(r)
            case .ring: rings += 1
            }
        }
        func plane(_ a: ColorParam, _ b: ColorParam) -> Bool { planes.contains { $0.0 == a && $0.1 == b } }
        func planeEither(_ a: ColorParam, _ b: ColorParam) -> Bool { plane(a, b) || plane(b, a) }
        var base = 0.0
        switch space {
        case .hsb:
            if planeEither(.hsbSaturation, .hsbBrightness) && axes == [.hue] {
                base = plane(.hsbSaturation, .hsbBrightness) ? 3.0 : 1.6
            } else if rings == 1 && planeEither(.hsbSaturation, .hsbBrightness) {
                base = 2.4
            } else if polars == [.hsbSaturation] && axes == [.hsbBrightness] {
                base = 2.4
            } else if planeEither(.hue, .hsbSaturation) && axes == [.hsbBrightness] {
                base = 1.2
            } else if planeEither(.hue, .hsbBrightness) && axes == [.hsbSaturation] {
                base = 0.8
            } else if axes.count == 3 {
                base = 1.6
            }
        case .rgb:
            if axes.count == 3 { base = 2.0 }
        case .hsl:
            if planeEither(.hue, .hslSaturation) && axes == [.hslLightness] {
                base = 2.0
            } else if axes.count == 3 {
                base = 1.2
            } else if planeEither(.hslSaturation, .hslLightness) && (axes == [.hue] || rings == 1) {
                base = 1.1
            } else if polars == [.hslSaturation] && axes == [.hslLightness] {
                base = 1.0
            }
        }
        if typed { base = max(base, 1.0) }
        // Saturation usually grows to the right, brightness / lightness / saturation upward.
        for f in fits {
            if case .plane(let mx, let my) = f.mapping {
                if [.hsbSaturation, .hslSaturation].contains(mx.param) && mx.slope > 0 { base += 0.3 }
                if [.hsbBrightness, .hslLightness, .hsbSaturation, .hslSaturation].contains(my.param) && my.slope < 0 { base += 0.3 }
            }
        }
        return base
    }

    /// Controls of one picker tend to share a size (a hue strip as tall as the square, RGB sliders
    /// equally long) and line up (stacked sliders, strip beside the square).
    static func consistency(_ fits: [ControlFit]) -> Double {
        var extents: [Double] = []
        var intervals: [ScreenAxis: [(lo: Double, hi: Double)]] = [:]
        for f in fits {
            for (axis, m) in f.linear {
                extents.append(m.extent)
                intervals[axis, default: []].append(m.interval)
            }
            if let d = f.diameter { extents.append(d) }
        }
        guard extents.count >= 2 else { return 0 }
        let med = median(extents)
        var s = -1.2 * extents.reduce(0.0) { $0 + abs(log($1 / med)) }
        for (_, list) in intervals where list.count >= 2 {
            for i in 0..<list.count {
                for j in (i + 1)..<list.count {
                    let inter = min(list[i].hi, list[j].hi) - max(list[i].lo, list[j].lo)
                    let union = max(list[i].hi, list[j].hi) - min(list[i].lo, list[j].lo)
                    if inter > 0 && union > 0 { s += 0.8 * inter / union }
                }
            }
        }
        return s
    }

    /// Structure of the kept actions (so a rejected typed interpretation is recognized).
    static func signature(_ kept: [[Action]], typing: [Int: TypingAnalysis]) -> String {
        kept.indices.map { k -> String in
            if let t = typing[k] {
                return "T[" + t.step.pieces.map { p -> String in
                    switch p {
                    case .key(let s): return "k\(s.keyCode)/\(s.modifiers.rawValue)"
                    case .text(let tpl): return "t\(tpl.slots.count)"
                    case .paste(let tpl, _): return "p\(tpl.slots.count)"
                    }
                }.joined(separator: ",") + "]"
            }
            return "G"
        }.joined(separator: " ")
    }

    // MARK: - Helpers

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }

    static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    static func mean(_ p: [CGPoint]) -> CGPoint {
        guard !p.isEmpty else { return .zero }
        let n = CGFloat(p.count)
        return CGPoint(x: p.map(\.x).reduce(0, +) / n, y: p.map(\.y).reduce(0, +) / n)
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func maxPairwise(_ p: [CGPoint]) -> Double {
        var m = 0.0
        for i in p.indices { for j in p.indices where j > i { m = max(m, distance(p[i], p[j])) } }
        return m
    }

    static func listFormat(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
