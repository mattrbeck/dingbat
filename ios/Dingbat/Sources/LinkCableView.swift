import SwiftUI

/// "Connect link cable" (web #net-modal): both players type the same code.
/// The game stays frozen while it is up; the sheet closes itself when the
/// session starts.
struct LinkCableView: View {
    @ObservedObject private var link = NetLink.shared
    @Environment(\.palette) private var palette
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        SheetChrome(title: "Connect link cable") {
            SheetHint("Enter the same code as your friend. They can be on dingbat.gg in a browser or on this app.")
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("", text: $code, prompt: Text("e.g. ABC123").foregroundColor(palette.textFaint))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.go)
                        .focused($focused)
                        .disabled(link.connecting)
                        .onSubmit { link.connectTapped(code: code) }
                        .onChange(of: code) { c in if c.count > 12 { code = String(c.prefix(12)) } }
                        .accessibilityLabel("Link code")
                    if link.connecting { ProgressView().controlSize(.small) }
                }
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(palette.text)
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border2, lineWidth: 1))
                Button(link.connecting ? "Cancel" : "Connect") { link.connectTapped(code: code) }
                    .buttonStyle(SheetButtonStyle(kind: link.connecting ? .normal : .primary, small: false))
            }
            if !link.status.isEmpty {
                Text(link.status)
                    .font(.system(size: 12.5))
                    .foregroundColor(link.statusIsError ? palette.danger : palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true } }
        .onDisappear { link.sheetClosed() }
    }
}
