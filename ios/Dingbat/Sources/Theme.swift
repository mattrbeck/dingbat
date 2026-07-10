// Design tokens ported from web/styles.css — the "handheld console" look:
// deep indigo-black surfaces + warm amber phosphor accent.
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

enum Theme {
    static let bg          = Color(hex: 0x0C0E16)
    static let stage       = Color(hex: 0x05060A)
    static let surface1    = Color(hex: 0x141826)
    static let surface2    = Color(hex: 0x1C2233)
    static let surface3    = Color(hex: 0x262E44)

    static let border      = Color.white.opacity(0.08)
    static let border2     = Color.white.opacity(0.14)

    static let text        = Color(hex: 0xEAEEF6)
    static let textDim     = Color(hex: 0x99A3BA)
    static let textFaint   = Color(hex: 0x616B83)

    static let accent      = Color(hex: 0xFFB04D)
    static let accent2     = Color(hex: 0xFFC880)
    static let accentInk   = Color(hex: 0x2A1800)
    static let accentGlow  = Color(hex: 0xFFB04D, alpha: 0.32)

    static let live        = Color(hex: 0x4FD583)
    static let danger      = Color(hex: 0xFF6B6B)

    // .pad-btn / .pad-btn.pressed gradients
    static let padTop        = surface3
    static let padBottom     = surface1
    static let padPressedTop = Color(hex: 0x2A2410)
    static let padPressedBot = Color(hex: 0x1D1809)
    static let padPressedBorder = Color(hex: 0xFFB04D, alpha: 0.55)
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
