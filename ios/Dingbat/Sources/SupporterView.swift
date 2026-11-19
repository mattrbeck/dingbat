import SwiftUI

/// Become a Supporter: a swipeable card per extra, three prices that all
/// unlock the same things, and a thank-you once bought. Opened from the top
/// of Settings and from the teaser rows where a supporter option is hidden.
struct SupporterView: View {
    /// Nil: the app's sheet (SheetNav.close). Over Settings: back to it.
    var onClose: (() -> Void)?
    @ObservedObject private var store = Supporter.shared
    @Environment(\.palette) private var palette
    @State private var slide = 0
    @State private var held = false
    @State private var tier = 1
    @State private var failure: String?
    @State private var note: String?
    private let timer = Timer.publish(every: 3.8, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                Group {
                    if store.unlocked { thanks } else { offer }
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            SheetCloseButton(action: close).padding(.top, 10).padding(.trailing, 12)
        }
        .foregroundColor(palette.text)
        .background(palette.surface1.ignoresSafeArea())
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func close() { (onClose ?? SheetNav.close)() }

    // MARK: offer

    private var offer: some View {
        VStack(spacing: 0) {
            bat(width: 126).padding(.top, 34)
            Text("Become a Supporter")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .padding(.top, 12)
            Text("dingbat stays free, link cable and all. Supporters keep it going and get a few extras as thanks.")
                .font(.system(size: 15))
                .foregroundColor(palette.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            carousel.padding(.top, 18)
            dots
            tiers.padding(.top, 4)
            buyButton.padding(.top, 14)
            if let note {
                Text(note).font(.system(size: 13)).foregroundColor(palette.textDim).padding(.top, 8)
            }
            Text("One-time purchase. Every tier unlocks the same extras. Shared with your family.")
                .font(.system(size: 12))
                .foregroundColor(palette.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Button("Restore purchase") {
                Task {
                    if await !store.restore() { failure = "No Supporter purchase was found for this Apple Account." }
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(palette.accent)
            .frame(minHeight: 44)
            .padFocus("supporter:restore") { Task { _ = await store.restore() } }
        }
        .onReceive(timer) { _ in
            guard !held else { return }
            withAnimation(.easeInOut(duration: 0.35)) { slide = (slide + 1) % Perk.all.count }
        }
    }

    private var carousel: some View {
        TabView(selection: $slide) {
            ForEach(Perk.all.indices, id: \.self) { i in
                PerkCard(perk: Perk.all[i]).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 270)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(palette.border, lineWidth: 1))
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in held = true })
    }

    private var dots: some View {
        HStack(spacing: 0) {
            ForEach(Perk.all.indices, id: \.self) { i in
                Button {
                    held = true
                    withAnimation(.easeInOut(duration: 0.3)) { slide = i }
                } label: {
                    Capsule()
                        .fill(i == slide ? palette.accent : palette.surface3)
                        .frame(width: i == slide ? 18 : 7, height: 7)
                        .frame(width: 28, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show " + Perk.all[i].title)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: slide)
    }

    private var tiers: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                let on = tier == i
                Button { tier = i } label: {
                    VStack(spacing: 2) {
                        Text(store.price(i)).font(.system(size: 18, weight: .bold))
                        Text(Supporter.tierNames[i]).font(.system(size: 12)).foregroundColor(palette.textDim)
                    }
                    .foregroundColor(palette.text)
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(on ? palette.accent.opacity(0.12) : palette.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(on ? palette.accent : palette.border, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(store.price(i)), \(Supporter.tierNames[i])")
                .accessibilityAddTraits(on ? .isSelected : [])
                .padFocus("supporter:tier\(i)", radius: 14) { tier = i }
            }
        }
    }

    private var buyButton: some View {
        Button(action: buy) {
            ZStack {
                Text("Support for \(store.price(tier))").opacity(store.busy ? 0 : 1)
                if store.busy { ProgressView().tint(palette.accentInk) }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(palette.accentInk)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.accent))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.busy)
        .padFocus("supporter:buy", radius: 16, press: buy)
    }

    private func buy() {
        note = nil
        Task {
            switch await store.buy(tier: tier) {
            case .purchased:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .pending:
                note = "Waiting for approval. The extras unlock as soon as it's approved."
            case .cancelled: break
            case .failed(let why): failure = why
            }
        }
    }

    // MARK: thanks

    private var thanks: some View {
        VStack(spacing: 0) {
            bat(width: 168).padding(.top, 70)
            SupporterPill().padding(.top, 18)
            Text("Thank you!")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .padding(.top, 12)
            Text("Every extra is unlocked here and on your other devices signed in to the same Apple Account.")
                .font(.system(size: 15))
                .foregroundColor(palette.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            VStack(spacing: 0) {
                next("Pick a theme", dot: Color(hex: 0x6EE126), section: "general")
                Rectangle().fill(palette.border).frame(height: 1)
                next("Make a Game Boy palette", dot: Color(hex: 0xFF8FB1), section: "gb")
                Rectangle().fill(palette.border).frame(height: 1)
                next("Try a smooth filter", dot: palette.accent, section: "video")
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.border, lineWidth: 1))
            .padding(.top, 28)
            Button(action: close) {
                Text("Done")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.surface3))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padFocus("supporter:done", radius: 16, press: close)
        }
    }

    private func next(_ label: String, dot: Color, section: String) -> some View {
        let overSettings = onClose != nil
        let go = {
            if overSettings {
                Supporter.shared.jumpTo = section
                Supporter.shared.sheetUp = false
            } else {
                AppModel.shared.openSheet(.settings(section: section))
            }
        }
        return Button(action: go) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8).fill(palette.surface3).frame(width: 30, height: 30)
                    .overlay(Circle().fill(dot).frame(width: 12, height: 12))
                Text(label).font(.system(size: 15, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(palette.textFaint)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padFocus("supporter:next:" + section, press: go)
    }

    private func bat(width: CGFloat) -> some View {
        Image("Logo").interpolation(.none).resizable().scaledToFit()
            .frame(width: width)
            .accessibilityHidden(true)
    }
}

/// The pink "Supporter" capsule (Settings, the thank-you, the link badge).
struct SupporterPill: View {
    var size: CGFloat = 12
    var body: some View {
        Text("Supporter")
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(Color(hex: 0xFF8FB1))
            .padding(.horizontal, size * 0.8)
            .padding(.vertical, size * 0.33)
            .background(Capsule().fill(Color(hex: 0xFF8FB1).opacity(0.16)))
    }
}

// MARK: - The extras

private struct Perk {
    enum Art { case themes, icons, palette, filters, clips, badge, early }
    let art: Art
    let title: String
    let desc: String
    /// Not built yet: the card says so.
    var soon = false

    static let all: [Perk] = [
        Perk(art: .themes, title: "Seven more themes", desc: "Kiwi, Atomic Purple, Indigo, Fuchsia, Glacier, Daiei and Famicom."),
        Perk(art: .icons, title: "App icons", desc: "Put a different bat on your Home Screen.", soon: true),
        Perk(art: .palette, title: "Your own Game Boy colors", desc: "Pick all four shades of a custom palette."),
        Perk(art: .filters, title: "More filters", desc: "Smooth upscalers (hq4x, xBR), and a CRT look soon."),
        Perk(art: .clips, title: "Clip studio", desc: "Export GIFs, and sharper, longer clips.", soon: true),
        Perk(art: .badge, title: "Supporter badge", desc: "Your link partner sees it beside your name.", soon: true),
        Perk(art: .early, title: "Early access", desc: "Try new builds before they ship."),
    ]
}

private struct PerkCard: View {
    let perk: Perk
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                art.frame(maxWidth: .infinity, maxHeight: .infinity)
                if perk.soon {
                    Text("Soon")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(palette.textDim)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(palette.surface3))
                        .padding(10)
                }
            }
            .frame(height: 182)
            .background(palette.surface2Lo)
            VStack(alignment: .leading, spacing: 3) {
                Text(perk.title).font(.system(size: 17, weight: .semibold))
                Text(perk.desc).font(.system(size: 14)).foregroundColor(palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .background(palette.surface2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var art: some View {
        switch perk.art {
        case .themes: ThemesArt()
        case .icons: IconsArt()
        case .palette: PaletteArt()
        case .filters: FiltersArt()
        case .clips: ClipsArt()
        case .badge: BadgeArt()
        case .early: EarlyArt()
        }
    }
}

private func batImage(_ w: CGFloat) -> some View {
    Image("Logo").interpolation(.none).resizable().scaledToFit().frame(width: w)
}

private struct ThemesArt: View {
    @Environment(\.palette) private var palette
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 6), count: 4), spacing: 12) {
            ForEach(ThemeName.allCases.filter(\.supporterOnly)) { t in
                VStack(spacing: 6) {
                    ZStack(alignment: .bottomTrailing) {
                        Circle().fill(Color(hex: t.swatch.0)).overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                        Circle().fill(Color(hex: t.swatch.1)).frame(width: 13, height: 13)
                            .overlay(Circle().stroke(palette.surface2Lo, lineWidth: 1.5)).padding(2)
                    }
                    .frame(width: 40, height: 40)
                    Text(t.label).font(.system(size: 11)).foregroundColor(palette.textDim).lineLimit(1).fixedSize()
                }
            }
        }
    }
}

private struct IconsArt: View {
    @Environment(\.palette) private var palette
    var body: some View {
        HStack(spacing: 14) {
            ForEach([("Night", 0x0E0A16), ("Ivory", 0xF1EEE8), ("Bubblegum", 0xFFB3C9), ("Pea Soup", 0xC9D9A0)], id: \.0) { name, ground in
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color(hex: UInt32(ground)))
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                        .overlay(batImage(46))
                        .frame(width: 62, height: 62)
                    Text(name).font(.system(size: 12)).foregroundColor(palette.textDim)
                }
            }
        }
    }
}

private struct PaletteArt: View {
    @Environment(\.palette) private var palette
    static let shades: [UInt32] = [0xFFE6EE, 0xFF8FB1, 0x7A4FC4, 0x1B1028]
    static let scene = [
        "0000000000000000", "0000000000011000", "0000000000111100", "0000000000111100",
        "0000000000011000", "0000000000000000", "0000111000000000", "0011111110001110",
        "1111111111111111", "2222222222222222", "2323232323232323", "3333333333333333",
    ]

