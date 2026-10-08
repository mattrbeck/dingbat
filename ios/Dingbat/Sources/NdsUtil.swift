import CoreGraphics
import Foundation

// Nintendo DS helpers, a port of web/nds/ndsutil.js (NdsUtil): file
// detection, the two-screen layout, stylus mapping and Blow's noise. Pure
// functions, so the math is the web's to the line: the same arrangements,
// the same rects, the same client point -> bottom-screen pixel.

enum NdsUtil {
    /// Each screen (GBATEK "DS Video").
    static let W: CGFloat = 256, H: CGFloat = 192
    /// The core's video frame rate: 33513982 Hz / (2130 * 263) a frame.
    static let fps = 59.8261

    // MARK: detection

    /// CRC-16 as GBATEK "BIOS Misc Functions" GetCRC16 states it (the
    /// header's checksums use it with initial value FFFFh).
    private static let crcVal: [UInt32] = [0xC0C1, 0xC181, 0xC301, 0xC601, 0xCC01, 0xD801, 0xF001, 0xA001]
    static func crc16(_ b: [UInt8], _ start: Int, _ end: Int, initial: UInt32 = 0xFFFF) -> UInt32 {
        var crc = initial
        for i in start..<end {
            crc ^= UInt32(b[i])
            for j in 0..<8 {
                let carry = crc & 1
                crc >>= 1
                if carry != 0 { crc ^= crcVal[j] << UInt32(7 - j) }
            }
        }
        return crc & 0xFFFF
    }

    /// web looksLikeNdsRom: any signal matches (homebrew is often built
    /// without a valid logo): the header CRC at 15Eh over [000h-15Dh], or
    /// the logo checksum CF56h at 15Ch (GBATEK "DS Cartridge Header").
    static func looksLikeNdsRom(_ d: Data) -> Bool {
        guard d.count >= 0x200 else { return false }
        let b = [UInt8](d.prefix(0x200))
        func rd16(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 }
        if rd16(0x15C) == 0xCF56 { return true }
        return rd16(0x15E) == crc16(b, 0, 0x15E)
    }

    // MARK: the two screens

    /// web ARRANGEMENTS, with their names in the Screens sheet.
    enum Arrangement: String, CaseIterable {
        case auto, stack, side, focus, single
        var label: String {
            switch self {
            case .auto: return "Automatic"
            case .stack: return "Stacked"
            case .side: return "Side by side"
            case .focus: return "Focus"
            case .single: return "One screen"
            }
        }
    }

    /// web GAPS: none, a hinge line, or the console's own (an estimate,
    /// Assumed: docs/nds/web.md "Screens").
    enum Gap: String, CaseIterable {
        case none, hinge, console
        var px: CGFloat { self == .none ? 0 : self == .hinge ? 8 : 90 }
        var label: String { self == .none ? "None" : self == .hinge ? "Hinge" : "Like the console" }
    }

    /// web ROTATIONS: 0 upright, 1 a quarter turn clockwise (Book, right),
    /// 3 anticlockwise (Book, left).
    static let rotations = [0, 3, 1]
    static func rotLabel(_ r: Int) -> String { r == 3 ? "Book, left" : r == 1 ? "Book, right" : "Upright" }

    /// Focus's small screen, a third of the large one.
    static let small: CGFloat = 1.0 / 3

    enum Screen { case top, bottom }

    /// An upright composite: its size and each screen's rect (nil when not
    /// shown).
    struct Composite {
        var w: CGFloat, h: CGFloat
        var top: CGRect?, bottom: CGRect?
        func rect(_ s: Screen) -> CGRect? { s == .top ? top : bottom }
    }

    /// web compose. Focus keeps at most a hinge's gap.
    static func compose(_ shape: String, gap: CGFloat, swap: Bool) -> Composite {
        var c = Composite(w: W, h: 2 * H + gap)
        func set(_ first: CGRect?, _ second: CGRect?) {
            if swap { c.bottom = first; c.top = second } else { c.top = first; c.bottom = second }
        }
        let g = min(gap, Gap.hinge.px), sw = W * small, sh = H * small
        switch shape {
        case "side":
            set(CGRect(x: 0, y: 0, width: W, height: H), CGRect(x: W + gap, y: 0, width: W, height: H))
            c.w = 2 * W + gap; c.h = H
        case "single":
            set(CGRect(x: 0, y: 0, width: W, height: H), nil)
            c.w = W; c.h = H
        case "focus-below":
            set(CGRect(x: 0, y: 0, width: W, height: H), CGRect(x: (W - sw) / 2, y: H + g, width: sw, height: sh))
            c.w = W; c.h = H + g + sh
        case "focus-beside":
            set(CGRect(x: 0, y: 0, width: W, height: H), CGRect(x: W + g, y: (H - sh) / 2, width: sw, height: sh))
            c.w = W + g + sw; c.h = H
        default: // stack
            set(CGRect(x: 0, y: 0, width: W, height: H), CGRect(x: 0, y: H + gap, width: W, height: H))
            c.w = W; c.h = 2 * H + gap
        }
        return c
    }

