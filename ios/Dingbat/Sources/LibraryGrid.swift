// The library on the home screen (web #home-recent-wrap): its head, the
// search / chips / sort bar, the grid of tiles and the sums that size it.
import SwiftUI
import UIKit

// MARK: - Pictures

/// Pictures and per-game facts the home screen reads from disk, kept until
/// `RomLibrary.pictureGen` moves (every write of a picture, a session or a
/// save reset bumps it), so a scroll or a search never touches the disk.
final class HomePictures {
    static let shared = HomePictures()

    private var gen = -1
    private var pictures: [String: UIImage?] = [:]
    private var facts: [String: Bool] = [:]

    private func sync() {
        let g = RomLibrary.shared.pictureGen
        if g != gen {
            gen = g
            pictures.removeAll()
            facts.removeAll()
        }
    }

    /// The tile's or hero's picture: `preferSession` takes the session's own
    /// picture first (the closed hero), else the last screen.
    func picture(_ e: RomEntry, preferSession: Bool) -> UIImage? {
        sync()
        let key = (preferSession ? "s:" : "f:") + e.fileName
        if let hit = pictures[key] { return hit }
        let img = RomLibrary.shared.picture(for: e, preferSession: preferSession)
        pictures[key] = .some(img)
        return img
    }

    func art(_ e: RomEntry) -> UIImage? {
        sync()
        let key = "a:" + e.fileName
        if let hit = pictures[key] { return hit }
        let img = RomLibrary.shared.art(for: e)
        pictures[key] = .some(img)
        return img
    }

    /// A session that still counts (Resume on the closed hero).
    func hasSession(_ e: RomEntry) -> Bool {
        sync()
        let key = "s:" + e.fileName
        if let hit = facts[key] { return hit }
        let v = RomLibrary.shared.resumableSession(e) != nil
        facts[key] = v
        return v
    }
}

/// A picture box's content (web .home-tile-thumb): the last screen
/// (contain, on black), else box art (cover), else the cartridge on a field
/// tinted by its system.
struct GamePicture: View {
    @Environment(\.palette) var palette
    let entry: RomEntry
    var preferSession = false
    /// The hero's closed look: a picture of a game not in memory reads a
    /// little like a memory (web saturate(.75) brightness(.82)).
    var dimmed = false

    var body: some View {
        GeometryReader { geo in
            let pics = HomePictures.shared
            if let img = pics.picture(entry, preferSession: preferSession) {
                ZStack {
                    Color.black
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .modifier(Dim(on: dimmed))
                }
            } else if let art = pics.art(entry) {
                Image(uiImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .modifier(Dim(on: dimmed))
            } else {
                ZStack {
                    palette.badge(entry.system).bg
                    CartridgeView(entry: entry, boxWidth: geo.size.width)
                }
            }
        }
    }

    private struct Dim: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on {
                content.saturation(0.75).overlay(Color.black.opacity(0.18))
            } else {
                content
            }
        }
    }
}

// MARK: - Layout

/// web #home-inner's width sums: how many columns, how wide a track, how
/// wide the block (head, bar, hero) is. `viewport` decides the breakpoints
/// (the web's media queries), `inner` is the width inside the page padding.
struct LibLayout {
    let cols: Int
    let fit: Int
    let track: CGFloat
    let width: CGFloat
    let gap: CGFloat = 10
    /// A full row of tracks, the grid's own width.
    var tracksWidth: CGFloat { CGFloat(fit) * track + CGFloat(fit - 1) * gap }

