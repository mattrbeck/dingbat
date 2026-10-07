// The home screen (web #home; docs/home-screen.md). A fresh visit opens on
// the brand with the whole library under it; once a game is played this
// visit it heads the page as the hero, paused or closed, and its tile
// stands down from the grid. Scrolling hands the brand to the home bar.
import SwiftUI
import UniformTypeIdentifiers

/// The web's --brand-p: 0 while the big brand is in view, 1 once it has
/// gone under the bar. Its own object, so a scroll redraws only the bar.
final class BrandProgress: ObservableObject {
    @Published var p: CGFloat = 0
}

private struct BrandFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: RomLibrary
    @EnvironmentObject var session: GameSession
    @Environment(\.palette) var palette

    @StateObject private var brand = BrandProgress()
    @State private var filter = LibFilter()
    @State private var sort = LibFilter.Sort.saved
    @State private var importing = false

    /// The search / chips / sort bar shows from this many games (web
    /// LIB_BAR_MIN), or while a filter is running so it can be cleared.
    static let libBarMin = 9

    /// The hero's game, while it is still in the library.
    private var hero: RomEntry? {
        guard let h = model.heroGame, library.entries.contains(h) else { return nil }
        return h
    }

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size.width
            let wide = viewport >= 760
            VStack(spacing: 0) {
                HomeBar(brand: brand, pinned: hero != nil, viewport: viewport) {
                    scrollToTop?()
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        content(viewport: viewport, wide: wide)
                            .padding(24)
                            .frame(maxWidth: .infinity)
                            .id("home-top")
                    }
                    .coordinateSpace(name: "home")
                    .scrollDismissesKeyboard(.immediately)
                    .onPreferenceChange(BrandFrameKey.self) { r in
                        // 0 while the brand is fully in view, 1 once it has
                        // gone completely under the bar.
                        let p = r.height > 0 ? min(1, max(0, -r.minY / r.height)) : 0
                        if abs(p - brand.p) > 0.001 { brand.p = p }
                    }
                    .onAppear {
                        scrollToTop = { withAnimation { proxy.scrollTo("home-top", anchor: .top) } }
                    }
                }
            }
            .background(palette.homeBg.ignoresSafeArea())
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.gbaRom, .gbRom, .gbcRom, .zip, .data],
                      allowsMultipleSelection: false) { result in
            importPicked(result)
        }
        .onChange(of: sort) { s in LibFilter.Sort.saved = s }
    }

    @State private var scrollToTop: (() -> Void)?

    // MARK: content

    @ViewBuilder
    private func content(viewport: CGFloat, wide: Bool) -> some View {
        let inner = max(0, viewport - 48)
        let entries = library.entries
        let hero = self.hero
        let solo = hero != nil && entries.count == 1
        let filtering = filter.active
        // The hero's game is shown once: its tile stands down unless a search
        // or filter is running (asked for by name, it must be found).
        let gridRows = LibFilter.sorted(entries, by: sort)
            .filter { filter.matches($0) && (filtering || $0 != hero) }
        let cells = entries.count - (hero != nil ? 1 : 0)
        let layout = LibLayout(viewport: viewport, inner: inner, count: cells, underHero: hero != nil)

        VStack(spacing: 26) {
            if entries.isEmpty {
                brandBlock
                EmptyStart { importing = true }
            } else {
                if let hero {
                    HeroView(entry: hero, wide: wide, viewport: viewport, solo: solo)
                        .frame(maxWidth: solo ? .infinity : layout.width, alignment: solo ? .center : .leading)
                        .frame(maxWidth: .infinity)
                    if solo {
                        AddPill { importing = true }
                    }
                } else {
                    brandBlock
                }
                if !solo {
                    library(rows: gridRows, layout: layout, wide: wide, underHero: hero != nil)
                }
            }
        }
        .frame(maxWidth: 1400)
    }

    private var brandBlock: some View {
        HomeBrand()
            .background(GeometryReader { g in
                Color.clear.preference(key: BrandFrameKey.self, value: g.frame(in: .named("home")))
            })
    }

    @ViewBuilder
    private func library(rows: [RomEntry], layout: LibLayout, wide: Bool, underHero: Bool) -> some View {
        let entries = library.entries
        let shown = entries.filter { filter.matches($0) }.count
        let total = entries.count
        let countText = shown == total ? "\(total) \(total == 1 ? "game" : "games")" : "\(shown) of \(total)"
        let counts = entries.reduce(into: [String: Int]()) { $0[$1.system, default: 0] += 1 }
        let systems = ["GBA", "GBC", "GB"].filter { (counts[$0] ?? 0) > 0 }

        VStack(spacing: 0) {
            LibraryHead(countText: countText, underHero: underHero) { importing = true }
                .frame(maxWidth: layout.width)
            let columns = Array(repeating: GridItem(.fixed(layout.track), spacing: layout.gap, alignment: .top),
                                count: layout.fit)
            // On phones the bar sticks under the top bar while the grid
            // scrolls, full-bleed over the tiles passing under it.
            LazyVStack(spacing: 0, pinnedViews: wide ? [] : [.sectionHeaders]) {
                Section {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: layout.gap) {
                        ForEach(rows) { e in
                            LibraryTile(entry: e, pictureGen: library.pictureGen).id(e.id)
                        }
                    }
                    // The tracks centre in the block; under a hero on a wide
                    // screen they start at the hero's left edge instead.
                    .frame(width: layout.tracksWidth)
                    .frame(width: underHero && wide ? layout.width : nil,
                           alignment: underHero && wide ? .leading : .center)
                } header: {
                    if total >= Self.libBarMin || filter.active {
                        if wide {
                            LibraryBar(filter: $filter, sort: $sort, systems: systems, counts: counts, wide: true)
                                .frame(maxWidth: layout.width)
                                .padding(.bottom, 12)
                        } else {
                            LibraryBar(filter: $filter, sort: $sort, systems: systems, counts: counts, wide: false)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 24)
                                .background(palette.stage.opacity(0.86))
                                .background(.ultraThinMaterial)
                                .padding(.horizontal, -24)
                                .padding(.bottom, 10)
                        }
                    }
                }
            }
            if rows.isEmpty && filter.active {
                Text("No games match.")
                    .font(.system(size: 13))
                    .foregroundColor(palette.textFaint)
                    .frame(maxWidth: layout.width)
                    .padding(.vertical, 28)
                    .padding(.horizontal, 12)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(palette.border2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: systems) { present in
            // A system that left the library leaves the filter too.
            filter.systems.formIntersection(present)
        }
    }

    // MARK: import

    /// web openRomPicker → addRecentRom → loadRom: a newly added game boots
    /// from its save (then offers its session).
    private func importPicked(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let err) = result { model.toast(err.localizedDescription, duration: 4) }
            return
        }
        do {
            let e = try library.importRom(from: url)
            model.launch(e, resume: false)
        } catch {
            model.toast(error.localizedDescription, duration: 4)
        }
    }
}