    /// web fitScale: whole multiples from 1x up with integer scaling, and a
    /// box too small for 1x gets the plain fit.
    static func fitScale(_ aw: CGFloat, _ ah: CGFloat, _ w: CGFloat, _ h: CGFloat, integer: Bool) -> CGFloat {
        guard aw > 0, ah > 0 else { return 0 }
        let s = min(aw / w, ah / h)
        return integer && s >= 1 ? floor(s) : s
    }

    /// web layout's result: `mode` the arrangement (auto resolved), `shape`
    /// the composite drawn, w x h the picture as shown (turned), uw x uh the
    /// upright composite, the rects in it, and the scale that fits.
    struct Layout: Equatable {
        var mode: Arrangement = .stack
        var shape = "stack"
        var rot = 0
        var swap = false
        var gap: CGFloat = 8
        var uw: CGFloat = W, uh: CGFloat = 2 * H + 8
        var w: CGFloat = W, h: CGFloat = 2 * H + 8
        var top: CGRect? = CGRect(x: 0, y: 0, width: W, height: H)
        var bottom: CGRect? = CGRect(x: 0, y: H + 8, width: W, height: H)
        var scale: CGFloat = 0
        func rect(_ s: Screen) -> CGRect? { s == .top ? top : bottom }
        /// Focus or One screen: a tap on the top screen swaps.
        var oneLarge: Bool { mode == .focus || mode == .single }
    }

    static func layout(_ availW: CGFloat, _ availH: CGFloat, _ pref: Arrangement,
                       gap: CGFloat = 0, integer: Bool = false, swap: Bool = false, rot r: Int = 0) -> Layout {
        let rot = rotations.contains(r) ? r : 0
        func turned(_ c: Composite) -> (CGFloat, CGFloat) { rot != 0 ? (c.h, c.w) : (c.w, c.h) }
        // Unrounded fits even under integer scaling: a box that holds 1.9x
        // one way and 1.2x the other wants the first.
        func fit(_ c: Composite) -> CGFloat { let t = turned(c); return fitScale(availW, availH, t.0, t.1, integer: false) }
        func pick(_ a: String, _ b: String) -> (String, Composite) {
            let ca = compose(a, gap: gap, swap: swap), cb = compose(b, gap: gap, swap: swap)
            return fit(cb) > fit(ca) ? (b, cb) : (a, ca)
        }
        var mode = pref
        let shape: String, c: Composite
        switch pref {
        case .auto:
            (shape, c) = pick("stack", "side")
            mode = shape == "side" ? .side : .stack
        case .focus:
            (shape, c) = pick("focus-below", "focus-beside")
        default:
            shape = pref.rawValue
            c = compose(shape, gap: gap, swap: swap)
        }
        let (w, h) = turned(c)
        var out = Layout()
        out.mode = mode; out.shape = shape; out.rot = rot; out.swap = swap; out.gap = gap
        out.uw = c.w; out.uh = c.h; out.w = w; out.h = h
        out.top = c.top; out.bottom = c.bottom
        out.scale = fitScale(availW, availH, w, h, integer: integer)
        return out
    }

    /// web turnRect: an upright rect of the composite where it shows, turned.
    static func turnRect(_ r: CGRect, _ lay: Layout) -> CGRect {
        switch lay.rot {
        case 1: return CGRect(x: lay.uh - r.minY - r.height, y: r.minX, width: r.height, height: r.width)
        case 3: return CGRect(x: r.minY, y: lay.uw - r.minX - r.width, width: r.height, height: r.width)
        default: return r
        }
    }

