import SwiftUI
import UniformTypeIdentifiers

/// Manage Saves (web #saves-modal): the game's own battery save (export,
/// import with GameShark-family unwrapping, reset) and whole-state files
/// (.state, the same bytes as desktop dingbat's).
struct ManageSavesView: View {
    @ObservedObject private var session = GameSession.shared
    @State private var picking = false
    /// What the importer is open for (kept past its dismissal).
    @State private var pickKind = Pick.save
    @State private var ask: SheetAsk?
    @State private var notice: String?

    private enum Pick { case save, state }

    var body: some View {
        SheetChrome(title: "Manage Saves") {
            if session.game == nil {
                SheetHint("Load a game to manage its saves.")
            } else {
                SheetSubhead(text: "Save file", rule: false)
                SheetRow(label: "Export save file",
                         sub: "Download the game's own save (.sav) — your in-game progress") {
                    Button("Export", action: exportSave).buttonStyle(SheetButtonStyle())
                }
                SheetRow(label: "Import save file", sub: "Replace the game's save (.sav) and reload it") {
                    Button("Import") { pickKind = .save; picking = true }.buttonStyle(SheetButtonStyle())
                }
                SheetRow(label: "Reset save file",
                         sub: "Wipe this game's save and reload it as a fresh cartridge") {
                    SheetConfirmButton(label: "Reset", confirmLabel: "Confirm reset?", action: resetSave)
                        .fixedSize()
                }
                SheetSubhead(text: "Save state file")
                SheetRow(label: "Export state",
                         sub: "Download the current state as a .state file (desktop-compatible). Manage slots in Save States.") {
                    Button("Export", action: exportState).buttonStyle(SheetButtonStyle())
                }
                SheetRow(label: "Import state", sub: "Apply a .state file to the running game") {
                    Button("Import") { pickKind = .state; picking = true }.buttonStyle(SheetButtonStyle())
                }
            }
        }
        // One importer for both (two on one view: only the last works).
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
            let kind = pickKind
            guard case .success(let url) = result, let data = SheetFiles.read(url) else { return }
            if kind == .save { importSave(data, fileName: url.lastPathComponent) } else { importState(data) }
        }
        .sheetAsk($ask)
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: save file

    private func exportSave() {
        guard let g = session.game else { return }
        dingbat_flush_save()
        guard let data = try? Data(contentsOf: g.saveURL), !data.isEmpty else {
            notice = "No save data found for this ROM."
            return
        }
        if let url = SheetFiles.temp(data, name: "\(g.stem).sav") { Share.present([url]) }
    }

    /// web applyImportedSave: unwrap, two confirms, then replace and reboot.
    private func importSave(_ data: Data, fileName: String) {
        guard let g = session.game else { return }
        let unwrapped: SaveImport.Result
        switch SaveImport.unwrap(data, fileName: fileName) {
        case .failure(.bad(let why)):
            notice = why
            return
        case .success(let r):
            unwrapped = r
        }
        var overwrite = "This will overwrite any existing save file for the current game."
        if let w = unwrapped.warning { overwrite += " Note: \(w)." }
        ask = SheetAsk(title: "Import save file?", message: overwrite + " Continue?", confirm: "Continue") {
            let stem = (fileName as NSString).deletingPathExtension
            if stem != g.stem {
                // The second confirm, once the first alert has gone.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    ask = SheetAsk(title: "Different name",
                                   message: "You've selected a save file that doesn't match the name of the current game. Are you sure you want to overwrite the save?",
                                   confirm: "Overwrite", destructive: true) {
                        installSave(unwrapped, for: g)
                    }
                }
            } else {
                installSave(unwrapped, for: g)
            }
        }
    }

    private func installSave(_ r: SaveImport.Result, for g: RomEntry) {
        SheetNav.close()
        Self.reboot(g) {
            try? r.bytes.write(to: g.saveURL, options: .atomic)
        }
        if let f = r.format {
            AppModel.shared.toast("Imported \(f) save" + (r.title.map { " — \($0)" } ?? ""))
        }
    }

    /// web resetCurrentSaveFile: the battery save and the session go (state
    /// slots stay), and the game boots as a fresh cartridge.
    private func resetSave() {
        guard let g = session.game else { return }
        SheetNav.close()
        Self.reboot(g) {
            let fm = FileManager.default
            for f in [g.saveURL, g.sessionURL, g.sessionMetaURL, g.sessionPicURL] { try? fm.removeItem(at: f) }
        }
        RomLibrary.shared.pictureGen += 1
        AppModel.shared.toast("Save reset — starting fresh")
    }

    /// Close the game first (its in-memory save is flushed there, so it can't
    /// land on top of the change afterwards), change the files, boot it again
    /// from the save.
    static func reboot(_ g: RomEntry, change: () -> Void) {
        let model = AppModel.shared
        model.session.close()
        change()
        model.launch(g, resume: false)
    }

    // MARK: state file

    private func exportState() {
        guard let g = session.game else { return }
        guard let data = session.captureState() else {
            AppModel.shared.toast("Couldn't capture the emulator state")
            return
        }
        if let url = SheetFiles.temp(data, name: "\(g.stem).state") { Share.present([url]) }
    }

    /// Applied to the running game, not kept anywhere.
    private func importState(_ data: Data) {
        if let why = session.apply(state: data, keepRewind: false) {
            notice = why
            return
        }
        SheetNav.close()
        AppModel.shared.toast("State loaded")
    }
}
