import SwiftUI

/// dingbat Supporter: a swipeable card per extra, three prices that all
/// unlock the same things, and a thank-you once bought. Opened from the
/// banner at the top of Settings and from every locked row (on its card).
struct SupporterView: View {
    /// Nil: the app's sheet (SheetNav.close). Over Settings: back to it.
    var onClose: (() -> Void)?
    @ObservedObject private var store = Supporter.shared
    @ObservedObject private var icons = AppIconManager.shared
    @Environment(\.palette) private var palette
    @State private var slide = Supporter.shared.sheetCard.rawValue
    @State private var held = false
    @State private var tier = 1
    @State private var failure: String?
    @State private var note: String?
    @Environment(\.verticalSizeClass) private var vClass
    private let timer = Timer.publish(every: 3.8, on: .main, in: .common).autoconnect()

    /// A short screen (iPhone mini, SE) or a short sheet (an iPad window):
    /// smaller hero and card, so the card's page dots sit above the price bar.
    private var compact: Bool {
        UIScreen.main.bounds.height < 860 || vClass == .compact || (height > 0 && height < 760)
    }
    @State private var height: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            if store.unlocked { thanks } else { offer }
            topBar
        }
        .foregroundColor(palette.text)
        .background(palette.surface1.ignoresSafeArea())
        .background(GeometryReader { g in
            Color.clear.onAppear { height = g.size.height }.onChange(of: g.size.height) { height = $0 }
        })
        // A controller starts on the buy button, or on Done once bought
        // ("supporter" is both the sheet's own scope and its pane in Settings).
        .onAppear { preferFocus() }
        .onChange(of: store.unlocked) { _ in preferFocus() }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func close() { (onClose ?? SheetNav.close)() }

    private func preferFocus() {
        PadNav.shared.preferred["supporter"] = store.unlocked ? "supporter:done" : "supporter:buy"
    }

    private var topBar: some View {
        HStack {
            GlassButton(label: "Close", action: close) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
            }
            .padFocus("supporter:close", radius: 22, press: close)
            Spacer()
            if !store.unlocked {
                GlassButton(label: "Restore purchase", wide: true, action: restore) {
                    Text("Restore").font(.system(size: 15, weight: .semibold))
                }
                .padFocus("supporter:restore", radius: 22, press: restore)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func restore() {
        Task {
            if await !store.restore() { failure = "No Supporter purchase was found for this Apple Account." }
        }
    }

    // MARK: offer

    private var offer: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image("LogoCrown").interpolation(.none).resizable().scaledToFit().frame(width: compact ? 84 : 112)
                    .accessibilityHidden(true)
                    .padding(.top, compact ? 54 : 62)
                Text("Support dingbat")
                    .font(.system(size: compact ? 26 : 30, weight: .bold, design: .rounded))
                    .padding(.top, 10)
                Text("Core features are always free. Supporters get some extra fun perks.")
                    .font(.system(size: 15))
                    .foregroundColor(palette.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                carousel.padding(.top, compact ? 12 : 16)
                dots
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .safeAreaInset(edge: .bottom) { buyBar }
        .onReceive(timer) { _ in
            guard !held else { return }
            withAnimation(.easeInOut(duration: 0.35)) { slide = (slide + 1) % Perk.all.count }
        }
    }

    private var carousel: some View {
        TabView(selection: $slide) {
            ForEach(Perk.all.indices, id: \.self) { i in PerkCard(perk: Perk.all[i]).tag(i) }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: compact ? 272 : 300)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(palette.border, lineWidth: 1))
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in held = true })
        .padFocus("supporter:cards", radius: 23, adjust: { d in step(d) }) { step(1) }
    }

    /// A controller pages the cards: left/right, or A for the next.
    private func step(_ d: Int) {
        held = true
        let n = Perk.all.count
        withAnimation(.easeInOut(duration: 0.3)) { slide = (slide + d + n) % n }
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
                        .frame(width: 26, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show " + Perk.all[i].title)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: slide)
    }

    private var buyBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let on = tier == i
                    Button { tier = i } label: {
                        Text(store.price(i))
                            .font(.system(size: 15, weight: on ? .bold : .medium))
                            .foregroundColor(palette.text)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(Capsule().fill(on ? Color.white.opacity(0.2) : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(store.price(i)), \(Supporter.tierNames[i])")
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .padFocus("supporter:tier\(i)", radius: 16) { tier = i }
                }
            }
            .padding(3)
            .background(Capsule().fill(Color(red: 118 / 255, green: 118 / 255, blue: 128 / 255).opacity(0.24)))
            Button(action: buy) {
                ZStack {
                    Text("Support for \(store.price(tier))").opacity(store.busy ? 0 : 1)
                    if store.busy { ProgressView().tint(palette.accentInk) }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(palette.accentInk)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Capsule().fill(palette.accent))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.busy)
            .padding(.top, 12)
            .padFocus("supporter:buy", radius: 27, press: buy)
            if let note {
                Text(note).font(.system(size: 13)).foregroundColor(palette.textDim).padding(.top, 8)
            }
            Text("One-time purchase · Every price unlocks everything")
                .font(.system(size: 12)).foregroundColor(palette.textFaint)
                .padding(.top, 8)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
    }

    private func buy() {
        note = nil
        Task {
            switch await store.buy(tier: tier) {
            case .purchased: UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .pending: note = "Waiting for approval. Everything unlocks as soon as it's approved."
            case .cancelled: break
            case .failed(let why): failure = why
            }
        }
    }

    // MARK: thanks

    private var thanks: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image("LogoCrown").interpolation(.none).resizable().scaledToFit()
                    .frame(width: 150)
                    .accessibilityHidden(true)
                    .padding(.top, 84)
                Text("Thank you!")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .padding(.top, 10)
                Text("Everything is unlocked here and on your other devices with the same Apple Account.")
                    .font(.system(size: 15))
                    .foregroundColor(palette.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                VStack(spacing: 0) {
                    next("Choose a theme", icon: AppIconChoice.classic[0].preview, pane: .appearance)
                    divider
                    next("Choose an app icon", icon: "IconPreview-dusk", pane: .appIcon)
                    divider
                    next("Turn on holiday icons", icon: "IconPreview-h-witch", pane: .appIcon)
                    divider
                    next("Make a Game Boy palette", icon: "IconPreview-paper", pane: .gb)
                }
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(palette.surface2))
                .padding(.top, 24)
                Button(action: close) {
                    Text("Done")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(palette.accentInk)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Capsule().fill(palette.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
                .padFocus("supporter:done", radius: 27, press: close)
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var divider: some View {
        Rectangle().fill(palette.border).frame(height: 0.5).padding(.leading, 58)
    }

    private func next(_ label: String, icon: String, pane: SettingsPane) -> some View {
        let overSettings = onClose != nil
        let go = {
            if overSettings {
                Supporter.shared.jumpTo = pane
                Supporter.shared.sheetUp = false
            } else {
                SettingsNav.shared.open(pane)
                AppModel.shared.openSheet(.settings(section: nil))
            }
        }
        return Button(action: go) {
            HStack(spacing: 12) {
                Image(icon).interpolation(.none).resizable().frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(label).font(.system(size: 17))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(palette.textFaint)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padFocus("supporter:next:" + label, press: go)
    }
}

/// A round (or capsule) glass button over the sheet.
private struct GlassButton<Label: View>: View {
    let label: String
    var wide = false
    let action: () -> Void
    @ViewBuilder var content: () -> Label
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            content()
                .foregroundColor(palette.text)
                .frame(width: wide ? nil : 44, height: 44)
                .padding(.horizontal, wide ? 16 : 0)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}


// MARK: - The cards (in Supporter.Perk order)

private struct Perk {
    let perk: Supporter.Perk
    let title: String
    let desc: String
    var soon = false

    static let all: [Perk] = [
        Perk(perk: .themes, title: "Every theme", desc: "Amber, Pure Black, Light, DMG, Kiwi and more."),
        Perk(perk: .icons, title: "App icons", desc: "Classic bats, plus holiday ones that can switch by themselves."),
        Perk(perk: .crown, title: "A crown for your bat", desc: "Your friend sees it over the link cable."),
        Perk(perk: .palette, title: "Your own Game Boy colors", desc: "Pick all four shades of a custom palette."),
        Perk(perk: .filters, title: "Smooth filters", desc: "hq4x and xBR round off the pixel steps."),
        Perk(perk: .advanced, title: "Advanced features", desc: "DS support and the save webhook."),
        Perk(perk: .early, title: "Early access", desc: "Try new builds a week before they ship."),
        Perk(perk: .clips, title: "Clip studio", desc: "GIFs, sharper video, and five minutes to clip from."),
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
            .frame(height: 200)
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
        switch perk.perk {
        case .themes: ThemesArt()
        case .icons: IconsArt()
        case .palette: PaletteArt()
        case .filters: FiltersArt()
        case .early: EarlyArt()
        case .advanced: AdvancedArt()
        case .clips: ClipsArt()
        case .crown: CrownArt()
        }
    }
}

private func batImage(_ w: CGFloat) -> some View {
    Image("Logo").interpolation(.none).resizable().scaledToFit().frame(width: w)
}

private struct ThemesArt: View {
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 6), spacing: 10) {
            ForEach(ThemeName.allCases) { ThemeMini(theme: $0, width: 44) }
        }
    }
}

private struct IconsArt: View {
    private let ids = ["night-flyer", "dusk", "midnight", "paper", "ember", "h-witch", "h-snowy", "h-lunar", "h-valentine", "h-pride"]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 12), count: 5), spacing: 12) {
            ForEach(ids, id: \.self) { id in
                Image("IconPreview-" + id).interpolation(.none).resizable().frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    // The bat through the app's own shaders at 8x (PresentShader's upscale,
    // rendered offline): the wing tips, cropped close so the steps show.
    var body: some View {
        HStack(spacing: 8) {
            tile("Sharp · free", "sharp", bright: false)
            tile("hq4x", "hq4x", bright: true)
            tile("xBR", "xbr", bright: true)
        }
    }

    private func tile(_ label: String, _ name: String, bright: Bool) -> some View {
        VStack(spacing: 7) {
            Image("FilterPreview-" + name).interpolation(.none).resizable()
                .frame(width: 384 * 0.62, height: 200 * 0.62)
                .offset(x: 72)
                .frame(width: 98, height: 98)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(label).font(.system(size: 12)).foregroundColor(bright ? palette.text : palette.textDim)
        }
    }
}

private struct EarlyArt: View {
    @Environment(\.palette) private var palette
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.bg.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(palette.border, lineWidth: 1))
                .frame(width: 268, height: 76)
            HStack(spacing: 12) {
                Image("IconPreview-night-flyer").interpolation(.none).resizable().frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.bg))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(palette.border2, lineWidth: 1))
            .padding(.top, 16)
        }
        .frame(height: 110)
    }
}

