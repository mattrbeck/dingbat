// The game's menus. The file menu (web #tile-menu: a tile's ⋯ or long
// press, the closed hero's ⋯) as a bottom sheet headed by the picture; the
// session menu (the paused hero's ⋯); and the Rename sheet.
import SwiftUI

// MARK: - File menu

struct TileMenuView: View {
    let entry: RomEntry
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var library = RomLibrary.shared
    @Environment(\.palette) var palette
    /// The item waiting for its second tap (web confirmLabel), and when.
    @State private var armed: String?
    @State private var armedAt = Date.distantPast

    private var loaded: Bool { GameSession.shared.game == entry }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Rectangle().fill(palette.border).frame(height: 1).padding(.bottom, 6)
            let drive = DriveSync.shared
            let local = entry.isLocal
            let onDrive = drive.driveHasRom(entry.fileName)
            if !local && !onDrive {
                item("find", "Find the file…") {
                    model.sheet = nil
                    model.relinking = entry
                }
            }
            if !local && onDrive {
                item("download", "Download to this device",
                     disabled: drive.downloading[entry.fileName] != nil ? "Downloading…" : nil) {
                    model.sheet = nil
                    model.downloadOnly(entry)
                }
            }
            item("rename", "Rename") {
                model.sheet = .rename(entry)
            }
            let hasSaves = library.hasSaveData(entry)
            item("reset", "Reset save data",
                 disabled: hasSaves ? nil : "No save data yet",
                 confirm: "Delete all save data?") {
                model.sheet = nil
                HomeActions.resetSaveData(entry)
            }
            if let kept = drive.keptSave(entry.fileName) {
                item("restore", "Restore old save", sub: kept.why == "replaced" ? "The save you replaced"
                        : "From before you deleted it" + (kept.at > 0 ? " · saved " + Self.fmtTime(kept.at) : ""),
                     confirm: "Replace the current save?") {
                    model.sheet = nil
                    drive.restoreKeptSave(entry.fileName)
                }
            }
            if local && drive.linked {
                item("remove", "Remove from this device",
                     disabled: onDrive ? nil : "Not backed up to Drive yet — this is your only copy",
                     confirm: loaded ? "Close and remove?" : "Remove from this device?") {
                    model.sheet = nil
                    Task { @MainActor in await drive.removeFromDevice(entry.fileName) }
                }
            }
            item("delete", "Delete", danger: true,
                 confirm: loaded ? "Close and delete everything?" : "Delete ROM and save data?") {
                model.sheet = nil
                HomeActions.delete(entry)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface1.ignoresSafeArea())
        .presentationDetents([.height(hasSavesHeight)])
        .presentationDragIndicator(.visible)
    }

    private var hasSavesHeight: CGFloat {
        let drive = DriveSync.shared
        var rows = 3
        if !entry.isLocal { rows += 1 }
        if drive.keptSave(entry.fileName) != nil { rows += 1 }
        if entry.isLocal && drive.linked { rows += 1 }
        return CGFloat(150 + rows * 50)
    }

    static func fmtTime(_ ms: Double) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d HH:mm")
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
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
                Text([entry.system, entry.sizeText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundColor(palette.textDim)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 12)
    }

    /// web tileMenuItem: a disabled item says why under its label; a
    /// destructive one asks for a second tap within 3.5 s.
    private func item(_ id: String, _ label: String, danger: Bool = false, disabled: String? = nil,
                      sub: String? = nil, confirm: String? = nil, run: @escaping () -> Void) -> some View {
        let isArmed = armed == id
        return Button {
            if confirm != nil, !isArmed {
                armed = id
                armedAt = Date()
                let stamp = armedAt
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    if armed == id && armedAt == stamp { armed = nil }
                }
                return
            }
            armed = nil
            run()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(isArmed ? (confirm ?? label) : label)
                    .font(.system(size: 15))
                    .foregroundColor(isArmed ? palette.accentInk
                                     : disabled != nil ? palette.textFaint
                                     : danger ? palette.danger : palette.text)
                if let sub = isArmed ? "Tap again to confirm" : (disabled ?? sub) {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundColor(isArmed ? palette.accentInk : palette.textDim)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isArmed
                          ? AnyShapeStyle(LinearGradient(colors: [palette.dangerHi, palette.danger],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled != nil)
    }
}

// MARK: - Session menu

/// The paused hero's ⋯ (web sessionMenuEntries): the menu's game-wide
/// items, without Screenshot (the frame here is the card's picture).
struct SessionMenuItems: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Button { model.openSheet(.states) } label: { Label("Save states", systemImage: "square.grid.2x2") }
        Button { model.openSheet(.saves) } label: { Label("Manage saves", systemImage: "folder") }
        if !PrintStore.all().isEmpty {
            Button { model.openSheet(.prints) } label: { Label("Printed photos", systemImage: "printer") }
        }
        Button { model.openSheet(.cheats) } label: { Label("Cheats", systemImage: "star") }
        Button { model.openSheet(.report) } label: { Label("Report a bug", systemImage: "ladybug") }
    }
}

// MARK: - Per-game actions

/// What the file menu's items do (web resetGameAction, deleteGameAction,
/// renameGame), the game in memory included.
enum HomeActions {
    /// Reset save data. The game in memory is closed first, so its battery
    /// RAM is not flushed back over the reset (the web reboots it fresh; here
    /// the hero turns to closed and the next Play starts fresh).
    static func resetSaveData(_ e: RomEntry) {
        let model = AppModel.shared
        if GameSession.shared.game == e { model.closeGame() }
        RomLibrary.shared.resetSaveData(e)
        model.toast("Save data deleted")
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
            guard let fresh = await RomLibrary.shared.rename(e, to: name) else { return }
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
        let states = (0..<9).filter { has(entry.stateURL(slot: $0)) }.count
        if states > 0 { out.append(states == 1 ? "1 save state" : "\(states) save states") }
        if has(entry.sessionURL) { out.append("The resume snapshot") }
        if has(entry.cheatsURL) { out.append("Your cheat list") }
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
