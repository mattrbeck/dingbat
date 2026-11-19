import SwiftUI

/// A file added under the name of a different game already in the library
/// (web #rom-clash-modal): which of the two the name is for. Two answers of
/// equal weight, each saying what becomes of the save, and neither the
/// default: replacing by reflex would put another game on a save.
struct RomClashSheet: View {
    @Environment(\.palette) var palette
    let asked: String
    let numbered: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("You already have a game named “\(DriveSync.display(asked))”")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The file you added is a different game with the same name.")
                    .font(.system(size: 14.5))
                    .foregroundColor(palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                option("Replace the game",
                       "Use this file for “\(DriveSync.display(asked))”. Its save and save states stay with it.",
                       id: "rom-clash-replace") { AppModel.shared.answerRomClash(.replace) }
                option("Keep both",
                       "Add this one as “\(DriveSync.display(numbered))”. It starts with no save.",
                       id: "rom-clash-both") { AppModel.shared.answerRomClash(.both) }
            }
            Button("Cancel") { AppModel.shared.answerRomClash(nil) }
                .font(.system(size: 14.5))
                .foregroundColor(palette.textDim)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("rom-clash-cancel")
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surface1.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func option(_ title: String, _ sub: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundColor(palette.text)
                Text(sub)
                    .font(.system(size: 13.5))
                    .foregroundColor(palette.textDim)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.border2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
