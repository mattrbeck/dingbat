import SwiftUI

/// Every persisted preference, mirroring the web Settings modal (keys and
/// defaults from web/index.js SETTINGS_KEYS). Changes apply immediately:
/// each setter persists to UserDefaults and pushes what it controls into the
/// core or the presenter via `Settings.apply`.
final class Settings: ObservableObject {
    static let shared = Settings()

    enum LandscapeButtons: String, CaseIterable { case outline, bold, solid }
    enum ControlStyle: String, CaseIterable { case dpad, joystick }
    enum JoystickMode: String, CaseIterable { case fixed, floating }
    enum LibraryOpen: String, CaseIterable { case resume, save }
    enum GbPaletteMode: String, CaseIterable { case `default`, theme, custom }
    enum Filter: String, CaseIterable {
        case none, grid, rgb, hq4x, xbr
        var label: String {
            switch self {
            case .none: return "None"
            case .grid: return "LCD grid"
            case .rgb: return "RGB subpixels"
            case .hq4x: return "hq4x"
            case .xbr: return "xBR"
            }
        }
    }

    /// GB_HW_SHADES: the custom palette's starting point.
    static let hardwareShades: [UInt32] = [0xFFF7D6, 0xFFAD73, 0xEF6B6B, 0x7B3A5A]

    private let d = UserDefaults.standard