private struct AdvancedArt: View {
    @Environment(\.palette) private var palette
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("DS support").font(.system(size: 15))
                BadgeView(badge: .highlyExperimental)
                Spacer(minLength: 0)
                Capsule().fill(palette.accent).frame(width: 44, height: 27)
                    .overlay(Circle().fill(.white).padding(2), alignment: .trailing)
            }
            .padding(.horizontal, 14).frame(height: 52)
            Rectangle().fill(palette.border).frame(height: 0.5).padding(.leading, 14)
            HStack {
                Text("Save webhook").font(.system(size: 15))
                Spacer()
                Text("example.com/saves").font(.system(size: 13, design: .monospaced)).foregroundColor(palette.textFaint)
            }
            .padding(.horizontal, 14).frame(height: 52)
        }
        .frame(width: 296)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.surface2))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(palette.border, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// The clip as it would land in Messages: a GIF of the game, looping.
private struct ClipsArt: View {
    @Environment(\.palette) private var palette
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color(hex: 0xE6DEFC)
                FlappingBat().frame(width: 156, height: 84)
            }
            .frame(width: 192, height: 120)
            .overlay(alignment: .topLeading) { tag("GIF", bold: true).padding(8) }
            .overlay(alignment: .bottomTrailing) { tag("0:06").padding(8) }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 26, height: 26).background(Circle().fill(Color(hex: 0x0E0A16).opacity(0.78))).padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
            HStack(spacing: 6) {
                chip("GIF export")
                chip("Sharper clips")
                chip("Longer clips")
            }
        }
    }

    private func tag(_ t: String, bold: Bool = false) -> some View {
        Text(t).font(.system(size: 11, weight: bold ? .heavy : .semibold)).foregroundColor(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x0E0A16).opacity(0.78)))
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold))
            .foregroundColor(palette.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(palette.surface3))
    }
}

/// The link transfer screen in small: your bat crowned, your friend's not.
private struct CrownArt: View {
    @Environment(\.palette) private var palette
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            end("FlapCrown", "You", crowned: true)
            Path { p in
                p.move(to: CGPoint(x: 2, y: 20))
                p.addCurve(to: CGPoint(x: 62, y: 20), control1: CGPoint(x: 18, y: 34), control2: CGPoint(x: 46, y: 6))
            }
            .stroke(palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 64, height: 40)
            .padding(.bottom, 30)
            end("FlapDusk", "Your friend", crowned: false)
        }
    }

    private func end(_ image: String, _ name: String, crowned: Bool) -> some View {
        VStack(spacing: 6) {
            FlappingBat(image: image).frame(width: 104, height: crowned ? 66 : 56)
            Text(name).font(.system(size: 12, weight: .semibold)).foregroundColor(palette.textDim)
        }
    }
}
