// Design tokens ported from web/styles.css: the eleven app themes
// (Settings › General › App theme). Amber is the "handheld console" default:
// deep indigo-black surfaces + warm amber phosphor accent. Device themes
// paint the shell colour on the top bar, around the screen and behind the
// controls, with the console's own button colours on the pads; menus, home
// and settings stay dark.
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

enum ThemeName: String, CaseIterable, Identifiable {
    case amber, black, light, dmg, kiwi
    case atomicPurple = "atomic-purple"
    case indigo, fuchsia, glacier, daiei, famicom

    var id: String { rawValue }

    /// The picker's label (web: the chip text).
    var label: String {
        switch self {
        case .amber: return "Amber"
        case .black: return "Pure Black"
        case .light: return "Light"
        case .dmg: return "DMG"
        case .kiwi: return "Kiwi"
        case .atomicPurple: return "Atomic Purple"
        case .indigo: return "Indigo"
        case .fuchsia: return "Fuchsia"
        case .glacier: return "Glacier"
        case .daiei: return "Daiei"
        case .famicom: return "Famicom"
        }
    }

    /// Picker swatch: (background, accent).
    var swatch: (UInt32, UInt32) {
        switch self {
        case .amber: return (0x0C0E16, 0xFFB04D)
        case .black: return (0x000000, 0xFFB04D)
        case .light: return (0xE2E4EA, 0x9C5400)
        case .indigo: return (0x675BA0, 0x7F6AE7)
        case .fuchsia: return (0xAF748C, 0xE8739A)
        case .glacier: return (0x999DB6, 0x769BE5)
        case .kiwi: return (0x6EE126, 0x65DB4D)
        case .dmg: return (0xC2BCB9, 0x9CC954)
        case .atomicPurple: return (0x9769A9, 0xC36EE7)
        case .daiei: return (0xC76637, 0xEB7C33)
        case .famicom: return (0xB99C68, 0xE0635C)
        }
    }

    /// Settings › Game Boy › Palette › "Match app theme": the four shades,
    /// lightest first (web GB_THEME_PALETTES).
    var gbPalette: [UInt32] {
        switch self {
        case .amber: return [0xFFF0D6, 0xFFB04D, 0x8F5312, 0x1A1206]
        case .black: return [0xFFF0D6, 0xFFB04D, 0x7A4A0F, 0x000000]
        case .light: return [0xF3F4F8, 0xD88A1F, 0x9C5400, 0x1D2433]
        case .indigo: return [0xCDC7F0, 0x7F6AE7, 0x55497F, 0x0D0B17]
        case .fuchsia: return [0xF0CCD8, 0xE8739A, 0x7E4560, 0x170A0F]
        case .glacier: return [0xCCD9F0, 0x769BE5, 0x3C4A6B, 0x0B0E16]
        case .kiwi: return [0xEFFBEA, 0x6EE126, 0x2D7A1F, 0x0C170B]
        case .dmg: return [0xEAF3DE, 0xB4ACA9, 0x6F6A6D, 0x262828]
        case .atomicPurple: return [0xE7CBF0, 0xC36EE7, 0x6A3D80, 0x120B16]
        case .daiei: return [0xF2D2B0, 0xEB7C33, 0x8C3D18, 0x160F0B]
        case .famicom: return [0xE6D9BF, 0xB99C68, 0xB44148, 0x25272B]
        }
    }

    var palette: Palette { Palette.make(self) }
}

/// One theme's resolved tokens (web: the :root custom properties).
struct Palette {
    var name: ThemeName = .amber
    var isLight = false

    var bg = Color(hex: 0x0C0E16)
    var stage = Color(hex: 0x05060A)
    var surface1 = Color(hex: 0x141826)
    var surface2 = Color(hex: 0x1C2233)
    var surface3 = Color(hex: 0x262E44)
    var surfaceHover = Color(hex: 0x2F3852)
    var surface2Lo = Color(hex: 0x171D2C)

    var border = Color.white.opacity(0.08)
    var border2 = Color.white.opacity(0.14)

    var text = Color(hex: 0xEAEEF6)
    var textDim = Color(hex: 0x99A3BA)
    var textFaint = Color(hex: 0x808AA1)

    var accent = Color(hex: 0xFFB04D)
    var accent2 = Color(hex: 0xFFC880)
    var accentHi = Color(hex: 0xFFD699)
    var accentInk = Color(hex: 0x2A1800)
    var accentGlow = Color(hex: 0xFFB04D, alpha: 0.32)