    // MARK: Controls
    @Published var largeControls: Bool { didSet { d.set(largeControls, forKey: "large-controls") } }
    @Published var landscapeButtons: LandscapeButtons { didSet { d.set(landscapeButtons.rawValue, forKey: "landscape-buttons") } }
    @Published var rumble: Bool { didSet { d.set(rumble, forKey: "gbRumble") } }
    @Published var controlStyle: ControlStyle { didSet { d.set(controlStyle.rawValue, forKey: "control-style") } }
    @Published var joystickMode: JoystickMode { didSet { d.set(joystickMode.rawValue, forKey: "joystick-mode") } }
    @Published var hideTouchOnGamepad: Bool { didSet { d.set(hideTouchOnGamepad, forKey: "hide-touch-on-gamepad") } }
    @Published var inputDisplay: Bool { didSet { d.set(inputDisplay, forKey: "input-display") } }
    @Published var libraryOpen: LibraryOpen { didSet { d.set(libraryOpen.rawValue, forKey: "library-open") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }

    // MARK: Game Boy
    @Published var gbPaletteMode: GbPaletteMode { didSet { d.set(gbPaletteMode.rawValue, forKey: "gb-palette.mode"); applyVideo() } }
    @Published var gbPaletteCustom: [UInt32] { didSet { d.set(gbPaletteCustom.map { Int($0) }, forKey: "gb-palette.custom"); applyVideo() } }
    @Published var sgbEnable: Bool { didSet { d.set(sgbEnable, forKey: "sgbEnable"); dingbat_set_sgb(sgbEnable ? 1 : 0) } }
    @Published var sgbBorder: Bool { didSet { d.set(sgbBorder, forKey: "sgbBorder"); dingbat_set_sgb_border(sgbBorder ? 1 : 0); GameRenderer.shared.redraw() } }

    // MARK: GBA
    @Published var gbaRunBios: Bool { didSet { d.set(gbaRunBios, forKey: "gbaRunBios"); dingbat_set_gba_run_bios(gbaRunBios ? 1 : 0) } }
    @Published var gbaBiosMode: Int { didSet { d.set(gbaBiosMode, forKey: "gbaBiosMode"); dingbat_set_gba_bios_mode(Int32(gbaBiosMode)) } }

    // MARK: Video
    @Published var colorCorrect: Bool { didSet { d.set(colorCorrect, forKey: "colorCorrect"); dingbat_set_color_correction(colorCorrect ? 1 : 0); applyVideo() } }
    @Published var filter: Filter { didSet { d.set(filter.rawValue, forKey: "video.upscaleFilter"); applyVideo() } }
    @Published var integerScale: Bool { didSet { d.set(integerScale, forKey: "video.integerScale") } }
    @Published var lcdResponse: Bool { didSet { d.set(lcdResponse, forKey: "video.lcdResponse"); dingbat_set_lcd_response(lcdResponse ? 1 : 0) } }
    @Published var ambientGlow: Bool { didSet { d.set(ambientGlow, forKey: "video.ambientGlow") } }

    // MARK: Audio
    @Published var fifoInterp: Bool { didSet { d.set(fifoInterp, forKey: "audio.fifoInterp"); dingbat_set_fifo_interp(fifoInterp ? 1 : 0) } }
    @Published var mp2kHle: Bool { didSet { d.set(mp2kHle, forKey: "audio.mp2kHle"); dingbat_set_mp2k_hle(mp2kHle ? 1 : 0) } }
    @Published var pitchCorrectFF: Bool { didSet { d.set(pitchCorrectFF, forKey: "audio.pitchCorrectFF"); dingbat_set_pitch_correct_ff(pitchCorrectFF ? 1 : 0) } }
    @Published var analogFilter: Bool { didSet { d.set(analogFilter, forKey: "audio.audioLowpass") } }
    @Published var playInSilent: Bool { didSet { d.set(playInSilent, forKey: "audio.playInSilent") } }
    @Published var volume: Int { didSet { d.set(volume, forKey: "audio.volume"); applyVolume() } }
    @Published var muted: Bool { didSet { d.set(muted, forKey: "audio.muted"); applyVolume() } }
    /// Settings › Audio › Channels: bit i mutes channel i. Never saved.
    @Published var channelMutes: Int = 0 { didSet { dingbat_set_channel_mutes(Int32(channelMutes)) } }

    // MARK: General
    @Published var theme: ThemeName { didSet { d.set(theme.rawValue, forKey: "dingbat_theme"); applyVideo() } }
    @Published var rewind: Bool { didSet { d.set(rewind, forKey: "rewindOn"); dingbat_set_rewind(rewind ? 1 : 0, 0) } }
    @Published var runahead: Int { didSet { d.set(runahead, forKey: "runahead") } }
    @Published var saveWebhook: String { didSet { d.set(saveWebhook, forKey: "save-hook") } }

    var palette: Palette { theme.palette }

    private init() {
        let d = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func str(_ k: String) -> String? { d.string(forKey: k) }
        largeControls = bool("large-controls", false)
        landscapeButtons = LandscapeButtons(rawValue: str("landscape-buttons") ?? "") ?? .bold
        rumble = bool("gbRumble", true)
        controlStyle = ControlStyle(rawValue: str("control-style") ?? "") ?? .dpad
        joystickMode = JoystickMode(rawValue: str("joystick-mode") ?? "") ?? .fixed
        hideTouchOnGamepad = bool("hide-touch-on-gamepad", true)
        inputDisplay = bool("input-display", false)
        libraryOpen = LibraryOpen(rawValue: str("library-open") ?? "") ?? .resume
        haptics = bool("haptics", true)
        gbPaletteMode = GbPaletteMode(rawValue: str("gb-palette.mode") ?? "") ?? .default
        let custom = (d.array(forKey: "gb-palette.custom") as? [Int])?.map { UInt32($0) }
        gbPaletteCustom = custom?.count == 4 ? custom! : Settings.hardwareShades
        sgbEnable = bool("sgbEnable", false)
        sgbBorder = bool("sgbBorder", true)
        gbaRunBios = bool("gbaRunBios", true)
        gbaBiosMode = d.object(forKey: "gbaBiosMode") == nil ? 0 : d.integer(forKey: "gbaBiosMode")
        colorCorrect = bool("colorCorrect", true)
        filter = Filter(rawValue: str("video.upscaleFilter") ?? "") ?? .none
        integerScale = bool("video.integerScale", false)
        lcdResponse = bool("video.lcdResponse", false)
        ambientGlow = bool("video.ambientGlow", false)
        fifoInterp = bool("audio.fifoInterp", true)
        mp2kHle = bool("audio.mp2kHle", false)
        pitchCorrectFF = bool("audio.pitchCorrectFF", true)
        analogFilter = bool("audio.audioLowpass", true)
        playInSilent = bool("audio.playInSilent", true)
        volume = d.object(forKey: "audio.volume") == nil ? 100 : d.integer(forKey: "audio.volume")
        muted = bool("audio.muted", false)
        theme = ThemeName(rawValue: str("dingbat_theme") ?? "") ?? .amber
        rewind = bool("rewindOn", true)
        runahead = d.integer(forKey: "runahead")
        saveWebhook = str("save-hook") ?? ""
    }

    /// The four DMG shades the presenter substitutes, or nil for the
    /// hardware's own green (the core's values, colour corrected).
    var dmgPalette: [UInt32]? {
        switch gbPaletteMode {
        case .default: return nil
        case .theme: return theme.gbPalette
        case .custom: return gbPaletteCustom
        }
    }

    /// Push every option into the core (options read at construction and
    /// live ones alike) and the presenter. Call once after dingbat_init().
    func apply() {
        dingbat_set_sgb(sgbEnable ? 1 : 0)
        dingbat_set_sgb_border(sgbBorder ? 1 : 0)
        dingbat_set_gba_run_bios(gbaRunBios ? 1 : 0)
        dingbat_set_gba_bios_mode(Int32(gbaBiosMode))
        dingbat_set_color_correction(colorCorrect ? 1 : 0)
        dingbat_set_lcd_response(lcdResponse ? 1 : 0)
        dingbat_set_fifo_interp(fifoInterp ? 1 : 0)
        dingbat_set_mp2k_hle(mp2kHle ? 1 : 0)
        dingbat_set_pitch_correct_ff(pitchCorrectFF ? 1 : 0)
        dingbat_set_channel_mutes(Int32(channelMutes))
        dingbat_set_rewind(rewind ? 1 : 0, 0)
        applyVolume()
        applyVideo()
    }

    func applyVolume() {
        dingbat_set_volume(Int32(volume), muted ? 1 : 0)
        AudioOutput.shared.refreshSession()
    }

    func applyVideo() {
        var o = PresentOptions()
        o.colorCorrect = colorCorrect
        o.filter = filter == .hq4x ? 1 : filter == .xbr ? 2 : 0
        o.grid = filter == .grid
        o.subpixel = filter == .rgb
        o.dmgPalette = dmgPalette
        GameRenderer.shared.options = o
        GameRenderer.shared.redraw()
    }

    /// Settings › General › Reset all settings: every key back to its
    /// default (the library, saves and states are untouched).
    func resetAll() {
        for k in ["large-controls", "landscape-buttons", "gbRumble", "control-style", "joystick-mode",
                  "hide-touch-on-gamepad", "input-display", "library-open", "haptics",
                  "gb-palette.mode", "gb-palette.custom", "sgbEnable", "sgbBorder",
                  "gbaRunBios", "gbaBiosMode", "colorCorrect", "video.upscaleFilter",
                  "video.integerScale", "video.lcdResponse", "video.ambientGlow",
                  "audio.fifoInterp", "audio.mp2kHle", "audio.pitchCorrectFF", "audio.audioLowpass",
                  "audio.playInSilent", "audio.volume", "audio.muted", "dingbat_theme",
                  "rewindOn", "runahead", "save-hook"] {
            d.removeObject(forKey: k)
        }
        let fresh = Settings()
        largeControls = fresh.largeControls
        landscapeButtons = fresh.landscapeButtons
        rumble = fresh.rumble
        controlStyle = fresh.controlStyle
        joystickMode = fresh.joystickMode
        hideTouchOnGamepad = fresh.hideTouchOnGamepad
        inputDisplay = fresh.inputDisplay
        libraryOpen = fresh.libraryOpen
        haptics = fresh.haptics
        gbPaletteMode = fresh.gbPaletteMode
        gbPaletteCustom = fresh.gbPaletteCustom
        sgbEnable = fresh.sgbEnable
        sgbBorder = fresh.sgbBorder
        gbaRunBios = fresh.gbaRunBios
        gbaBiosMode = fresh.gbaBiosMode
        colorCorrect = fresh.colorCorrect
        filter = fresh.filter
        integerScale = fresh.integerScale
        lcdResponse = fresh.lcdResponse
        ambientGlow = fresh.ambientGlow
        fifoInterp = fresh.fifoInterp
        mp2kHle = fresh.mp2kHle
        pitchCorrectFF = fresh.pitchCorrectFF
        analogFilter = fresh.analogFilter
        playInSilent = fresh.playInSilent
        volume = fresh.volume
        muted = fresh.muted
        channelMutes = 0
        theme = fresh.theme
        rewind = fresh.rewind
        runahead = fresh.runahead
        saveWebhook = fresh.saveWebhook
        apply()
    }
}
