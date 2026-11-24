import AppKit
import DrawBotCore

/// How each colour gets selected in the drawing app.
enum ColorSelectionMode: String, Codable, CaseIterable {
    /// DrawBot shows the colour and the user selects it, then presses Continue.
    case manual
    /// Colour Learn: DrawBot replays what it learned from the user's demonstrations.
    case automatic

    var displayName: String {
        switch self {
        case .manual: return "Ask me to select each colour"
        case .automatic: return "Select colours automatically (Colour Learn)"
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
    var countdownSeconds: Int = 1
    var pauseOnMouseMove: Bool = true
    var skipNearWhite: Bool = true
    var autoCopyHex: Bool = true
    var colorSelection: ColorSelectionMode = .manual

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
        countdownSeconds = (try? c.decodeIfPresent(Int.self, forKey: .countdownSeconds)) ?? d.countdownSeconds
        pauseOnMouseMove = (try? c.decodeIfPresent(Bool.self, forKey: .pauseOnMouseMove)) ?? d.pauseOnMouseMove
        skipNearWhite = (try? c.decodeIfPresent(Bool.self, forKey: .skipNearWhite)) ?? d.skipNearWhite
        autoCopyHex = (try? c.decodeIfPresent(Bool.self, forKey: .autoCopyHex)) ?? d.autoCopyHex
        colorSelection = (try? c.decodeIfPresent(ColorSelectionMode.self, forKey: .colorSelection)) ?? d.colorSelection
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

    /// Learned colour pickers, keyed by `ColorPickerProfile.appKey`.
    static func loadProfiles() -> [String: ColorPickerProfile] {
        guard let data = defaults.data(forKey: profilesKey),
              let p = try? JSONDecoder().decode([String: ColorPickerProfile].self, from: data) else { return [:] }
        return p
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