    var body: some View {
        HStack(spacing: 18) {
            Canvas { ctx, _ in
                for (y, row) in Self.scene.enumerated() {
                    for (x, ch) in row.enumerated() {
                        let i = Int(String(ch)) ?? 0
                        ctx.fill(Path(CGRect(x: x * 8, y: y * 8, width: 8, height: 8)), with: .color(Color(hex: Self.shades[i])))
                    }
                }
            }
            .frame(width: 128, height: 96)
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0B0812)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.shades, id: \.self) { c in
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: c)).overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1)).frame(width: 22, height: 22)
                        Text(String(format: "#%06X", c)).font(.system(size: 12, design: .monospaced)).foregroundColor(palette.textDim)
                    }
                }
            }
        }
    }
}

private struct FiltersArt: View {
    @Environment(\.palette) private var palette
    var body: some View {
        HStack(spacing: 8) {
            tile("Sharp, free", bright: false) {
                batImage(84)
            }
            tile("xBR", bright: true) {
                Image("Logo").resizable().interpolation(.high).scaledToFit().frame(width: 84).blur(radius: 0.6)
            }
            tile("CRT", bright: true, ground: Color(hex: 0x2A2440)) {
                batImage(84).brightness(0.12).shadow(color: palette.accent.opacity(0.7), radius: 4)
                    .overlay(Canvas { ctx, size in
                        var y: CGFloat = 0
                        while y < size.height {
                            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.42)))
                            y += 3
                        }
                    })
            }
        }
    }

    private func tile<C: View>(_ label: String, bright: Bool, ground: Color = Color(hex: 0xE6DEFC),
                               @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ground)
                .overlay(content())
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(width: 98, height: 98)
            Text(label).font(.system(size: 12)).foregroundColor(bright ? palette.text : palette.textDim)
        }
    }
}

