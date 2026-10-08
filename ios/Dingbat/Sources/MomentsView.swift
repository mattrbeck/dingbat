import SwiftUI

/// Resume from earlier (web #moments-modal): the game's session and its
/// checkpoints, newest first, each with its picture, how much play earlier
/// it is and when. Two ways in: the game's menu, and - after the game has
/// stopped unexpectedly twice in a row - a tap on the game, which opens the
/// `crash` form ("… stopped unexpectedly", with Start from in-game save)
/// instead of resuming the moment that may be the cause.
struct MomentsView: View {
    let entry: RomEntry
    let crash: Bool
    @Environment(\.palette) private var palette
    @State private var moments: [Checkpoints.Moment] = []
    @State private var pictures: [String: UIImage] = [:]
    @State private var pick = 0
    @State private var saveSig: String?

    var body: some View {
        SheetChrome(title: crash ? entry.name + " stopped unexpectedly" : "Resume from earlier") {
            SheetHint(hint)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { i, m in
                    cell(i, m)
                }
            }
            .padding(.bottom, 12)
            if let m = selected, before(m) {
                SheetHint("This is from before your last in-game save, which goes back with it. Your newer save " +
                          "is kept: Restore old save, on the game's menu, brings it back.")
            }
            HStack(spacing: 10) {
                if crash {
                    PadButton("Start from in-game save") {
                        SheetNav.close()
                        AppModel.shared.launch(entry, resume: false, fresh: true)
                    }
                    .buttonStyle(SheetButtonStyle())
                }
                Spacer()
                Button("Resume", action: resume)
                    .buttonStyle(SheetButtonStyle(kind: .primary))
                    .disabled(selected == nil)
            }
        }
        .onAppear(perform: load)
    }

    private var hint: String {
        guard crash else { return "Moments from your recent play, kept on this device." }
        let n = CrashWatch.streak(entry.fileName)
        return "It closed without warning the last " + (n == 2 ? "two" : "\(n)") + " times. If the " +
            "moment it resumes from is what's stopping it, pick an earlier one."
    }

    private var selected: Checkpoints.Moment? { moments.indices.contains(pick) ? moments[pick] : nil }

    /// From before the save stored now (its battery would go back with it).
    private func before(_ m: Checkpoints.Moment) -> Bool { saveSig != nil && m.saveSig != saveSig }

    private func load() {
        moments = Checkpoints.moments(entry)
        saveSig = RomLibrary.currentSaveSig(entry)
        pick = 0
        for m in moments { pictures[m.id] = Checkpoints.picture(entry, m) }
    }

    private func resume() {
        guard let m = selected else { return }
        SheetNav.close()
        AppModel.shared.resumeMoment(entry, m)
    }

    private func cell(_ i: Int, _ m: Checkpoints.Moment) -> some View {
        let on = i == pick
        return VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(palette.surface3)
                if let img = pictures[m.id] {
                    Image(uiImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(i == 0 ? "Latest" : Checkpoints.fmtPlayGap((moments.first?.play ?? m.play) - m.play))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(palette.text)
                    .lineLimit(1)
                Text(Self.when(m.ts))
                    .font(.system(size: 11))
                    .foregroundColor(palette.textDim)
                    .lineLimit(1)
            }
            if before(m) {
                Text("Before your last save")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(palette.accent)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? palette.accent.opacity(0.14) : palette.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? palette.accent : palette.border2, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pick = i; resume() }
        .onTapGesture { pick = i }
        .padFocus("moment\(i)") { pick = i }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// web fmtMomentTime: today the time, otherwise the day too.
    static func when(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(d) ? "jjmm" : "MMMdjjmm")
        return f.string(from: d)
    }
}