    /// `count`: tiles on screen (the hero's stood-down tile is not a cell).
    init(viewport: CGFloat, inner: CGFloat, count: Int, underHero: Bool) {
        let cols: Int
        switch viewport {
        case ..<360: cols = 1
        case ..<640: cols = 2
        case ..<900: cols = 3
        case ..<1150: cols = 4
        case ..<1400: cols = 5
        default: cols = 6
        }
        let wide = viewport >= 760
        var floor: CGFloat = 460
        var tileMax: CGFloat = 300
        let n = max(1, count)
        var fit = cols
        if count <= 5 {
            // Each breakpoint narrows the block to the counts short of its
            // own capacity (web [data-n] rules).
            if n == 1 { fit = 1 }
            if wide && n == 2 { fit = 2; floor = min(inner, 780); tileMax = 520 }
            if wide && n == 3 { floor = min(inner, 1000); tileMax = 520 }
            if viewport >= 900 && n == 3 { fit = 3 }
            if viewport >= 1150 && n == 4 { fit = 4 }
            if viewport >= 1400 && n == 5 { fit = 5 }
            // Phones keep their columns under a hero, even for one game.
            if !wide && underHero && n == 1 { fit = cols }
            if wide && underHero && n <= 2 { floor = min(inner, 860) }
        }
        fit = min(fit, cols)
        let g: CGFloat = 10
        let tile = (inner - CGFloat(cols - 1) * g) / CGFloat(cols)
        let width = min(inner, max(floor, CGFloat(fit) * tile + CGFloat(fit - 1) * g))
        self.cols = cols
        self.fit = fit
        self.width = width
        self.track = min(tileMax, (width - CGFloat(fit - 1) * g) / CGFloat(fit))
    }
}

// MARK: - Filter

/// Search, chips and sort (web libFilter, romsSort).
struct LibFilter: Equatable {
    var query = ""
    var systems: Set<String> = []
    var active: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || !systems.isEmpty }

    static let systemOrder = ["GBA": 0, "GBC": 1, "GB": 2]

    enum Sort: String, CaseIterable, Identifiable {
        case recent, alpha, system
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: return "Last played"
            case .alpha: return "A–Z"
            case .system: return "System"
            }
        }
        static var saved: Sort {
            get { Sort(rawValue: UserDefaults.standard.string(forKey: "roms_sort") ?? "") ?? .recent }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: "roms_sort") }
        }
    }

    static func sorted(_ rows: [RomEntry], by sort: Sort) -> [RomEntry] {
        switch sort {
        case .recent: return rows
        case .alpha: return rows.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .system:
            return rows.sorted {
                let a = systemOrder[$0.system] ?? 3, b = systemOrder[$1.system] ?? 3
                return a != b ? a < b : $0.name.localizedCompare($1.name) == .orderedAscending
            }
        }
    }

    // Search is forgiving (web libSearchMatch). Names and the query are
    // folded to lowercase letters and digits, so "firered", "fire red" and
    // "Fire-Red" are one thing. Every word of the query must land somewhere
    // in the name, in any order; a word of three or more characters that
    // lands nowhere as a run still matches if its characters appear in
    // order ("pokmon", "zlda"). Shorter words stay exact.
    static func fold(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0)
        }.map(Character.init))
    }

    private static func subsequence(_ needle: String, _ hay: String) -> Bool {
        var it = needle.makeIterator()
        var want = it.next()
        for c in hay where c == want { want = it.next(); if want == nil { break } }
        return want == nil
    }

    private static func wordMatches(_ w: String, _ name: String) -> Bool {
        name.contains(w) || (w.count >= 3 && subsequence(w, name))
    }

    static func searchMatch(_ q: String, foldedName: String) -> Bool {
        let words = q.lowercased().split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }
            .filter { !$0.isEmpty }
        if words.isEmpty { return true }
        if words.allSatisfy({ wordMatches($0, foldedName) }) { return true }
        // "fire red" typed as two words is also "firered" typed as one.
        return words.count > 1 && wordMatches(words.joined(), foldedName)
    }

    func matches(_ e: RomEntry) -> Bool {
        if !query.isEmpty && !Self.searchMatch(query, foldedName: Self.fold(e.name)) { return false }
        if !systems.isEmpty && !systems.contains(e.system) { return false }
        return true
    }
}

// MARK: - Head