private struct ClipsArt: View {
    @Environment(\.palette) private var palette
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 5) {
                holes
                HStack(spacing: 6) {
                    ForEach([2.0, 9, 15, 7], id: \.self) { y in
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0xE6DEFC))
                            .overlay(alignment: .top) { batImage(42).padding(.top, y) }
                            .frame(height: 46).clipped()
                    }
                }
                holes
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(width: 296)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x0B0812)))
            ZStack(alignment: .leading) {
                Capsule().fill(palette.surface3).frame(height: 6)
                Rectangle().fill(palette.accent).frame(width: 170, height: 6).offset(x: 50)
                RoundedRectangle(cornerRadius: 4).fill(palette.text).frame(width: 12, height: 22).offset(x: 44)
                RoundedRectangle(cornerRadius: 4).fill(palette.text).frame(width: 12, height: 22).offset(x: 214)
            }
            .frame(width: 296, height: 22)
            HStack(spacing: 6) {
                chip("GIF", on: true)
                chip("4× MP4", on: false)
                chip("Up to 2 min", on: false)
            }
        }
    }

    private var holes: some View {
        HStack {
            ForEach(0..<14, id: \.self) { i in
                if i > 0 { Spacer(minLength: 0) }
                RoundedRectangle(cornerRadius: 1).fill(palette.surface3).frame(width: 8, height: 4)
            }
        }
    }

    private func chip(_ t: String, on: Bool) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold))
            .foregroundColor(on ? palette.accentInk : palette.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(on ? palette.accent : palette.surface3))
    }
}

