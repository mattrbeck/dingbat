import SwiftUI

/// Printed Photos (web #prints-modal): every Game Boy Printer photo, newest
/// first, each with Save PNG (the share sheet) and Delete. Opening it clears
/// the menu's new-photo dot.
struct PrintsView: View {
    @Environment(\.palette) private var palette
    @State private var prints: [URL] = []

    var body: some View {
        SheetChrome(title: "Printed Photos") {
            SheetHint("Anything a game prints to the Game Boy Printer lands here.")
            if prints.isEmpty {
                Text("Nothing printed yet.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.textFaint)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
                    ForEach(prints, id: \.self) { url in cell(url) }
                }
            }
        }
        .onAppear {
            prints = PrintStore.all()
            AppModel.shared.newPrints = false
        }
    }

    private func cell(_ url: URL) -> some View {
        VStack(spacing: 8) {
            if let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border2, lineWidth: 1))
                    .accessibilityLabel("Printed photo")
            }
            HStack(spacing: 8) {
                PadButton("Save PNG") {
                    // Under the web's name, <game>-print-<stamp>.png.
                    let copy = (try? Data(contentsOf: url)).flatMap { SheetFiles.temp($0, name: PrintStore.shareName(url)) }
                    Share.present([copy ?? url])
                }
                    .buttonStyle(SheetButtonStyle())
                PadButton("Delete") {
                    try? FileManager.default.removeItem(at: url)
                    prints = PrintStore.all()
                }
                .buttonStyle(SheetButtonStyle(kind: .ghost))
            }
        }
    }
}