/// "LIBRARY 12 games" and "+ Add a game" (web .home-recent-head).
struct LibraryHead: View {
    @Environment(\.palette) var palette
    let countText: String
    let underHero: Bool
    let add: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("LIBRARY")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundColor(palette.textFaint)
                Text(countText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(palette.textFaint)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: add) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text("Add a game").font(.system(size: 13))
                }
                .foregroundColor(palette.text)
                .padding(.leading, 11)
                .padding(.trailing, 14)
                .frame(minHeight: 34)
                .background(Capsule().fill(LinearGradient(colors: [palette.surface3, palette.surface2],
                                                          startPoint: .top, endPoint: .bottom)))
                .overlay(Capsule().stroke(palette.border2, lineWidth: 1))
            }
            .buttonStyle(PressStyle())
        }
        .padding(.top, underHero ? 20 : 0)
        .overlay(alignment: .top) {
            // Under a hero, the library begins at a rule.
            if underHero { Rectangle().fill(palette.border).frame(height: 1) }
        }
        .padding(.bottom, 10)
    }
}

// MARK: - Search, chips, sort

/// web .lib-bar: one row on wide screens; on phones search and sort, then
/// the chips scrolling sideways in their own row.
struct LibraryBar: View {
    @Environment(\.palette) var palette
    @Binding var filter: LibFilter
    @Binding var sort: LibFilter.Sort
    let systems: [String]
    let counts: [String: Int]
    let wide: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if wide {
                HStack(spacing: 8) {
                    search
                    if systems.count > 1 { chips }
                    sortMenu
                }
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        search
                        sortMenu
                    }
                    if systems.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) { chips }
                    }
                }
            }
        }
    }

    private var fieldHeight: CGFloat { wide ? 32 : 36 }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(searchFocused ? palette.textDim : palette.textFaint)
            TextField("", text: $filter.query, prompt: Text("Search").foregroundColor(palette.textFaint))
                .font(.system(size: 14))
                .foregroundColor(palette.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .accessibilityLabel("Search the library")
            if !filter.query.isEmpty {
                Button {
                    filter.query = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(palette.textFaint)
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: fieldHeight)
        .frame(minWidth: 120, maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(searchFocused ? palette.accent : palette.border2, lineWidth: 1))
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(systems, id: \.self) { s in
                let on = filter.systems.contains(s)
                Button {
                    if on { filter.systems.remove(s) } else { filter.systems.insert(s) }
                } label: {
                    HStack(spacing: 6) {
                        Text(s)
                        // The counts are wide-screen detail: on a phone they
                        // cost the chips their one row.
                        if wide, let n = counts[s] {
                            Text("\(n)").fontWeight(.medium)
                                .foregroundColor(on ? palette.accent.opacity(0.8) : palette.textFaint)
                        }
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(on ? palette.accent : palette.textDim)
                    .padding(.horizontal, 10)
                    .frame(height: wide ? 28 : 30)
                    .background(Capsule().fill(on ? palette.accent.opacity(0.12) : palette.surface2))
                    .overlay(Capsule().stroke(on ? palette.accent.opacity(0.5) : palette.border2, lineWidth: 1))
                }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(LibFilter.Sort.allCases) { s in Text(s.label).tag(s) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(sort.label)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12.5))
            .foregroundColor(palette.text)
            .padding(.horizontal, 10)
            .frame(height: fieldHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border2, lineWidth: 1))
        }
        .accessibilityLabel("Sort the library")
        .fixedSize()
    }
}

// MARK: - Tile

