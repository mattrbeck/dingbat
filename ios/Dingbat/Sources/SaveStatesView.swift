import SwiftUI

/// Save States (web #states-modal): nine slots in a 3x3 grid, slot 1 being
/// the Quick slot the menu's Quick Save/Load use. Pick a slot, then Save,
/// Load or Delete.
struct SaveStatesView: View {
    @ObservedObject private var session = GameSession.shared
    @Environment(\.palette) private var palette
    @State private var selected = 0
    @State private var infos: [GameSession.SlotInfo?] = Array(repeating: nil, count: 9)
    @State private var ask: SheetAsk?

    var body: some View {
        SheetChrome(title: "Save States") {
            if session.game == nil {
                SheetHint("Load a game to use save states.")
            } else {
                SheetHint("Tap a slot, then Save or Load. Slot 1 is the Quick slot.")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(0..<9, id: \.self) { slot in
                        SlotCell(slot: slot, info: infos[slot], selected: slot == selected) { selected = slot }
                    }
                }
                .padding(.bottom, 18)
                HStack(spacing: 10) {
                    Button("Delete") { askDelete() }
                        .buttonStyle(SheetButtonStyle(kind: .danger))
                        .disabled(infos[selected] == nil)
                    Spacer()
                    Button("Load") {
                        if session.loadState(slot: selected) { SheetNav.close() }
                    }
                    .buttonStyle(SheetButtonStyle())
                    .disabled(infos[selected] == nil)
                    Button("Save") {
                        if session.saveState(slot: selected) {
                            AppModel.shared.toast("Saved to slot \(selected + 1)")
                            reload()
                        }
                    }
                    .buttonStyle(SheetButtonStyle(kind: .primary))
                }
            }
        }
        .onAppear(perform: reload)
        .sheetAsk($ask)
    }

    private func reload() {
        infos = (0..<9).map { session.slotInfo($0) }
    }

    private func askDelete() {
        let slot = selected
        let label = slot == 0 ? "the Quick slot" : "slot \(slot + 1)"
        ask = SheetAsk(title: "Delete save state?",
                       message: "Delete the save state in \(label)? This can't be undone.",
                       confirm: "Delete", destructive: true) {
            session.deleteState(slot: slot)
            AppModel.shared.toast("Deleted \(label)")
            reload()
        }
    }
}

/// One slot: its picture (3:2, letterboxed) and "1 · Quick" / the time.
private struct SlotCell: View {
    let slot: Int
    let info: GameSession.SlotInfo?
    let selected: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    if let img = info?.thumb {
                        RoundedRectangle(cornerRadius: 3).fill(palette.surface3)
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(palette.border2, style: StrokeStyle(lineWidth: 1, dash: info == nil ? [3, 3] : []))
                    }
                }
                .aspectRatio(3 / 2, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(slot == 0 ? "1 · Quick" : "\(slot + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(palette.text)
                        .fixedSize()
                    Spacer(minLength: 0)
                    Text(info.map { Self.when($0.date) } ?? "empty")
                        .font(.system(size: 11))
                        .foregroundColor(palette.textDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? palette.accent.opacity(0.14) : palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? palette.accent : palette.border2, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(slot == 0 ? "Slot 1, Quick" : "Slot \(slot + 1)")
        .accessibilityValue(info.map { Self.when($0.date) } ?? "empty")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// web fmtStateTime: month, day, hh:mm.
    static func when(_ d: Date) -> String {
        "\(day.string(from: d)), \(time.string(from: d))"
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jjmm")
        return f
    }()
}
