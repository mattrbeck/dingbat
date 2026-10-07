import SwiftUI

/// "Connect link cable" (web #net-modal): both players type the same code,
/// or, with no server (or by choice), trade codes by hand. The game stays
/// frozen while it is up; the sheet closes itself when the session starts.
struct LinkCableView: View {
    @ObservedObject private var link = NetLink.shared
    @Environment(\.palette) private var palette
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        SheetChrome(title: "Connect link cable") {
            if link.manualView { manual } else { shared }
            if !link.status.isEmpty {
                Text(link.status)
                    .font(.system(size: 12.5))
                    .foregroundColor(link.statusIsError ? palette.danger : palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            Button(link.manualView ? "Use a shared code instead" : "Trade codes manually instead") {
                if link.manualView { link.manualBack() } else { link.enterManual(attemptFailed: false) }
            }
            .font(.system(size: 12.5))
            .foregroundColor(palette.textDim)
            .underline()
            .padding(.top, 18)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true } }
        .onDisappear { link.sheetClosed() }
    }

    private var shared: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHint("Enter the same code as your friend. They can be on dingbat.gg in a browser or on this app.")
            HStack(spacing: 8) {
                field {
                    TextField("", text: $code, prompt: Text("e.g. ABC123").foregroundColor(palette.textFaint))
                        .textInputAutocapitalization(.characters)
                        .keyboardType(.asciiCapable)
                        .submitLabel(.go)
                        .focused($focused)
                        .disabled(link.connecting)
                        .onSubmit { link.connectTapped(code: code) }
                        .onChange(of: code) { c in if c.count > 12 { code = String(c.prefix(12)) } }
                        .accessibilityLabel("Link code")
                    if link.connecting { ProgressView().controlSize(.small) }
                }
                Button(link.connecting ? "Cancel" : "Connect") { link.connectTapped(code: code) }
                    .buttonStyle(SheetButtonStyle(kind: link.connecting ? .normal : .primary, small: false))
            }
        }
    }

    /// web #net-manual-view: no visible code box; ours is minted unseen and
    /// leaves by Share or Copy, the friend's goes in the field.
    private var manual: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetHint("Trade codes with your friend — any messenger works. Same Wi-Fi is the most reliable.")
            HStack(spacing: 8) {
                Button { link.shareCode() } label: {
                    HStack(spacing: 6) {
                        if link.manualCode == nil { ProgressView().controlSize(.mini) }
                        Text("Share code")
                    }
                }
                .buttonStyle(SheetButtonStyle(small: false, fill: true))
                Button("Copy code") { link.copyCode() }
                    .buttonStyle(SheetButtonStyle(small: false, fill: true))
            }
            .disabled(link.manualCode == nil)
            HStack(spacing: 8) {
                field {
                    TextField("", text: $link.friendCode, prompt: Text("Friend's code").foregroundColor(palette.textFaint))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        .submitLabel(.go)
                        .focused($focused)
                        .disabled(link.friendLocked)
                        .onSubmit { link.confirmManual() }
                        .accessibilityLabel("Friend's code")
                }
                Button("Confirm") { link.confirmManual() }
                    .buttonStyle(SheetButtonStyle(kind: .primary, small: false))
                    .disabled(link.friendLocked || link.manualCode == nil
                              || link.friendCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func field<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .autocorrectionDisabled()
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundColor(palette.text)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border2, lineWidth: 1))
    }
}
