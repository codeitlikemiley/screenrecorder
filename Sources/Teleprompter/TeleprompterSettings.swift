import Foundation
import CoreGraphics

// MARK: - Teleprompter Settings

/// All user-configurable teleprompter preferences.
/// Persisted as a single JSON blob in UserDefaults for atomic read/write.
struct TeleprompterSettings: Codable, Equatable {

    // MARK: Mode

    /// Operating mode for the teleprompter
    var mode: TeleprompterMode = .manual

    // MARK: Typography

    /// Font size in points (16...80)
    var fontSize: CGFloat = 32

    /// Line height multiplier (1.0...3.0)
    var lineHeight: CGFloat = 1.6

    /// Text alignment
    var textAlignment: TeleprompterTextAlignment = .center

    // MARK: Manual Mode Settings

    /// Maximum words per slide for smart chunking (1...120)
    var maxWordsPerSlide: Int = 60



    // MARK: Voice-Follow Mode Settings

    /// How many recent spoken words to use for LCS matching (8...20)
    var phraseWindowSize: Int = 12

    /// Speech recognition locale (e.g. "en-US", "en-PH", "en-GB")
    var speechLocale: String = "en-US"



    // MARK: Appearance

    /// Window opacity (0.3...1.0)
    var opacity: CGFloat = 0.9

    /// Background rendering style
    var backgroundStyle: TeleprompterBackgroundStyle = .frosted

    /// Allow mouse clicks to pass through to apps behind
    var isClickThrough: Bool = false

    /// When true, overrides isExcludedFromRecording so the overlay CAN appear
    /// in screen recordings — useful for demoing the teleprompter feature itself.
    var isVisibleInRecordings: Bool = false

    // MARK: Placement

    /// Preset placement mode
    var placementMode: TeleprompterPlacementMode = .floating

    // MARK: Window Geometry (persisted between launches)

    /// Saved window frame (nil = use default)
    var windowX: CGFloat?
    var windowY: CGFloat?
    var windowWidth: CGFloat?
    var windowHeight: CGFloat?

    /// The display ID where the window was last shown
    var lastScreenID: UInt32?

    // MARK: Computed

    /// Reconstructs a CGRect from the persisted origin + size, or nil if not yet saved.
    var windowFrame: CGRect? {
        guard let x = windowX, let y = windowY,
              let w = windowWidth, let h = windowHeight else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Saves a CGRect into the individual components.
    mutating func setWindowFrame(_ rect: CGRect) {
        windowX = rect.origin.x
        windowY = rect.origin.y
        windowWidth = rect.size.width
        windowHeight = rect.size.height
    }
}

// MARK: - Supporting Enums

enum TeleprompterMode: String, Codable, CaseIterable, Identifiable {
    /// Slide-by-slide, user navigates with ⌘F1/F2
    case manual
    /// Fixed WPM continuous scroll
    case autoScroll
    /// LCS voice-follow continuous scroll
    case voiceFollow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual:      return "Manual"
        case .autoScroll:  return "Auto-Scroll"
        case .voiceFollow: return "Voice-Follow"
        }
    }

    var icon: String {
        switch self {
        case .manual:      return "hand.tap"
        case .autoScroll:  return "scroll"
        case .voiceFollow: return "waveform.badge.mic"
        }
    }
}



enum TeleprompterTextAlignment: String, Codable, CaseIterable, Identifiable {
    case leading
    case center

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leading: return "Left"
        case .center:  return "Center"
        }
    }
}

enum TeleprompterBackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case frosted
    case solid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .frosted:     return "Frosted Glass"
        case .solid:       return "Solid Dark"
        }
    }
}


enum TeleprompterPlacementMode: String, Codable, CaseIterable, Identifiable {
    /// Free-floating, user places it anywhere
    case floating
    /// Pinned to the notch / Dynamic Island area at top-center
    case dynamicIsland
    /// Top-center of the screen, wide and narrow
    case presentationTop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .floating:        return "Floating"
        case .dynamicIsland:   return "Dynamic Island"
        case .presentationTop: return "Presentation (Top)"
        }
    }

    var icon: String {
        switch self {
        case .floating:        return "macwindow"
        case .dynamicIsland:   return "rectangle.topthird.inset.filled"
        case .presentationTop: return "rectangle.topthird.inset.filled"
        }
    }
}

// MARK: - Persistence Store

/// Reads and writes `TeleprompterSettings` as a JSON blob in UserDefaults.
@MainActor
final class TeleprompterSettingsStore {

    static let shared = TeleprompterSettingsStore()

    private let key = "teleprompter_settings_v1"
    private let defaults = UserDefaults.standard

    private init() {}

    func load() -> TeleprompterSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(TeleprompterSettings.self, from: data)
        else {
            return TeleprompterSettings()
        }
        return settings
    }

    func save(_ settings: TeleprompterSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
