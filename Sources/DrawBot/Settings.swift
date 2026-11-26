import AppKit
import DrawBotCore

/// How each color gets selected in the drawing app.
/// How quickly Color Learn selects each color while drawing.
enum SelectionSpeed: String, Codable, CaseIterable {
    case slow, normal, fast, ludicrous

    var displayName: String {
        switch self {
        case .slow: return "Slow (laggy apps)"
        case .normal: return "Normal"
        case .fast: return "Fast"
        case .ludicrous: return "Ludicrous"
        }
    }

    /// Multiplies the pauses between the replayed clicks and keystrokes, and the waits learned
    /// from the user's own pace (e.g. while a dialog opens).
    var pace: Double {
        switch self {
        case .slow: return 1.8
        case .normal: return 1
        case .fast: return 0.5
        case .ludicrous: return 0.25
        }
    }

    /// How long there must have been no click or key press before DrawBot touches the picker
    /// (DrawBot's own drawing counts: apps may still be busy with the last stroke).
    var quietPeriod: TimeInterval {
        switch self {
        case .slow: return 2
        case .normal: return pickerQuietPeriod
        case .fast: return 0.5
        case .ludicrous: return 0.15
        }
    }

    /// Pause after bringing the drawing app to the front.
    var settle: TimeInterval {
        switch self {
        case .slow: return 0.4
        case .normal: return 0.25
        case .fast: return 0.1
        case .ludicrous: return 0.03
        }
    }

    /// Whether the countdown runs before every automatically selected color, or only before the
    /// first one (after that, nobody needs time to take their hands off the mouse).
    var countdownEveryColor: Bool {
        switch self {
        case .slow, .normal: return true
        case .fast, .ludicrous: return false
        }
    }
}

enum ColorSelectionMode: String, Codable, CaseIterable {
    /// DrawBot shows the color and the user selects it, then presses Continue.
    case manual
    /// Color Learn: DrawBot replays what it learned from the user's demonstrations.
    case automatic

    var displayName: String {
        switch self {
        case .manual: return "Ask me to select each color"
        case .automatic: return "Select colors automatically (Color Learn)"
        }
    }
}

/// User-adjustable drawing settings. Persisted as JSON in UserDefaults. Missing keys (older
/// versions, first launch) fall back to the defaults below.
struct DrawSettings: Codable, Equatable {
    var maxColors: Int = 8
    var mergeDistance: Double = 6
    var penSize: Double = 4
    var speed: SpeedPreset = .normal
    var order: ColorOrder = .lightToDark
    var strokeStyle: StrokeStyle = .paths
    var countdownSeconds: Int = 1
    var pauseOnMouseMove: Bool = true
    var skipNearWhite: Bool = true
    var colorSelection: ColorSelectionMode = .manual
    var selectionSpeed: SelectionSpeed = .normal

    static let colorRange = 1...32
    static let mergeRange = 0.0...30.0
    static let penRange = 1.0...40.0
    static let countdownRange = 0...5

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DrawSettings()
        maxColors = (try? c.decodeIfPresent(Int.self, forKey: .maxColors)) ?? d.maxColors
        mergeDistance = (try? c.decodeIfPresent(Double.self, forKey: .mergeDistance)) ?? d.mergeDistance
        penSize = (try? c.decodeIfPresent(Double.self, forKey: .penSize)) ?? d.penSize
        speed = (try? c.decodeIfPresent(SpeedPreset.self, forKey: .speed)) ?? d.speed
        order = (try? c.decodeIfPresent(ColorOrder.self, forKey: .order)) ?? d.order
        strokeStyle = (try? c.decodeIfPresent(StrokeStyle.self, forKey: .strokeStyle)) ?? d.strokeStyle
        countdownSeconds = (try? c.decodeIfPresent(Int.self, forKey: .countdownSeconds)) ?? d.countdownSeconds
        pauseOnMouseMove = (try? c.decodeIfPresent(Bool.self, forKey: .pauseOnMouseMove)) ?? d.pauseOnMouseMove
        skipNearWhite = (try? c.decodeIfPresent(Bool.self, forKey: .skipNearWhite)) ?? d.skipNearWhite
        colorSelection = (try? c.decodeIfPresent(ColorSelectionMode.self, forKey: .colorSelection)) ?? d.colorSelection
        selectionSpeed = (try? c.decodeIfPresent(SelectionSpeed.self, forKey: .selectionSpeed)) ?? d.selectionSpeed
        self = clamped()
    }

    func clamped() -> DrawSettings {
        var s = self
        s.maxColors = min(max(s.maxColors, Self.colorRange.lowerBound), Self.colorRange.upperBound)
        s.mergeDistance = min(max(s.mergeDistance.isFinite ? s.mergeDistance : 6, Self.mergeRange.lowerBound), Self.mergeRange.upperBound)
        s.penSize = min(max(s.penSize.isFinite ? s.penSize : 4, Self.penRange.lowerBound), Self.penRange.upperBound)
        s.countdownSeconds = min(max(s.countdownSeconds, Self.countdownRange.lowerBound), Self.countdownRange.upperBound)
        return s
    }

    var quantizeOptions: QuantizeOptions {
        QuantizeOptions(maxColors: maxColors, mergeDistance: mergeDistance)
    }
}

/// Thin UserDefaults wrapper (the app is unsandboxed; plain paths are fine).
enum SettingsStore {
    private static let defaults = UserDefaults.standard
    private static let settingsKey = "DrawBot.settings.v1"
    private static let imagePathKey = "DrawBot.lastImagePath"
    private static let canvasKey = "DrawBot.lastCanvasCG"
    private static let profilesKey = "DrawBot.colorPickerProfiles.v1"

    /// Learned color pickers, keyed by `ColorPickerProfile.appKey`.
    /// One unreadable profile (e.g. saved by an older version) must not lose the others.
    private struct LossyProfile: Decodable {
        let profile: ColorPickerProfile?
        init(from decoder: Decoder) throws { profile = try? ColorPickerProfile(from: decoder) }
    }

    static func loadProfiles() -> [String: ColorPickerProfile] {
        guard let data = defaults.data(forKey: profilesKey),
              let p = try? JSONDecoder().decode([String: LossyProfile].self, from: data) else { return [:] }
        return p.compactMapValues(\.profile)
    }

    static func saveProfiles(_ profiles: [String: ColorPickerProfile]) {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: profilesKey) }
    }

    static func loadSettings() -> DrawSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(DrawSettings.self, from: data) else { return DrawSettings() }
        return s
    }

    static func save(_ settings: DrawSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: settingsKey) }
    }

    static var lastImagePath: String? {
        get { defaults.string(forKey: imagePathKey) }
        set { defaults.set(newValue, forKey: imagePathKey) }
    }

    /// Last canvas rectangle in CG global coordinates.
    static var lastCanvas: CGRect? {
        get {
            guard let a = defaults.array(forKey: canvasKey) as? [Double], a.count == 4 else { return nil }
            let r = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
            return r.width >= 8 && r.height >= 8 ? r : nil
        }
        set {
            if let r = newValue {
                defaults.set([Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)], forKey: canvasKey)
            } else {
                defaults.removeObject(forKey: canvasKey)
            }
        }
    }
}