// MARK: - Brand

/// The big brand (web #home-brand): logo, wordmark and slogan.
struct HomeBrand: View {
    @Environment(\.palette) var palette

    var body: some View {
        VStack(spacing: 0) {
            Image("Logo")
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(width: 76)
                .shadow(color: .black.opacity(palette.isLight ? 0.25 : 0.6), radius: 7, y: 4)
                .padding(.bottom, 14)
            Text("dingbat")
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.3)
                .foregroundColor(palette.text)
            Text("a game boy & game boy advance emulator")
                .font(.system(size: 13.5))
                .foregroundColor(palette.textFaint)
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }
}

/// The empty library's way in (web #home-start on a touch screen: only the
/// button and the hint).
struct EmptyStart: View {
    @Environment(\.palette) var palette
    let add: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: add) {
                Text("Add a game")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(palette.accentInk)
                    .padding(.horizontal, 30)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(LinearGradient(colors: [palette.accent2, palette.accent],
                                                              startPoint: .top, endPoint: .bottom)))
                    .overlay(Capsule().stroke(palette.accent.opacity(0.6), lineWidth: 1))
                    .shadow(color: palette.accentGlow, radius: 6, y: 2)
            }
            .buttonStyle(PressStyle())
            Text(".gba, .gb, .gbc or a .zip")
                .font(.system(size: 12))
                .foregroundColor(palette.textFaint)
        }
        .frame(maxWidth: 560)
    }
}

/// A quiet dashed pill under a hero that is the whole library (web
/// #home-solo-add): a second game is a thing to offer, not to push.
struct AddPill: View {
    @Environment(\.palette) var palette
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                Text("Add a game").font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(palette.textDim)
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .padding(.vertical, 10)
            .overlay(Capsule().strokeBorder(palette.border2, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Bar

/// The top bar on the home screen (web #topbar, body:not(.running)): the
/// bar's copy of the brand, which the scroll fades in, then volume (with
/// its slider, which the in-game bar on a phone gives up) and Settings.
struct HomeBar: View {
    @ObservedObject var brand: BrandProgress
    @Environment(\.palette) var palette
    @EnvironmentObject var model: AppModel
    /// A hero is up: the big brand is gone, so the bar's is fully there.
    let pinned: Bool
    let viewport: CGFloat
    let toTop: () -> Void

    var body: some View {
        let p = pinned ? 1 : brand.p
        let wide = viewport >= 760
        ZStack {
            HStack(spacing: viewport <= 560 ? 4 : 8) {
                if !wide { brandButton(p) }
                Spacer(minLength: 4)
                VolumeControl(showSlider: true, sliderWidth: viewport <= 560 ? 64 : 96)
                BarIconButton(system: "gearshape", label: "Settings") {
                    model.openSheet(.settings(section: nil))
                }
            }
            // Wide screens centre it.
            if wide { brandButton(p) }
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(
            LinearGradient(colors: [palette.topbarTop, palette.topbarBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
        .overlay(Rectangle().fill(palette.frameLine).frame(height: 1), alignment: .bottom)
    }

    private func brandButton(_ p: CGFloat) -> some View {
        Button(action: toTop) {
            HStack(spacing: 8) {
                Image("Logo")
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22)
                // Under 360 points the wordmark gives way and the bat stays.
                if viewport >= 360 {
                    Text("dingbat")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(palette.chromeInk)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .opacity(p)
            .offset(y: (1 - p) * 7)
        }
        .buttonStyle(.plain)
        // Opacity 0 still takes a tap: inert until the brand is there.
        .allowsHitTesting(p > 0.5)
        .accessibilityHidden(p < 0.5)
        .accessibilityLabel("Back to the top")
    }
}