private struct BadgeArt: View {
    @Environment(\.palette) private var palette
    var body: some View {
        HStack(spacing: 0) {
            player("You", sub: Text("Player 1").foregroundColor(palette.textFaint), color: palette.text, ring: palette.border)
            Line().stroke(palette.accent, style: StrokeStyle(lineWidth: 2, dash: [5, 4])).frame(width: 52, height: 2)
            player("Sam", sub: SupporterPill(size: 11), color: palette.peer, ring: palette.peer)
        }
    }

    private func player<S: View>(_ name: String, sub: S, color: Color, ring: Color) -> some View {
        VStack(spacing: 6) {
            Circle().fill(palette.surface3).frame(width: 44, height: 44).overlay(batImage(32))
            Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(color)
            sub.font(.system(size: 11))
        }
        .frame(width: 118, height: 120)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.bg))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ring, lineWidth: 1))
    }

    private struct Line: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            return p
        }
    }
}

private struct EarlyArt: View {
    @Environment(\.palette) private var palette
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.bg.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.border, lineWidth: 1))
                .frame(width: 268, height: 76)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.surface2Lo)
                    .overlay(batImage(38))
                    .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("dingbat beta").font(.system(size: 15, weight: .semibold))
                    Text("Next update, a week early").font(.system(size: 12)).foregroundColor(palette.textDim)
                }
                Spacer(minLength: 0)
                Text("Get").font(.system(size: 13, weight: .bold)).foregroundColor(palette.accentInk)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(palette.accent))
            }
            .padding(.horizontal, 14)
            .frame(width: 296, height: 80)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.bg))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.border2, lineWidth: 1))
            .padding(.top, 16)
        }
        .frame(height: 110)
    }
}

// MARK: - Settings entry points

/// Top of Settings: "Support dingbat" for everyone else, "You're a
/// Supporter" once bought. Opens the sheet over Settings.
struct SupporterSettingsRow: View {
    @ObservedObject private var store = Supporter.shared
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.bg)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.border, lineWidth: 1))
                    .overlay(batImage(40))
                    .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.unlocked ? "You're a Supporter" : "Support dingbat")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(palette.text)
                    Text(store.unlocked ? sinceText : "Themes, palettes, filters and more")
                        .font(.system(size: 12.5))
                        .foregroundColor(palette.textDim)
                }
                Spacer(minLength: 4)
                if store.unlocked { SupporterPill(size: 11) }
                else {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(palette.accent)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(store.unlocked ? palette.surface2 : palette.accent.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(store.unlocked ? palette.border : palette.accent.opacity(0.4), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padFocus("supporter:row", radius: 14, press: open)
    }

    private var sinceText: String {
        guard let d = store.since else { return "Thank you." }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return "Since \(f.string(from: d)). Thank you."
    }

    private func open() { Supporter.shared.sheetUp = true }
}

/// Where supporter options are hidden: one row that says what's there and
/// opens the sheet (e.g. "7 more themes" under the theme chips).
struct SupporterTeaser: View {
    let text: String
    var swatches: [UInt32] = []
    @ObservedObject private var store = Supporter.shared
    @Environment(\.palette) private var palette

    var body: some View {
        if !store.unlocked {
            Button(action: open) {
                HStack(spacing: 12) {
                    if !swatches.isEmpty {
                        HStack(spacing: -7) {
                            ForEach(swatches, id: \.self) { c in
                                Circle().fill(Color(hex: c)).frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(palette.surface1, lineWidth: 2))
                            }
                        }
                        .accessibilityHidden(true)
                    }
                    Text(text).font(.system(size: 12.5, weight: .semibold)).foregroundColor(palette.text)
                    Spacer(minLength: 4)
                    SupporterPill(size: 11)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.accent.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(palette.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows what Supporters get")
            .padFocus("supporter:teaser:" + text, press: open)
        }
    }

    private func open() { Supporter.shared.sheetUp = true }
}