    var live = Color(hex: 0x4FD583)
    var danger = Color(hex: 0xFF6B6B)
    var dangerHi = Color(hex: 0xFF9B9B)

    // Chrome: the top bar, the stage around the screen, the control strip.
    var topbarTop = Color(hex: 0x161B2B)
    var topbarBottom = Color(hex: 0x10131E)
    var controlStripTop = Color(hex: 0x0E1119)
    var controlStripBottom = Color(hex: 0x0C0E16)
    var frameLine = Color.white.opacity(0.08)
    var chromeInk = Color(hex: 0xEAEEF6)
    var chromeInkDim = Color(hex: 0x99A3BA)
    var statusInk = Color(hex: 0x99A3BA)
    var chromeBtnTop = Color(hex: 0x1C2233)
    var chromeBtnBottom = Color(hex: 0x171D2C)
    var chromeBtnBorder = Color.white.opacity(0.08)
    var homeBg = Color(hex: 0x0C0E16)
    /// Pure Black lets the ambient glow bleed under the bar and controls.
    var chromeTransparent = false

    var accentTintTop = Color(hex: 0x2A2410)
    var btnActiveBottom = Color(hex: 0x211C0C)
    var padPressedBottom = Color(hex: 0x1D1809)

    // Touch pads.
    var padTop = Color(hex: 0x262E44)
    var padBottom = Color(hex: 0x141826)
    var padBorder = Color.white.opacity(0.14)
    var padLabel = Color(hex: 0x99A3BA)
    var abTop: Color? = nil
    var abBottom: Color? = nil
    var abBorder: Color? = nil
    var abBorderWidth: CGFloat = 1
    var abRing: Color? = nil        // kept by the see-through landscape pads
    var abLabel: Color? = nil
    var pillTop: Color? = nil
    var pillBottom: Color? = nil
    var pillLabel: Color? = nil
    var dpadBorder: Color? = nil
    var dpadBorderWidth: CGFloat = 1
    var dpadBarLine = true          // the cross's inner bar lines
    var panelStripe: Color? = nil   // Famicom pinstripes

    // Library cartridges and system badges.
    var cartGbaTop = Color(hex: 0x6B7488)
    var cartGbaBottom = Color(hex: 0x464E5E)
    var cartGbaLabelLo = Color(hex: 0xD98724)
    var cartGbTop = Color(hex: 0x9A9EA8)
    var cartGbBottom = Color(hex: 0x6E727C)
    var cartGbcTop = Color(hex: 0x8F6FE6)
    var cartGbcBottom = Color(hex: 0x5B3FC0)
    var badgeGbaFg = Color(hex: 0xB3A7FF)
    var badgeGbaBg = Color(red: 138 / 255, green: 125 / 255, blue: 1, opacity: 0.16)
    var badgeGbFg = Color(hex: 0x74D47F)
    var badgeGbBg = Color(red: 95 / 255, green: 191 / 255, blue: 106 / 255, opacity: 0.16)
    var badgeGbcFg = Color(hex: 0x5FD6DE)
    var badgeGbcBg = Color(red: 79 / 255, green: 208 / 255, blue: 216 / 255, opacity: 0.16)
    // Nintendo DS (web styles.css "Nintendo DS": --badge-ds-*, --cart-ds-*).
    var cartDsTop = Color(hex: 0x5D6170)
    var cartDsBottom = Color(hex: 0x3C3F4B)
    var badgeDsFg = Color(hex: 0xFF9F80)
    var badgeDsBg = Color(red: 1, green: 128 / 255, blue: 96 / 255, opacity: 0.16)

    var abTopC: Color { abTop ?? padTop }
    var abBottomC: Color { abBottom ?? padBottom }
    var abBorderC: Color { abBorder ?? padBorder }
    var abLabelC: Color { abLabel ?? padLabel }
    var pillTopC: Color { pillTop ?? padTop }
    var pillBottomC: Color { pillBottom ?? padBottom }
    var pillLabelC: Color { pillLabel ?? padLabel }
    var dpadBorderC: Color { dpadBorder ?? padBorder }

    var colorScheme: ColorScheme { isLight ? .light : .dark }

