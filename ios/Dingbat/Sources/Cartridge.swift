// A game with no picture yet gets a cartridge of its system's shape, and on
// its label a short mark to tell it from the next one: two initials and a
// sequel's number (web "Cartridge labels": cartTitle, cartLabelFor,
// buildCart). The mark comes from a tidied title, used for the label only;
// the tile's own name is the library's.
//   "0412 - Metroid Fusion (U) [!].gba"          -> Metroid Fusion       -> MF
//   "Legend of Zelda, The - The Minish Cap (U)"  -> The Legend of ...    -> LZ
//   "GoodboyGalaxy.gba" -> GG   "advance_wars_2.gba" -> AW2
//   "Final Fantasy VI Advance (J)" -> FF6   "TETRIS.gb" -> Te
import SwiftUI

enum CartLabel {
    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    private static let tags = re(#"\s*[(\[][^)\]]*[)\]]"#)       // (U) [!] (Rev 1) (En,Fr)
    private static let number = re(#"^\s*\d{3,5}\s*-\s*"#)        // "0412 - "
    private static let article = re(#"^([^,]+),\s*(The|A|An)\b"#, .caseInsensitive) // "Zelda, The"
    private static let spaces = re(#"\s+"#)
    private static let camel = re("([a-z])([A-Z])")
    private static let digitStart = re(#"([A-Za-z])(\d)"#)
    private static let splitter = re(#"[\s\-–:.,&!_]+"#)
    private static let shortNumber = re(#"^\d{1,3}$"#)

    private static func sub(_ r: NSRegularExpression, _ s: String, _ with: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    /// web cartTitle: the name without its extension, dump tags, release
    /// number or trailing article.
    static func title(_ fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        var s = stem.isEmpty ? fileName : stem
        s = sub(tags, s, "")
        s = sub(number, s, "")
        s = sub(article, s, "$2 $1")
        s = sub(spaces, s.replacingOccurrences(of: "_", with: " "), " ")
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? fileName : s
    }

    private static let smallWords: Set<String> = ["the", "a", "an", "of", "and", "version", "edition"]
    /// No V or X: "Mega Man X" is not the tenth.
    private static let roman: [String: Int] = ["ii": 2, "iii": 3, "iv": 4, "vi": 6, "vii": 7, "viii": 8, "ix": 9]

    /// web cartLabelFor.
    static func label(_ fileName: String) -> String {
        let bare = title(fileName).replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        // One run with no spaces is split where its capitals and digits start.
        let hasGap = bare.contains { $0.isWhitespace || $0 == "_" }
        let src = hasGap ? bare : sub(digitStart, sub(camel, bare, "$1 $2"), "$1 $2")
        let ns = src as NSString
        var words: [String] = []
        var last = 0
        for m in splitter.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
            words.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        words.append(ns.substring(from: last))
        words = words.filter { !$0.isEmpty }

        var num = ""
        if words.count > 1 {
            for i in 1..<words.count {
                let w = words[i].lowercased()
                let isNum = shortNumber.firstMatch(in: w, range: NSRange(w.startIndex..., in: w)) != nil
                if isNum || roman[w] != nil {
                    num = isNum ? w : String(roman[w]!)
                    words.remove(at: i)
                    break
                }
            }
        }
        var sig = words.filter { !smallWords.contains($0.lowercased()) }
        if sig.isEmpty { sig = words }
        guard !sig.isEmpty else { return "" }
        if sig.count == 1 {
            let c = Array(sig[0])
            let first = c.first.map { String($0).uppercased() } ?? ""
            let second = c.count > 1 ? String(c[1]).lowercased() : ""
            return first + second + num
        }
        return sig.prefix(2).map { String($0.first!).uppercased() }.joined() + num
    }
}

/// The cartridge itself (web .lib-cart): a GBA cart wide, a Game Boy one
/// tall with its corner cut, the mark on its label. Sized off the picture
/// box it stands in (`boxWidth`), so one view serves a tile, the hero and
/// the tile menu's head.
struct CartridgeView: View {
    @Environment(\.palette) var palette
    let entry: RomEntry
    let boxWidth: CGFloat

    var body: some View {
        let gba = entry.isGBA, ds = entry.isNDS
        // web .cart-ds: small and nearly square (33:35), 28% of the box.
        let w = boxWidth * (gba ? 0.40 : ds ? 0.28 : 0.25)
        let h = gba ? w * 5 / 8 : ds ? w * 35 / 33 : w * 6 / 5
        let labelFont = gba ? min(22, max(9, boxWidth * 0.054)) : min(20, max(8, boxWidth * 0.046))
        let (top, bottom, labelBg): (Color, Color, Color) = {
            switch entry.system {
            case "GBA": return (palette.cartGbaTop, palette.cartGbaBottom, palette.badgeGbaFg)
            case "GBC": return (palette.cartGbcTop, palette.cartGbcBottom, palette.badgeGbcFg)
            case "DS": return (palette.cartDsTop, palette.cartDsBottom, palette.badgeDsFg)
            default: return (palette.cartGbTop, palette.cartGbBottom, palette.badgeGbFg)
            }
        }()
        let shape = CartShape(gba: gba, ds: ds)
        ZStack(alignment: .top) {
            shape.fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            // inset 0 1px 0 highlight
            shape.stroke(Color.white.opacity(0.16), lineWidth: 1)
                .mask(VStack { Rectangle().frame(height: 2); Spacer() })
            Text(CartLabel.label(entry.fileName))
                .font(.system(size: labelFont, weight: .heavy, design: .monospaced))
                .tracking(labelFont * 0.06)
                .foregroundColor(Color(red: 10 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: w * (gba ? 0.64 : ds ? 0.78 : 0.76), height: h * (gba ? 0.50 : ds ? 0.46 : 0.48))
                .background(RoundedRectangle(cornerRadius: 4).fill(labelBg))
                .padding(.top, gba ? boxWidth * 0.05 : ds ? w * 0.08 : boxWidth * 0.07)
        }
        .frame(width: w, height: h)
        .clipShape(shape)
        .shadow(color: gba ? .black.opacity(0.4) : .clear, radius: 11, y: 10)
        .accessibilityHidden(true)
    }
}

/// web .lib-cart's outline: rounded, the bottom corners tighter on a GBA
/// cart; a Game Boy cart rounded at the foot with its top-right corner cut;
/// a DS card the same cut smaller (web .cart-ds clip-path: 84% across,
/// 12% down).
struct CartShape: Shape {
    var gba: Bool
    var ds = false

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        if ds {
            let rt = w * 0.06, rb = w * 0.08
            p.move(to: CGPoint(x: r.minX + rt, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + w * 0.84, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.12))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rb))
            p.addQuadCurve(to: CGPoint(x: r.maxX - rb, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + rb, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rb), control: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + rt))
            p.addQuadCurve(to: CGPoint(x: r.minX + rt, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        } else if gba {
            let rt = w * 0.10, rb = w * 0.06
            p.move(to: CGPoint(x: r.minX + rt, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - rt, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + rt), control: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rb))
            p.addQuadCurve(to: CGPoint(x: r.maxX - rb, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + rb, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rb), control: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + rt))
            p.addQuadCurve(to: CGPoint(x: r.minX + rt, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        } else {
            let rt = w * 0.04, rb = w * 0.10
            p.move(to: CGPoint(x: r.minX + rt, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + w * 0.8, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.14))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rb))
            p.addQuadCurve(to: CGPoint(x: r.maxX - rb, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + rb, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rb), control: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + rt))
            p.addQuadCurve(to: CGPoint(x: r.minX + rt, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        }
        p.closeSubpath()
        return p
    }
}

/// A system chip (web .sys-chip.badge-*): "GBA", "GBC", "GB" or "DS".
struct SysChip: View {
    @Environment(\.palette) var palette
    let system: String
    var height: CGFloat = 24

    var body: some View {
        let b = palette.badge(system)
        Text(system)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.27)
            .foregroundColor(b.fg)
            .frame(width: 34, height: height)
            .background(RoundedRectangle(cornerRadius: 5).fill(b.bg))
    }
}
