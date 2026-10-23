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
        SheetChrome(title: "Connect link cable", fit: true) {
            if link.transferring { LinkTransferScene() } else if link.manualView { manual } else { shared }
            if !link.status.isEmpty {
                Text(link.status)
                    .font(.system(size: 12.5))
                    .foregroundColor(link.statusIsError ? palette.danger : palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            if !link.transferring {
                Button(link.manualView ? "Use a shared code instead" : "Trade codes manually instead") {
                    if link.manualView { link.manualBack() } else { link.enterManual(attemptFailed: false) }
                }
                .font(.system(size: 12.5))
                .foregroundColor(palette.textDim)
                .underline()
                .padding(.top, 18)
            }
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
                PadButton("Copy code") { link.copyCode() }
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
                PadButton("Confirm") { link.confirmManual() }
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

/// web #net-transfer: while the games cross the network, you (the purple
/// bat) and your friend (the dusk bat) either end of the link cable, bits
/// running both ways along it.
struct LinkTransferScene: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            end("Flap", "You")
            TimelineView(.animation(paused: reduceMotion)) { ctx in
                Canvas { g, _ in draw(g, t: ctx.date.timeIntervalSinceReferenceDate) }
            }
            .frame(width: 140, height: 68)
            .accessibilityHidden(true)
            end("FlapDusk", "Your friend")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func end(_ image: String, _ name: String) -> some View {
        VStack(spacing: 6) {
            FlappingBat(image: image).frame(width: 104, height: 56)
            Text(name).font(.system(size: 12, weight: .semibold)).foregroundColor(palette.textDim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }

    // The web's cable: M6 34 C 40 58, 100 10, 134 34 in a 140 x 68 box.
    private static let p0 = CGPoint(x: 6, y: 34), p1 = CGPoint(x: 40, y: 58)
    private static let p2 = CGPoint(x: 100, y: 10), p3 = CGPoint(x: 134, y: 34)

    private static func at(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    private func draw(_ g: GraphicsContext, t: TimeInterval) {
        var cable = Path()
        cable.move(to: Self.p0)
        cable.addCurve(to: Self.p3, control1: Self.p1, control2: Self.p2)
        g.stroke(cable, with: .color(palette.textFaint), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        for x in [0.0, 131.0] {
            g.fill(Path(roundedRect: CGRect(x: x, y: 28, width: 9, height: 12), cornerRadius: 2),
                   with: .color(palette.surface3))
        }
        let phase = reduceMotion ? 0 : CGFloat(t.truncatingRemainder(dividingBy: 1.6) / 1.6)
        for k in 0..<3 {
            let s = (phase + CGFloat(k) / 3).truncatingRemainder(dividingBy: 1)
            let out = Self.at(s), back = Self.at(1 - (s + 1.0 / 6).truncatingRemainder(dividingBy: 1))
            g.fill(Path(CGRect(x: out.x - 2.5, y: out.y - 2.5, width: 5, height: 5)), with: .color(palette.accent))
            g.fill(Path(CGRect(x: back.x - 2.5, y: back.y - 2.5, width: 5, height: 5)), with: .color(Color(hex: 0xFFCF4A)))
        }
    }
}
