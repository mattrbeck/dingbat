// The Export… sheet (web openExportModal): "What would you like to export?",
// a checkbox per kind of file with its size, the file it will become, then
// Export N; done, the file is in Files › dingbat › Exports and the share
// sheet is a tap away.
import SwiftUI

struct ExportView: View {
    let entry: RomEntry
    @ObservedObject private var model = AppModel.shared
    @Environment(\.palette) var palette
    @State private var items: [GameExport.Item]?
    @State private var on: [String: Bool] = [:]
    @State private var done: (url: URL, count: Int, size: Int, kinds: Set<String>)?

    private var chosen: [GameExport.Item] { (items ?? []).filter { on[$0.kind] == true } }

    var body: some View {
        SheetChrome(title: done == nil ? "What would you like to export?" : "Exported", fit: true) {
            if let done { donePane(done) } else if let items { pickPane(items) } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
        .task { await load() }
    }

    private func load() async {
        // The running game's battery first, so the .sav is as fresh as the screen.
        if GameSession.shared.game == entry { GameSession.shared.flushSave() }
        let e = entry
        let list = await Task.detached(priority: .userInitiated) { GameExport.inventory(e) }.value
        if list.isEmpty {
            model.sheet = nil
            model.toast("Nothing to export for this game yet")
            return
        }
        on = Dictionary(uniqueKeysWithValues: list.map { ($0.kind, GameExport.ticked($0.kind)) })
        items = list
        #if DEBUG
        // `-export-go [kinds]`: tick those (all but the ROM by default) and
        // press Export, for a headless check of the file (ios/e2e).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-export-go") {
            if i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                let want = Set(args[i + 1].split(separator: ",").map(String.init))
                for k in on.keys { on[k] = want.contains(k) }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            export()
        }
        #endif
    }

    // MARK: picking

    private func pickPane(_ items: [GameExport.Item]) -> some View {
        let sectioned = items.count >= GameExport.sectionMin
        return VStack(alignment: .leading, spacing: 0) {
            Text(entry.name + " · " + entry.system)
                .font(.system(size: 13))
                .foregroundColor(palette.textDim)
                .padding(.bottom, 10)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                if sectioned && (i == 0 || items[i - 1].group != it.group) {
                    Text(it.group.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundColor(palette.textFaint)
                        .padding(.top, i == 0 ? 4 : 14)
                        .padding(.bottom, 4)
                }
                row(it)
            }
            footer
                .padding(.top, 16)
        }
    }

    private func row(_ it: GameExport.Item) -> some View {
        let isOn = on[it.kind] == true
        let toggle = { on[it.kind] = !isOn }
        return Button(action: toggle) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? palette.accent : Color.clear)
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isOn ? palette.accent : palette.border2, lineWidth: 1.5)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(palette.accentInk)
                    }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.label)
                        .font(.system(size: 15))
                        .foregroundColor(palette.text)
                    Text(it.sub)
                        .font(.system(size: 12))
                        .foregroundColor(palette.textDim)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(RomEntry.formatBytes(it.size))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(palette.textFaint)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .opacity(isOn ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(it.label)
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityHint(it.sub)
        .padFocus("export:" + it.kind, radius: 8, press: toggle)
    }

    private var footer: some View {
        let c = chosen
        let files = c.flatMap(\.files)
        let bytes = files.reduce(0) { $0 + $1.data.count }
        let now = Date().timeIntervalSince1970 * 1000
        return VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(palette.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.isEmpty ? "Nothing selected" : GameExport.fileName(entry, c, now: now))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(palette.text)
                    .lineLimit(2)
                Text(c.isEmpty ? "Tick something to export"
                     : files.count == 1 ? RomEntry.formatBytes(bytes) + " · a single file"
                     : "\(c.count) \(c.count == 1 ? "item" : "items") · " + RomEntry.formatBytes(bytes))
                    .font(.system(size: 12))
                    .foregroundColor(palette.textDim)
            }
            HStack(spacing: 10) {
                Spacer()
                pill("Cancel", primary: false) { model.sheet = nil }
                pill(c.isEmpty ? "Export" : "Export \(c.count)", primary: true, disabled: c.isEmpty) { export() }
            }
        }
    }

    private func export() {
        let c = chosen
        guard !c.isEmpty else { return }
        GameExport.remember(on)
        do {
            let url = try GameExport.package(entry, c)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            withAnimation(.easeOut(duration: 0.15)) {
                done = (url, c.count, size, Set(c.map(\.kind)))
            }
        } catch {
            model.toast("Couldn't export: " + error.localizedDescription)
        }
    }

    // MARK: done

    private func donePane(_ d: (url: URL, count: Int, size: Int, kinds: Set<String>)) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(d.url.lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.text)
                Text((d.count > 1 ? "\(d.count) items · " : "") + RomEntry.formatBytes(d.size)
                     + " · in Files › dingbat › Exports")
                    .font(.system(size: 12))
                    .foregroundColor(palette.textDim)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border2, lineWidth: 1))
            if d.kinds.contains("states") {
                Text(d.kinds.contains("save")
                     ? "The .sav opens in any emulator. The save states only open in dingbat."
                     : "The save states only open in dingbat.")
                    .font(.system(size: 12.5))
                    .foregroundColor(palette.textDim)
            }
            HStack(spacing: 10) {
                Spacer()
                // Files, AirDrop or a message: where it was going anyway.
                pill("Share…", primary: false) { Share.present([d.url]) }
                pill("Done", primary: true) { model.sheet = nil }
            }
        }
    }

    private func pill(_ label: String, primary: Bool, disabled: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: primary ? .semibold : .regular))
                .foregroundColor(primary ? palette.accentInk : palette.text)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .background(Capsule().fill(primary
                    ? AnyShapeStyle(LinearGradient(colors: [palette.accent2, palette.accent], startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(palette.surface2)))
                .overlay(Capsule().stroke(primary ? palette.accent.opacity(0.6) : palette.border2, lineWidth: 1))
                .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(PressStyle())
        .disabled(disabled)
        .padFocus("export-btn:" + label, radius: 22, press: action)
    }
}