    func badge(_ system: String) -> (fg: Color, bg: Color) {
        switch system {
        case "GBA": return (badgeGbaFg, badgeGbaBg)
        case "GBC": return (badgeGbcFg, badgeGbcBg)
        case "DS": return (badgeDsFg, badgeDsBg)
        default: return (badgeGbFg, badgeGbBg)
        }
    }

    // swiftlint:disable function_body_length
    static func make(_ t: ThemeName) -> Palette {
        var p = Palette()
        p.name = t
        func dark(bg: UInt32, stage: UInt32, s1: UInt32, s2: UInt32, s3: UInt32, hover: UInt32,
                  text: UInt32, dim: UInt32, faint: UInt32,
                  accent: UInt32, a2: UInt32, ahi: UInt32, ink: UInt32, glow: Double,
                  topTop: UInt32, topBot: UInt32, s2lo: UInt32, strip: UInt32,
                  tint: UInt32, active: UInt32, pressed: UInt32, cartLo: UInt32) {
            p.bg = Color(hex: bg); p.stage = Color(hex: stage)
            p.surface1 = Color(hex: s1); p.surface2 = Color(hex: s2); p.surface3 = Color(hex: s3)
            p.surfaceHover = Color(hex: hover); p.surface2Lo = Color(hex: s2lo)
            p.text = Color(hex: text); p.textDim = Color(hex: dim); p.textFaint = Color(hex: faint)
            p.accent = Color(hex: accent); p.accent2 = Color(hex: a2); p.accentHi = Color(hex: ahi)
            p.accentInk = Color(hex: ink); p.accentGlow = Color(hex: accent, alpha: glow)
            p.topbarTop = Color(hex: topTop); p.topbarBottom = Color(hex: topBot)
            p.controlStripTop = Color(hex: strip); p.controlStripBottom = Color(hex: bg)
            p.accentTintTop = Color(hex: tint); p.btnActiveBottom = Color(hex: active)
            p.padPressedBottom = Color(hex: pressed); p.cartGbaLabelLo = Color(hex: cartLo)
            p.chromeInk = p.text; p.chromeInkDim = p.textDim; p.statusInk = p.textDim
            p.chromeBtnTop = p.surface2; p.chromeBtnBottom = p.surface2Lo
            p.padTop = p.surface3; p.padBottom = p.surface1; p.padLabel = p.textDim
            p.homeBg = p.bg
        }
        // Shell chrome shared by the device themes.
        func shell(top: UInt32, bottom: UInt32, stage: UInt32, stripTop: UInt32, stripBottom: UInt32,
                   line: Double, ink: UInt32, inkDim: UInt32, status: UInt32, darkButtons: Bool) {
            p.topbarTop = Color(hex: top); p.topbarBottom = Color(hex: bottom)
            p.stage = Color(hex: stage)
            p.controlStripTop = Color(hex: stripTop); p.controlStripBottom = Color(hex: stripBottom)
            p.frameLine = Color.black.opacity(line)
            p.chromeInk = Color(hex: ink); p.chromeInkDim = Color(hex: inkDim)
            p.statusInk = Color(hex: status)
            if darkButtons {
                p.chromeBtnTop = Color.black.opacity(0.24); p.chromeBtnBottom = Color.black.opacity(0.32)
                p.chromeBtnBorder = Color.white.opacity(0.22)
            } else {
                p.chromeBtnTop = Color.white.opacity(0.30); p.chromeBtnBottom = Color.white.opacity(0.12)
                p.chromeBtnBorder = Color.black.opacity(0.16)
            }
        }
        func gbaPads() {
            p.padTop = Color(hex: 0xE2E2E5); p.padBottom = Color(hex: 0xC5C4CB)
            p.padBorder = Color(red: 20 / 255, green: 16 / 255, blue: 12 / 255, opacity: 0.32)
            p.padLabel = Color(hex: 0x3A3A40)
        }
        func gbcPads() {
            p.padTop = Color(hex: 0x34363E); p.padBottom = Color(hex: 0x1A1B1F)
            p.padBorder = Color.black.opacity(0.55); p.padLabel = Color(hex: 0xCFCED4)
        }

        switch t {
        case .amber:
            p.homeBg = p.bg
        case .black:
            dark(bg: 0x000000, stage: 0x000000, s1: 0x0E0E0F, s2: 0x161617, s3: 0x202021, hover: 0x29292B,
                 text: 0xECECEE, dim: 0x9C9CA4, faint: 0x808089,
                 accent: 0xFFB04D, a2: 0xFFC880, ahi: 0xFFD699, ink: 0x2A1800, glow: 0.32,
                 topTop: 0x101011, topBot: 0x060607, s2lo: 0x101011, strip: 0x050505,
                 tint: 0x221D0C, active: 0x191507, pressed: 0x141104, cartLo: 0xD98724)
            p.border = Color.white.opacity(0.10); p.border2 = Color.white.opacity(0.17)
            p.padBorder = p.border2
            p.chromeTransparent = true
        case .light:
            p.isLight = true
            p.bg = Color(hex: 0xE2E4EA); p.stage = Color(hex: 0xCDD0D9)
            p.surface1 = Color(hex: 0xEEF0F5); p.surface2 = Color(hex: 0xF3F4F8)
            p.surface3 = Color(hex: 0xFBFCFE); p.surfaceHover = Color(hex: 0xFFFFFF)
            p.surface2Lo = Color(hex: 0xE8EAF1)
            p.border = Color(red: 24 / 255, green: 32 / 255, blue: 52 / 255, opacity: 0.16)
            p.border2 = Color(red: 24 / 255, green: 32 / 255, blue: 52 / 255, opacity: 0.28)
            p.text = Color(hex: 0x1D2433); p.textDim = Color(hex: 0x4D576D); p.textFaint = Color(hex: 0x646C7E)
            p.accent = Color(hex: 0x9C5400); p.accent2 = Color(hex: 0xB76A0A); p.accentHi = Color(hex: 0xD88A1F)
            p.accentInk = Color(hex: 0xFFFFFF); p.accentGlow = Color(hex: 0x9C5400, alpha: 0.28)
            p.live = Color(hex: 0x22A55B); p.danger = Color(hex: 0xCF3F3F); p.dangerHi = Color(hex: 0xE06060)
            p.topbarTop = Color(hex: 0xF7F8FB); p.topbarBottom = Color(hex: 0xE9EBF1)
            p.controlStripTop = Color(hex: 0xDFE2EA); p.controlStripBottom = p.bg
            p.accentTintTop = Color(hex: 0xFFE7C4); p.btnActiveBottom = Color(hex: 0xFFDCA6)
            p.padPressedBottom = Color(hex: 0xF8D193)
            p.cartGbaLabelLo = Color(hex: 0x7A4200)
            p.badgeGbaFg = Color(hex: 0x4F46B8); p.badgeGbaBg = Color(red: 99 / 255, green: 91 / 255, blue: 1, opacity: 0.14)
            p.badgeGbFg = Color(hex: 0x1E7A2E); p.badgeGbBg = Color(red: 46 / 255, green: 150 / 255, blue: 60 / 255, opacity: 0.15)
            p.badgeGbcFg = Color(hex: 0x086F77); p.badgeGbcBg = Color(red: 20 / 255, green: 160 / 255, blue: 170 / 255, opacity: 0.14)
            p.badgeDsFg = Color(hex: 0xB0472A); p.badgeDsBg = Color(red: 210 / 255, green: 90 / 255, blue: 60 / 255, opacity: 0.14)
            p.chromeInk = p.text; p.chromeInkDim = p.textDim; p.statusInk = p.textDim
            p.chromeBtnTop = p.surface2; p.chromeBtnBottom = p.surface2Lo; p.chromeBtnBorder = p.border
            p.padTop = p.surface3; p.padBottom = p.surface1; p.padBorder = p.border2; p.padLabel = p.textDim
            p.frameLine = p.border
            p.homeBg = p.bg
        case .indigo:
            dark(bg: 0x0D0B17, stage: 0x050408, s1: 0x161328, s2: 0x1D1834, s3: 0x262143, hover: 0x312A53,
                 text: 0xECEBEF, dim: 0xA19FAC, faint: 0x858391,
                 accent: 0x7F6AE7, a2: 0xAB9EEB, ahi: 0xCDC7F0, ink: 0x0E0637, glow: 0.35,
                 topTop: 0x19152D, topBot: 0x110F1F, s2lo: 0x1A162F, strip: 0x0E0B18,
                 tint: 0x1C1738, active: 0x15112A, pressed: 0x110E22, cartLo: 0x705CD6)
            shell(top: 0x6C60A5, bottom: 0x5A508C, stage: 0x675BA0, stripTop: 0x695DA3, stripBottom: 0x615596,
                  line: 0.42, ink: 0xFBF7FD, inkDim: 0xD9D2DE, status: 0xEEEBF0, darkButtons: true)
            gbaPads()
        case .fuchsia:
            dark(bg: 0x170A0F, stage: 0x090406, s1: 0x28121B, s2: 0x351823, s3: 0x44202E, hover: 0x54293A,
                 text: 0xEFEBED, dim: 0xAD9FA4, faint: 0x93858B,
                 accent: 0xE8739A, a2: 0xECA2BB, ahi: 0xF0CCD8, ink: 0x340414, glow: 0.32,
                 topTop: 0x2E151F, topBot: 0x200E15, s2lo: 0x301520, strip: 0x190B10,
                 tint: 0x381724, active: 0x2A111B, pressed: 0x220E16, cartLo: 0xD1618E)
            shell(top: 0xB37A91, bottom: 0xA4617C, stage: 0xAF748C, stripTop: 0xB1778F, stripBottom: 0xA96A84,
                  line: 0.34, ink: 0x211D1A, inkDim: 0x282522, status: 0x000000, darkButtons: false)
            gbaPads()
        case .glacier:
            dark(bg: 0x0B0E16, stage: 0x040608, s1: 0x131927, s2: 0x192133, s3: 0x222B42, hover: 0x2B3752,
                 text: 0xEBECEF, dim: 0xA0A3AC, faint: 0x858892,
                 accent: 0x769BE5, a2: 0xA4BBEA, ahi: 0xCCD9F0, ink: 0x061537, glow: 0.30,
                 topTop: 0x161D2C, topBot: 0x0F141F, s2lo: 0x171E2E, strip: 0x0C0F18,
                 tint: 0x182137, active: 0x121929, pressed: 0x0F1422, cartLo: 0x5E85D4)
            shell(top: 0x9FA3BA, bottom: 0x878CA9, stage: 0x999DB6, stripTop: 0x9CA0B8, stripBottom: 0x9094B0,
                  line: 0.34, ink: 0x211D1A, inkDim: 0x413C37, status: 0x282522, darkButtons: false)
            gbaPads()
        case .kiwi:
            dark(bg: 0x0C170B, stage: 0x050804, s1: 0x162813, s2: 0x1C3418, s3: 0x254321, hover: 0x2F532A,
                 text: 0xECEFEB, dim: 0xA1AC9F, faint: 0x8F9A8D,
                 accent: 0x65DB4D, a2: 0x97E189, ahi: 0xC6EDC0, ink: 0x0C3905, glow: 0.28,
                 topTop: 0x182D15, topBot: 0x111F0F, s2lo: 0x192F16, strip: 0x0D180B,
                 tint: 0x1B3916, active: 0x142A10, pressed: 0x10230E, cartLo: 0x4DCC33)
            shell(top: 0x74E22F, bottom: 0x60CC1C, stage: 0x6EE126, stripTop: 0x71E22A, stripBottom: 0x66DA1E,
                  line: 0.34, ink: 0x211D1A, inkDim: 0x524B45, status: 0x4B443F, darkButtons: false)
            gbcPads()
        case .dmg:
            dark(bg: 0x111110, stage: 0x070706, s1: 0x1F1E1C, s2: 0x282824, s3: 0x34332F, hover: 0x41413C,
                 text: 0xEDEDED, dim: 0xA7A6A5, faint: 0x908F8E,
                 accent: 0x9CC954, a2: 0xB1D283, ahi: 0xCDE1B7, ink: 0x273C07, glow: 0.28,
                 topTop: 0x23221F, topBot: 0x181816, s2lo: 0x242421, strip: 0x131311,
                 tint: 0x2B331C, active: 0x202615, pressed: 0x1B1F11, cartLo: 0x7DA63A)
            shell(top: 0xC7C1BE, bottom: 0xB4ACA9, stage: 0xC2BCB9, stripTop: 0xC4BFBC, stripBottom: 0xBBB4B1,
                  line: 0.34, ink: 0x211D1A, inkDim: 0x524B45, status: 0x46403B, darkButtons: false)
            p.padTop = Color(hex: 0x323535); p.padBottom = Color(hex: 0x171818)
            p.padBorder = Color.black.opacity(0.55); p.padLabel = Color(hex: 0x9D98DB)
            p.abTop = Color(hex: 0xB32E68); p.abBottom = Color(hex: 0x87234E)
            p.abBorder = Color.black.opacity(0.4); p.abLabel = Color(hex: 0xF3DBE7)
            p.pillTop = Color(hex: 0x8C8689); p.pillBottom = Color(hex: 0x6F6A6D)
            p.pillLabel = Color(hex: 0x211D33)
        case .atomicPurple:
            dark(bg: 0x120B16, stage: 0x070408, s1: 0x211327, s2: 0x2B1933, s3: 0x372242, hover: 0x452B52,
                 text: 0xEEEBEF, dim: 0xA8A0AC, faint: 0x8E8592,
                 accent: 0xC36EE7, a2: 0xD5A3EB, ahi: 0xE7CBF0, ink: 0x290638, glow: 0.32,
                 topTop: 0x25162C, topBot: 0x1A0F1F, s2lo: 0x26172E, strip: 0x140C18,
                 tint: 0x2D1738, active: 0x21112A, pressed: 0x1C0E22, cartLo: 0xAE54D4)
            shell(top: 0x9B6FAD, bottom: 0x88599B, stage: 0x9769A9, stripTop: 0x996CAB, stripBottom: 0x905FA3,
                  line: 0.42, ink: 0xFBF7FD, inkDim: 0xECE9EF, status: 0xFFFFFF, darkButtons: true)
            gbcPads()
        case .daiei:
            dark(bg: 0x160F0B, stage: 0x080605, s1: 0x271B14, s2: 0x32231A, s3: 0x412E23, hover: 0x513A2C,
                 text: 0xEFEDEC, dim: 0xABA4A0, faint: 0x948D88,
                 accent: 0xEB7C33, a2: 0xEFA76C, ahi: 0xF2D2B0, ink: 0x441904, glow: 0.30,
                 topTop: 0x2C1E17, topBot: 0x1E1510, s2lo: 0x2D1F17, strip: 0x18100C,
                 tint: 0x3B2214, active: 0x2C190F, pressed: 0x24150C, cartLo: 0xCF6A30)
            shell(top: 0xCA6C3E, bottom: 0xAF5A30, stage: 0xC76637, stripTop: 0xC9693A, stripBottom: 0xBB6034,
                  line: 0.34, ink: 0x211D1A, inkDim: 0x23201E, status: 0x000000, darkButtons: false)
            gbaPads()
        case .famicom:
            dark(bg: 0x12110F, stage: 0x070706, s1: 0x211E1A, s2: 0x2A2722, s3: 0x37332D, hover: 0x454038,
                 text: 0xEEEDED, dim: 0xA8A6A4, faint: 0x918F8D,
                 accent: 0xE0635C, a2: 0xE38F87, ahi: 0xEDC2BB, ink: 0x340704, glow: 0.30,
                 topTop: 0x25221E, topBot: 0x191714, s2lo: 0x26231F, strip: 0x141210,
                 tint: 0x3C1613, active: 0x2D100E, pressed: 0x250D0C, cartLo: 0xC74343)
            shell(top: 0xBCA16F, bottom: 0xAF8E53, stage: 0xB99C68, stripTop: 0xBB9E6B, stripBottom: 0xB4955E,
                  line: 0.34, ink: 0x211D1A, inkDim: 0x46403B, status: 0x2E2A27, darkButtons: false)
            p.padTop = Color(hex: 0x3F4349); p.padBottom = Color(hex: 0x25272B)
            p.padBorder = Color.black.opacity(0.5); p.padLabel = Color(hex: 0xE6D9BF)
            p.abTop = Color(hex: 0x3F4349); p.abBottom = Color(hex: 0x25272B)
            p.abBorder = Color(hex: 0xB44148); p.abBorderWidth = 3
            p.abRing = Color(hex: 0xB44148); p.abLabel = Color(hex: 0xE6D9BF)
            p.dpadBorder = Color(hex: 0xB44148); p.dpadBorderWidth = 3; p.dpadBarLine = false
            p.panelStripe = Color(red: 24 / 255, green: 18 / 255, blue: 10 / 255, opacity: 0.62)
        }
        return p
    }
    // swiftlint:enable function_body_length
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette()
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Shape with per-corner radii, used for the d-pad arms and shoulder keys.
struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
