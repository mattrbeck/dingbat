// The game's menu (web #tile-menu), one wherever its ⋯ is (a tile's ⋯ or
// long press, the closed hero's, the paused hero's): a bottom sheet headed
// by the picture; and the Rename sheet.
import SwiftUI

// MARK: - The game's menu

/// One menu per game (web openTileMenu): the head says which game, then
/// Play - the session's own items, only while the paused hero is up for
/// this very game - then Game, the file items that apply, then Delete set
/// apart. Context hides rows; it never swaps the menu.
struct TileMenuView: View {
    let entry: RomEntry
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var library = RomLibrary.shared
    @Environment(\.palette) var palette
    /// The item waiting for its second tap (web confirmLabel), and when.
    @State private var armed: String?
    @State private var armedAt = Date.distantPast
    /// The rows' height as laid out unarmed: the sheet's (an armed row's
    /// sub-line takes the reserve below, so arming never moves the sheet).
    @State private var contentHeight: CGFloat?
    /// The pinned head's, the rule under it included.
    @State private var headHeight: CGFloat?

    private var loaded: Bool { GameSession.shared.game == entry }
    /// web tileMenuEntries' busy: the loaded game's files wait for its
    /// link or 2P session to end.
    private var busy: String? { loaded && model.sessionBusy ? "Exit the online session first" : nil }
    /// web openTileMenu's `session`: the paused hero is up for this game.
    /// `!sessionBusy` is the hero's own guard (HomeView's `hero`: none is
    /// drawn for a link or 2P session), so the Play rows never wait.
    private var session: Bool {
        loaded && model.screen == .home && model.heroGame == entry && !model.sessionBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            // The head stays put, × and all, while the rows scroll under it
            // (as SheetChrome's header): held sideways the sheet is the
            // whole height, and the × is its one visible way out.
            VStack(alignment: .leading, spacing: 0) {
                head
                Rectangle().fill(palette.border).frame(height: 1)
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.top, 18)
            .background(GeometryReader { g in
                Color.clear.preference(key: TileMenuHeadKey.self, value: g.size.height)
            })
            ScrollViewReader { proxy in
                ScrollView {
                    rows
                        .background(GeometryReader { g in
                            Color.clear.preference(key: TileMenuHeightKey.self, value: g.size.height)
                        })
                }
                .bounceOnlyIfScrolling()
                .padScrollFollow(proxy)
            }
        }
        .onPreferenceChange(TileMenuHeadKey.self) { h in
            if h > 0 { headHeight = h }
        }
        .onPreferenceChange(TileMenuHeightKey.self) { h in
            if armed == nil && h > 0 { contentHeight = h }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface1.ignoresSafeArea())
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session {
                group("Play")
                playRows
                group("Game")
            }
            fileRows
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// The loaded game's own controls (web sessionMenuEntries), without
    /// Screenshot or Clip that! (the frame here is the hero's picture of a
    /// game that stopped). A DS game has no link cable or cheats, as in the
    /// game's own menu. Link Cable goes through NetLink's own sheet opener.
    @ViewBuilder private var playRows: some View {
        item("states", "Save states", icon: "square.grid.2x2") { model.openSheet(.states) }
        item("saves", "Manage saves", icon: "folder") { model.openSheet(.saves) }
        if !PrintStore.all().isEmpty {
            item("prints", "Printed photos", icon: "printer", dot: model.newPrints) {
                model.openSheet(.prints)
            }
        }
        if !GameSession.shared.isNDS {
            item("link", "Link cable", icon: "cable.connector") { NetLink.shared.openSheet() }
            item("cheats", "Cheats", icon: "star") { model.openSheet(.cheats) }
        }
        item("report", "Report a bug", icon: "ladybug") { model.openSheet(.report) }
    }

