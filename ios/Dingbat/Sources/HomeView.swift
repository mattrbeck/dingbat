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

    @ObservedObject private var link = NetLink.shared

    /// The hero's game, while it is still in the library. None while a
    /// link or 2P session holds the game (web drawPausedHero): Resume
    /// game stands in for it.
    private var hero: RomEntry? {
        guard !model.sessionBusy, let h = model.heroGame, library.entries.contains(h) else { return nil }
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
                    .padScrollFollow(proxy)
                }
            }
            .background(palette.homeBg.ignoresSafeArea())
        }
        .environment(\.padScope, "home")
        .onAppear {
            // The one-time offer, once a first Drive pull has had a moment
            // to bring pictures down (not in scripted test launches).
            let args = ProcessInfo.processInfo.arguments
            guard !args.contains("-autoplay"), !args.contains("-sheet") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { AddPictures.shared.maybeOffer() }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.gbaRom, .gbRom, .gbcRom] + (Settings.dsBetaOn ? [.ndsRom] : []) + [.zip, .data],
                      allowsMultipleSelection: false) { result in
            importPicked(result)
        }
        .onChange(of: sort) { s in LibFilter.Sort.saved = s }
        .background(EmptyView().fileImporter(isPresented: Binding(get: { model.relinking != nil },
                                                                  set: { if !$0 { model.relinking = nil } }),
                                             allowedContentTypes: [.gbaRom, .gbRom, .gbcRom] + (Settings.dsBetaOn ? [.ndsRom] : []) + [.data],
                                             allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first, let e = model.relinking {
                model.relink(e, to: url)
            }
            model.relinking = nil
        })
        .alert("A Different File", isPresented: Binding(get: { model.relinkConfirm != nil },
                                                         set: { if !$0 { model.relinkConfirm = nil } })) {
            Button("Cancel", role: .cancel) { model.relinkConfirm = nil }
            Button("Use It") {
                guard let c = model.relinkConfirm else { return }
                model.relinkConfirm = nil
                // Then the file check, as the web asks both in turn.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    Task { @MainActor in
                        guard await RomLibrary.confirmSuspect(c.bytes, name: c.entry.fileName, ext: c.entry.ext) else { return }
                        model.finishRelink(c.entry, c.bytes)
                    }
                }
            }
        } message: {
            Text("That file isn't the size this game's was. Its save may not work with it. Use it anyway?")
        }
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
        let _ = padGrid(gridRows, cols: layout.fit)

        VStack(spacing: 26) {
            if entries.isEmpty {
                brandBlock
                EmptyStart { importing = true }
                HomeDriveRow()
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
                    if model.sessionBusy { ResumeSessionButton() }
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
        let systems = ["GBA", "GBC", "GB", "DS"].filter { (counts[$0] ?? 0) > 0 }

        VStack(spacing: 0) {
            LibraryHead(countText: countText, underHero: underHero) { importing = true }
                .frame(maxWidth: layout.width)
                .homeRise(0.28)
            let columns = Array(repeating: GridItem(.fixed(layout.track), spacing: layout.gap, alignment: .top),
                                count: layout.fit)
            // On phones the bar sticks under the top bar while the grid
            // scrolls, full-bleed over the tiles passing under it.
            LazyVStack(spacing: 0, pinnedViews: wide ? [] : [.sectionHeaders]) {
                Section {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: layout.gap) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                            LibraryTile(entry: e, pictureGen: library.pictureGen)
                                .homeRise(0.32 + 0.04 * Double(min(i, 4)))
                        }
                    }
                    // The tracks centre in the block; under a hero on a wide
                    // screen they start at the hero's left edge instead.
                    .frame(width: layout.tracksWidth)
                    .frame(width: underHero && wide ? layout.width : nil,
                           alignment: underHero && wide ? .leading : .center)
                } header: {
                    Group {
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
                    .homeRise(0.28)
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

    // MARK: controller

    /// The grid is lazy: a step past the last tile laid out goes by index
    /// (the scroll then brings it in). LB/RB step the system filter, LT/RT
    /// the sort (web gamepad home).
    private func padGrid(_ rows: [RomEntry], cols: Int) {
        let nav = PadNav.shared
        let ids = rows.map { "tile:" + $0.id }
        nav.edge["home"] = { id, dir in
            guard let i = ids.firstIndex(of: id) else { return nil }
            let j: Int
            switch dir {
            case .down: j = i + cols
            case .up: j = i - cols
            case .right: j = i + 1
            case .left: j = i - 1
            }
            return ids.indices.contains(j) ? ids[j] : nil
        }
        let counts = Set(library.entries.map(\.system))
        let systems = ["GBA", "GBC", "GB", "DS"].filter { counts.contains($0) }
        nav.homeFilter = { step in
            let opts: [String?] = [nil] + systems
            let cur: String? = filter.systems.count == 1 ? filter.systems.first : nil
            let i = opts.firstIndex(where: { $0 == cur }) ?? 0
            let next = opts[(i + step + opts.count) % opts.count]
            filter.systems = next.map { [$0] } ?? []
        }
        nav.homeSort = { step in
            let all = LibFilter.Sort.allCases
            let i = all.firstIndex(of: sort) ?? 0
            sort = all[(i + step + all.count) % all.count]
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
        Task { @MainActor in
            do {
                let e = try await library.importRom(from: url)
                model.launch(e, resume: false)
            } catch RomLibrary.ImportError.declined {
            } catch {
                model.toast(error.localizedDescription, duration: 4)
            }
        }
    }
}

// MARK: - Brand

/// The big brand (web #home-brand): logo, wordmark and slogan.
struct HomeBrand: View {
    @Environment(\.palette) var palette
    @ObservedObject private var intro = LaunchIntro.shared

    var body: some View {
        VStack(spacing: 0) {
            Image("Logo")
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(width: 76)
                // The opening's logo lands here (LaunchIntro).
                .background(GeometryReader { g in
                    let r = g.frame(in: .global)
                    Color.clear
                        .onAppear { intro.brandAt(r) }
                        .onChange(of: r) { intro.brandAt($0) }
                })
                .opacity(intro.hidesBrand ? 0 : 1)
                .shadow(color: .black.opacity(palette.isLight ? 0.25 : 0.6), radius: 7, y: 4)
                .padding(.bottom, 14)
            VStack(spacing: 0) {
                Text("dingbat")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.3)
                    .foregroundColor(palette.text)
                Text("a game boy & game boy advance emulator")
                    .font(.system(size: 13.5))
                    .foregroundColor(palette.textFaint)
                    .padding(.top, 6)
            }
            // After the opening's bat has flown up past them.
            .homeRise(0.8)
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
/// web #home-resume: back to a session the hero cannot draw (an online
/// link, local 2P).
struct ResumeSessionButton: View {
    @Environment(\.palette) var palette

    var body: some View {
        Button { AppModel.shared.resumeFromHero() } label: {
            HStack(spacing: 9) {
                Image(systemName: "play.fill").font(.system(size: 15))
                Text("Resume game").font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(palette.accentInk)
            .padding(.horizontal, 24)
            .padding(.vertical, 11)
            .background(Capsule().fill(LinearGradient(colors: [palette.accent2, palette.accent],
                                                      startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().stroke(palette.accent.opacity(0.6), lineWidth: 1))
            .shadow(color: palette.accentGlow, radius: 12, y: 8)
        }
        .buttonStyle(PressStyle())
        .padFocus("home-resume", radius: 22) { AppModel.shared.resumeFromHero() }
    }
}

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
                AccountButton()
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