    /// web views: each shown screen's place in the turned picture (layout
    /// pixels) and the turn it is drawn with.
    struct View: Equatable { var screen: Screen; var dst: CGRect; var rot: Int }
    static func views(_ lay: Layout) -> [View] {
        [Screen.top, .bottom].compactMap { s in
            lay.rect(s).map { View(screen: s, dst: turnRect($0, lay), rot: lay.rot) }
        }
    }

    /// web toComposite: a point in the picture's box (`rect`, which the
    /// picture fills) -> the upright composite's coordinates.
    static func toComposite(_ p: CGPoint, _ rect: CGRect, _ lay: Layout) -> CGPoint {
        let dx = (p.x - rect.minX) * lay.w / rect.width
        let dy = (p.y - rect.minY) * lay.h / rect.height
        switch lay.rot {
        case 1: return CGPoint(x: dy, y: lay.uh - dx)
        case 3: return CGPoint(x: lay.uw - dy, y: dx)
        default: return CGPoint(x: dx, y: dy)
        }
    }

    /// web screenAt: which screen a point is on, if any.
    static func screenAt(_ p: CGPoint, _ rect: CGRect, _ lay: Layout) -> Screen? {
        let f = toComposite(p, rect, lay)
        for s in [Screen.bottom, .top] {
            if let r = lay.rect(s), f.x >= r.minX, f.x < r.maxX, f.y >= r.minY, f.y < r.maxY { return s }
        }
        return nil
    }

    /// web touchPoint: a point -> the bottom screen's pixel, exact at any
    /// scale, arrangement and turn; clamped to the screen either way, so a
    /// stylus dragged off the edge stays on the edge.
    static func touchPoint(_ p: CGPoint, _ rect: CGRect, _ lay: Layout) -> (x: Int, y: Int, inside: Bool) {
        guard let b = lay.bottom, rect.width > 0, rect.height > 0 else { return (0, 0, false) }
        let f = toComposite(p, rect, lay)
        let fx = ((f.x - b.minX) * W / b.width).rounded(.down)
        let fy = ((f.y - b.minY) * H / b.height).rounded(.down)
        guard fx.isFinite, fy.isFinite else { return (0, 0, false) }
        let inside = fx >= 0 && fx < W && fy >= 0 && fy < H
        return (Int(min(W - 1, max(0, fx))), Int(min(H - 1, max(0, fy))), inside)
    }

    /// web clientPoint, the inverse: the point at the centre of a screen's
    /// pixel (px, py), or nil when that screen is not shown. The stylus
    /// self-test aims with it.
    static func clientPoint(_ s: Screen, _ px: Int, _ py: Int, _ rect: CGRect, _ lay: Layout) -> CGPoint? {
        guard let r = lay.rect(s) else { return nil }
        let fx = r.minX + (CGFloat(px) + 0.5) * r.width / W, fy = r.minY + (CGFloat(py) + 0.5) * r.height / H
        let d: (CGFloat, CGFloat) = lay.rot == 1 ? (lay.uh - fy, fx) : lay.rot == 3 ? (fy, lay.uw - fx) : (fx, fy)
        return CGPoint(x: rect.minX + d.0 * rect.width / lay.w, y: rect.minY + d.1 * rect.height / lay.h)
    }

    // MARK: microphone

    /// Blowing into the microphone, for a device without one: white noise
    /// at about 60% of full scale (web blowNoise, Assumed: a game's blow
    /// test listens for a loud level).
    static let blowLevel: Float = 20000
    static func blowNoise(_ n: Int) -> [Int16] {
        (0..<n).map { _ in Int16((Float.random(in: 0..<1) * 2 - 1) * blowLevel) }
    }

    // MARK: BIOS / firmware dumps

    /// web biosKindOf / BIOS_SIZES (GBATEK "DS Memory Map": ARM9 BIOS 4 KB,
    /// ARM7 BIOS 16 KB; firmware 256 KB on a DS, 128 KB on some parts, 512
    /// KB on a DSi).
    enum BiosKind: String, CaseIterable {
        case bios9, bios7, firmware
        var sizes: [Int] {
            switch self {
            case .bios9: return [4096]
            case .bios7: return [16384]
            case .firmware: return [131072, 262144, 524288]
            }
        }
        var fileName: String { "nds_" + rawValue + ".bin" }
        var label: String {
            switch self {
            case .bios9: return "ARM9 BIOS (bios9.bin)"
            case .bios7: return "ARM7 BIOS (bios7.bin)"
            case .firmware: return "Firmware (firmware.bin)"
            }
        }
    }
}