    /// The file items (web tileMenuEntries). Order: get it, name it, wipe
    /// its saves, free the space, and last - set apart - delete it.
    @ViewBuilder private var fileRows: some View {
        let drive = DriveSync.shared
        let local = entry.isLocal
        let onDrive = drive.driveHasRom(entry.fileName)
        if !local && !onDrive {
            item("find", "Find the file…", icon: "magnifyingglass") {
                model.sheet = nil
                model.relinkLaunch = false
                model.relinking = entry
            }
        }
        if !local && onDrive {
            item("download", "Download to this device", icon: "arrow.down",
                 disabled: drive.downloading[entry.fileName] != nil ? "Downloading…" : nil) {
                model.sheet = nil
                model.downloadOnly(entry)
            }
        }
        // Earlier moments of play, kept on this device: the way back when
        // where the game stopped is what keeps stopping it.
        if local && Checkpoints.hasAny(entry) {
            item("moments", "Resume from earlier", icon: "clock.arrow.circlepath", disabled: busy) {
                model.sheet = .moments(entry, crash: false)
            }
        }
        item("rename", "Rename", icon: "pencil", disabled: busy) {
            model.sheet = .rename(entry)
        }
        // It only reads, so an online session does not hold it up.
        if !local && onDrive {
            item("export", "Download and export…", icon: "arrow.up.forward.square",
                 disabled: drive.downloading[entry.fileName] != nil ? "Downloading…" : nil) {
                model.sheet = nil
                model.downloadThenExport(entry)
            }
        } else {
            item("export", "Export…", icon: "arrow.up.forward.square") { model.sheet = .export(entry) }
        }
        let hasSaves = library.hasSaveData(entry)
        item("reset", "Reset save data", icon: "eraser",
             disabled: busy ?? (hasSaves ? nil : "No save data yet"),
             confirm: "Reset save data?", confirmSub: "Every save for this game is deleted") {
            model.sheet = nil
            HomeActions.resetSaveData(entry)
        }
        if let kept = drive.keptSave(entry.fileName) {
            item("restore", "Restore old save", icon: "arrow.uturn.backward", disabled: busy,
                 sub: kept.why == "replaced" ? "The save you replaced"
                    : "From before you deleted it" + (kept.at > 0 ? " · saved " + Self.fmtTime(kept.at) : ""),
                 confirm: "Restore old save?", confirmSub: "It replaces the current save") {
                model.sheet = nil
                drive.restoreKeptSave(entry.fileName)
            }
        }
        if local && drive.linked {
            item("remove", "Remove from this device", icon: Self.removeGlyph,
                 disabled: busy ?? (onDrive ? nil : "Not backed up to Drive yet — this is your only copy"),
                 confirm: "Remove from this device?",
                 confirmSub: (loaded ? "Closes the game; " : "") + "Drive keeps a copy") {
                model.sheet = nil
                Task { @MainActor in await drive.removeFromDevice(entry.fileName) }
            }
        }
        // Set apart by a rule: the one that cannot be undone.
        Rectangle().fill(palette.border).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 4)
        item("delete", "Delete", icon: "trash", danger: true, disabled: busy,
             confirm: "Delete this game?",
             confirmSub: loaded ? "Closes the game; the ROM and its save data go"
                : !local && !onDrive ? "Its save data goes too" : "The ROM and its save data go") {
            model.sheet = nil
            HomeActions.delete(entry)
        }
    }

    /// The pinned head and the rows as measured, plus room for an armed
    /// row's sub-line. Until both are measured, a guess from the row count.
    /// Taller than the screen is the screen's height, and the rows scroll.
    private var sheetHeight: CGFloat {
        if let contentHeight, let headHeight { return headHeight + contentHeight + Self.armReserve }
        let drive = DriveSync.shared
        var rows = 4
        if !entry.isLocal { rows += 1 }
        if drive.keptSave(entry.fileName) != nil { rows += 1 }
        if entry.isLocal && drive.linked { rows += 1 }
        if entry.isLocal && Checkpoints.hasAny(entry) { rows += 1 }
        if session { rows += 7 }
        return CGFloat(130 + rows * 46)
    }

    /// An armed row's sub-line (what goes): 12 pt and its spacing.
    private static let armReserve: CGFloat = 18

    /// This device, struck out: an iPad's own where it has one (16.1 on).
    private static var removeGlyph: String {
        if #available(iOS 16.1, *), UIDevice.current.userInterfaceIdiom == .pad {
            return "ipad.and.iphone.slash"
        }
        return "iphone.slash"
    }

    static func fmtTime(_ ms: Double) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d HH:mm")
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// web tileMenuStatus: the system, the size, and the one thing nothing
    /// else in the menu says, that a game whose file is gone left its save.
    private var status: String {
        var bits = [entry.system]
        // DS games never sync (driveExcluded): say so where sync is in play.
        if entry.isNDS && DriveSync.shared.linked { bits.append("this device only") }
        bits += [entry.sizeText].filter { !$0.isEmpty }
        let onDrive = DriveSync.shared.driveHasRom(entry.fileName)
        let saves = library.hasSaveData(entry)
        if !entry.isLocal && !onDrive {
            bits.append(saves ? "the file is not here, but your save is" : "the file is not on this device")
        } else if !entry.isLocal && saves {
            bits.append("your save is still on this device")
        }
        return bits.joined(separator: " · ")
    }

    /// The game's picture, its name, "SYS · size" (web buildTileMenuHead).
    private var head: some View {
        HStack(spacing: 10) {
            ZStack {
                if let img = HomePictures.shared.picture(entry, preferSession: false) {
                    Color.black
                    Image(uiImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                } else if let art = HomePictures.shared.art(entry) {
                    Image(uiImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    palette.text.opacity(0.03)
                    SysChip(system: entry.system)
                }
            }
            .frame(width: 84, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(status)
                    .font(.system(size: 12))
                    .foregroundColor(palette.textDim)
            }
            Spacer(minLength: 0)
            // A way out anyone can see: held sideways the sheet takes the
            // whole height, with no grabber and no scrim above it (web: the
            // tile menu's ×). The sheets' own close (SheetChrome).
            SheetCloseButton(action: SheetNav.close)
        }
        .padding(.leading, 6)  // the × 12 pt from the edge, as SheetHeader's
        .padding(.bottom, 12)
    }

    /// A group's heading (web .tile-menu-group): the library head's small
    /// caps. Not an item: the pad passes over it.
    private func group(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundColor(palette.textFaint)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    /// web tileMenuItem: a glyph, then the label; a disabled item says why
    /// under its label; a destructive one asks for a second tap within 3.5 s.
    /// Armed, the label asks the action back (`confirm`) and the sub-line
    /// says what goes (`confirmSub`).
    private func item(_ id: String, _ label: String, icon: String, danger: Bool = false,
                      disabled: String? = nil, sub: String? = nil, confirm: String? = nil,
                      confirmSub: String? = nil, dot: Bool = false,
                      run: @escaping () -> Void) -> some View {
        let isArmed = armed == id
        let tap = {
            if confirm != nil, armed != id {
                armed = id
                armedAt = Date()
                Haptic.warning()
                let stamp = armedAt
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    if armed == id && armedAt == stamp { armed = nil }
                }
                return
            }
            armed = nil
            run()
        }
        // The glyph follows its label: faint when blocked, red on Delete,
        // the armed ink when armed (web .tile-menu-icon).
        let ink = isArmed ? palette.dangerInk
            : disabled != nil ? palette.textFaint
            : danger ? palette.danger : palette.text
        return Button(action: tap) {
            // The glyph centred on the label and its sub-line, as the web's.
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .foregroundColor(isArmed || disabled != nil || danger ? ink : palette.textDim)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        // The question is bold; what goes, under it, is not.
                        Text(isArmed ? (confirm ?? label) : label)
                            .font(.system(size: 15, weight: isArmed ? .semibold : .regular))
                            .foregroundColor(ink)
                        if dot { Circle().fill(palette.accent).frame(width: 6, height: 6) }
                    }
                    if let sub = isArmed ? confirmSub : (disabled ?? sub) {
                        Text(sub)
                            .font(.system(size: 12))
                            .foregroundColor(isArmed ? palette.dangerInk : palette.textDim)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .armedFill(isArmed, RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padFocus("item:" + id, armed: isArmed, press: tap)
        .disabled(disabled != nil)
    }
}

private struct TileMenuHeadKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TileMenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    /// Rows that fit do not bounce (iOS 16.4 on; before, they do).
    @ViewBuilder func bounceOnlyIfScrolling() -> some View {
        if #available(iOS 16.4, *) { scrollBounceBehavior(.basedOnSize) } else { self }
    }
}

// MARK: - Per-game actions

/// What the game's menu's items do (web resetGameAction, deleteGameAction,
/// renameGame), the game in memory included.
enum HomeActions {
    /// Reset save data (web resetGameAction). The game in memory is let go
    /// unflushed, so its battery RAM cannot write back over the reset, and
    /// boots again fresh, still where the player is.
    static func resetSaveData(_ e: RomEntry) {
        let model = AppModel.shared
        let session = GameSession.shared
        let loaded = session.game == e
        if loaded { session.discard() }
        RomLibrary.shared.resetSaveData(e)
        if loaded { reboot(e) }
        model.toast(loaded ? "Save data deleted — starting fresh" : "Save data deleted")
    }

    /// Boot `e` again from its save, playing if the player is in the game,
    /// paused behind the hero otherwise.
    static func reboot(_ e: RomEntry) {
        let model = AppModel.shared
        let session = GameSession.shared
        guard session.open(e, resume: false) != .failed else { return }
        model.heroGame = e
        if model.screen != .play { session.setPaused(true) }
    }

    /// Delete the ROM and everything of it; the game in memory is closed
    /// first, and the hero goes with it.
    static func delete(_ e: RomEntry) {
        let model = AppModel.shared
        if GameSession.shared.game == e { model.closeGame() }
        if model.heroGame == e { model.heroGame = nil }
        Task { @MainActor in
            await RomLibrary.shared.delete(e)
            model.toast(DriveSync.shared.enrolled ? "Deleted from all your devices" : "Deleted from this device")
        }
    }

    /// Rename every file of the game. One in memory stays open under its new
    /// name: it is closed (the session is kept), renamed, and put back from
    /// that session, still paused.
    static func rename(_ e: RomEntry, to name: String) {
        let model = AppModel.shared
        let session = GameSession.shared
        let wasLoaded = session.game == e
        if wasLoaded { model.closeGame() }
        Task { @MainActor in
            guard let fresh = await RomLibrary.shared.rename(e, to: name) else {
                if wasLoaded, session.open(e, resume: true) != .failed { session.setPaused(true) }
                model.toast("Couldn't rename “\(e.name)” — its ROM, saves and save states are all still under that name",
                            duration: 5)
                return
            }
            if model.heroGame == e { model.heroGame = fresh }
            if wasLoaded, session.open(fresh, resume: true) != .failed {
                session.setPaused(true)
            }
            model.toast("Renamed to “\(fresh.name)”")
        }
    }
}

// MARK: - Rename

/// web openRenameModal: the new name (checked as it is typed), then a
/// confirmation saying what moves.
struct RenameView: View {
    let entry: RomEntry
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var library = RomLibrary.shared
    @Environment(\.palette) var palette
    @State private var name = ""
    @State private var confirming = false
    @FocusState private var focused: Bool

    private var error: String? { library.renameError(entry, to: name) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var loaded: Bool { GameSession.shared.game == entry }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if confirming { confirmPane } else { namePane }
                }
                .padding(20)
            }
            .background(palette.surface1.ignoresSafeArea())
            .navigationTitle("Rename game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(confirming ? "Back" : "Cancel") {
                        if confirming { confirming = false } else { model.sheet = nil }
                    }
                    .foregroundColor(palette.textDim)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirming ? "Rename" : "Continue") {
                        if confirming {
                            model.sheet = nil
                            HomeActions.rename(entry, to: trimmed)
                        } else if error == nil {
                            focused = false
                            confirming = true
                        }
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(error == nil ? palette.accent : palette.textFaint)
                    .disabled(error != nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            name = entry.name
            focused = true
        }
    }

    private var namePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            hint("The name is how every one of this game's files is stored, so renaming it " +
                 "moves its saves, save states and cheats too. Nothing is deleted. " +
                 "Its “.\(entry.ext)” ending stays as it is.")
            Text("New name")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(palette.textDim)
            TextField("", text: $name)
                .font(.system(size: 16))
                .foregroundColor(palette.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.continue)
                .onSubmit { if error == nil { confirming = true } }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(focused ? palette.accent : palette.border2, lineWidth: 1))
                .accessibilityLabel("New name for \(entry.name)")
            if let error {
                Text(error).font(.system(size: 12.5)).foregroundColor(palette.danger)
            } else {
                Text("Stored as “\(trimmed).\(entry.ext)”.")
                    .font(.system(size: 12.5)).foregroundColor(palette.textDim)
            }
        }
    }

    private var confirmPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            hint("Everything stored under the old name moves to the new one. This does not delete anything.")
            VStack(spacing: 0) {
                diffRow("From", entry.fileName)
                Rectangle().fill(palette.border).frame(height: 1)
                diffRow("To", "\(trimmed).\(entry.ext)")
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
            let lines = inventory
            Text(lines.isEmpty ? "Nothing else is stored here" : "What gets renamed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(palette.textDim)
            ForEach(lines, id: \.self) { l in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundColor(palette.textFaint)
                    Text(l).foregroundColor(palette.text)
                }
                .font(.system(size: 14))
            }
            if lines.isEmpty && !DriveSync.shared.linked {
                hint("This game has no saved data on this device yet — only its place in your library moves.")
            }
            if DriveSync.shared.linked {
                hint("Copies on Google Drive are renamed on the next sync, and your other devices follow.")
            }
            if loaded {
                hint("This game is open right now. It stays open, under its new name.")
            }
        }
    }

    /// web renameInventoryLines, for what this device stores.
    private var inventory: [String] {
        let fm = FileManager.default
        func has(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
        var out: [String] = []
        if has(entry.url) { out.append(has(entry.artURL) ? "The ROM file and its box art" : "The ROM file") }
        if entry.hasSave { out.append("1 save file") }
        if has(entry.dir.appendingPathComponent("rom-p2.sav")) { out.append("The 2-player link save") }
        let states = (0..<9).filter { has(entry.stateURL(slot: $0)) }.count
        if states > 0 { out.append(states == 1 ? "1 save state" : "\(states) save states") }
        if has(entry.sessionURL) { out.append("The resume snapshot") }
        if has(entry.cheatsURL) { out.append("Your cheat list") }
        if has(entry.oldSaveURL) { out.append("The save kept from before you deleted it") }
        let prints = PrintStore.all().filter { PrintStore.game(of: $0) == entry.fileName }.count
        if prints > 0 { out.append(prints == 1 ? "1 printed photo" : "\(prints) printed photos") }
        return out
    }

    private func diffRow(_ k: String, _ v: String) -> some View {
        HStack(spacing: 12) {
            Text(k)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.textFaint)
                .frame(width: 40, alignment: .leading)
            Text(v)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func hint(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13))
            .foregroundColor(palette.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }
}