/// One game (web .home-tile): a 3:2 picture, then the name and its system
/// chip under it, the ⋯ corner button always there (touch). A tap opens the
/// game; a long press or the ⋯ opens its menu.
struct LibraryTile: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var palette
    @ObservedObject private var drive = DriveSync.shared
    let entry: RomEntry
    /// Read only so the picture is redrawn when it changes.
    let pictureGen: Int
    @State private var pressed = false

    /// No ROM here: Drive holds it (web .home-tile-cloud) or not (missing).
    private var local: Bool { entry.isLocal }
    private var onDrive: Bool { !local && drive.driveHasRom(entry.fileName) }

    var body: some View {
        VStack(spacing: 0) {
            GamePicture(entry: entry)
                .aspectRatio(3 / 2, contentMode: .fit)
                .clipped()
                .id(pictureGen)
                .opacity(local ? 1 : 0.72)
                .overlay { loadOverlay }
            HStack(spacing: 8) {
                Text(entry.name)
                    .font(.system(size: 13))
                    .foregroundColor(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(local ? 1 : 0.72)
                SysChip(system: entry.system)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(LinearGradient(colors: [palette.surface2, palette.surface1],
                                   startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(pressed ? palette.border2 : local ? palette.border : palette.border2,
                          style: StrokeStyle(lineWidth: 1, dash: local ? [] : [4, 3])))
        .overlay(alignment: .topTrailing) { moreButton }
        .overlay(alignment: .topLeading) { cornerButton }
        .offset(y: pressed ? 1 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { model.openLibraryGame(entry) }
        .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 10) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            model.openSheet(.tileMenu(entry))
        } onPressingChanged: { p in pressed = p }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(entry.system)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "More for this game") { model.openSheet(.tileMenu(entry)) }
    }

    /// What the tile says while its game comes down (web paintTileLoad).
    @ViewBuilder private var loadOverlay: some View {
        let name = entry.fileName
        if let (got, total) = drive.downloading[name] {
            let opening = model.opening == name
            ZStack {
                Color.black.opacity(0.55)
                VStack(spacing: 6) {
                    Text(opening ? (total > 0 && got >= total ? "Starting…" : "Opening") : "Downloading")
                        .font(.system(size: 13, weight: .semibold))
                    if total > 0 {
                        Text(String(format: "%.1f of %.1f MB", Double(got) / 1048576, Double(total) / 1048576))
                            .font(.system(size: 11, design: .monospaced))
                        ProgressView(value: Double(min(got, total)), total: Double(total))
                            .tint(palette.accent)
                            .frame(width: 90)
                    }
                }
                .foregroundColor(.white)
            }
            .overlay(RoundedRectangle(cornerRadius: 1).stroke(opening ? palette.accent : .clear, lineWidth: 2))
        } else if model.opening == name {
            ZStack {
                Color.black.opacity(0.55)
                VStack(spacing: 4) {
                    Text(drive.active ? "Opening" : "Signing in…").font(.system(size: 13, weight: .semibold))
                    if !drive.active { Text("Google Drive").font(.system(size: 11)) }
                }
                .foregroundColor(.white)
            }
        } else if model.tileFailed.contains(name) {
            ZStack {
                Color.black.opacity(0.6)
                VStack(spacing: 4) {
                    Text("Couldn't download").font(.system(size: 13, weight: .semibold))
                    Text("Tap to try again").font(.system(size: 11))
                }
                .foregroundColor(.white)
            }
        }
    }

    /// ↓ for a Drive-only game, a magnifier for a missing one, a check for a
    /// download that just landed.
    @ViewBuilder private var cornerButton: some View {
        let name = entry.fileName
        if model.tileDone.contains(name) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(palette.live)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
                .padding(6)
        } else if !local {
            Button {
                if onDrive { model.downloadOnly(entry) } else { model.relinking = entry }
            } label: {
                Group {
                    if drive.downloading[name] != nil { ProgressView().scaleEffect(0.6).tint(.white) }
                    else { Image(systemName: onDrive ? "arrow.down" : "magnifyingglass") }
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color.white.opacity(0.85))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
            }
            .padding(6)
            .disabled(drive.downloading[name] != nil)
            .accessibilityLabel(onDrive ? "Download \(entry.name) to this device" : "Find the file for \(entry.name)")
        }
    }

    private var moreButton: some View {
        Button {
            model.openSheet(.tileMenu(entry))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(palette.isLight ? Color.white.opacity(0.85) : palette.textDim)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
        }
        .padding(6)
        .accessibilityLabel("More for \(entry.name)")
    }
}

/// A tactile press: the web's translateY(1px) on :active.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 1 : 0)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}
