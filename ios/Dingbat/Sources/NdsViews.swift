import SwiftUI

// The DS game's own pieces of the play screen and Settings (web index.html
// #nds-panel, #nds-swap-btn / #nds-layout-btn, #nds-lid-open, #nds-off and
// Settings › Nintendo DS; styles.css "Nintendo DS").

// MARK: - Over the stage

/// The lid closed ("Lid closed · tap to open", a tap anywhere on the stage
/// opens it: a closed console has no touch screen to reach), and the
/// switched-off console's card with Restart and Library.
struct NdsStageLayers: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: GameSession
    @ObservedObject private var nds = NdsState.shared
    @Environment(\.palette) var palette

    var body: some View {
        ZStack {
            if nds.lidClosed && !nds.poweredOff {
                Button { nds.setLid(false) } label: {
                    Text("Lid closed · tap to open")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(palette.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.35))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if nds.poweredOff {
                Color.black.opacity(0.45)
                VStack(spacing: 0) {
                    Text("The game turned the DS off")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(palette.text)
                        .padding(.bottom, 6)
                    Text("Its save is kept. Restart to switch it on again.")
                        .font(.system(size: 14))
                        .foregroundColor(palette.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 16)
                    HStack(spacing: 10) {
                        PadButton("Restart") { session.ndsRestart() }
                            .buttonStyle(SheetButtonStyle(kind: .primary, small: false))
                        PadButton("Library") {
                            model.closeGame()
                            withAnimation(.easeOut(duration: 0.25)) { model.screen = .home }
                        }
                        .buttonStyle(SheetButtonStyle(small: false))
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 22)
                .frame(maxWidth: 320)
                .background(RoundedRectangle(cornerRadius: 14).fill(palette.surface2))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
                .padding(16)
            }
        }
    }
}

// MARK: - The bar

/// The swap and screens buttons (web #nds-swap-btn, #nds-layout-btn): a DS
/// game in front of you only.
struct NdsBarButtons: View {
    @ObservedObject private var nds = NdsState.shared

    var body: some View {
        BarIconButton(system: "arrow.up.arrow.down", label: "Swap the DS screens", active: nds.swap, saysOn: true) {
            nds.swapScreens()
        }
        BarIconButton(system: nds.layout.mode == .side ? "rectangle.split.2x1" : "rectangle.split.1x2",
                      label: "DS screens", active: nds.panelOpen) {
            withAnimation(.easeOut(duration: 0.15)) { nds.panelOpen.toggle() }
        }
    }
}

/// The Screens panel under the bar's screens button (web #nds-panel): the
/// arrangement, gap and turn, Swap / Close the lid / Blow, and on a phone
/// "Hide the top bar". It does not pause: the game shows each choice live.
/// A tap outside closes it.
struct NdsPanel: View {
    @ObservedObject private var nds = NdsState.shared
    @ObservedObject private var mic = NdsMic.shared
    @Environment(\.palette) var palette
    @Environment(\.horizontalSizeClass) var hSize
    @GestureState private var blowHeld = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(alignment: .leading, spacing: 12) {
                group("Screens") {
                    ChipFlow(spacing: 6) {
                        ForEach(NdsUtil.Arrangement.allCases, id: \.self) { a in
                            SheetChip(label: a.label, selected: nds.arrangement == a) { nds.arrangement = a }
                        }
                    }
                }
                group("Gap") {
                    ChipFlow(spacing: 6) {
                        ForEach(NdsUtil.Gap.allCases, id: \.self) { g in
                            SheetChip(label: g.label, selected: nds.gap == g) { nds.gap = g }
                        }
                    }
                }
                group("Turn") {
                    ChipFlow(spacing: 6) {
                        ForEach(NdsUtil.rotations, id: \.self) { r in
                            SheetChip(label: NdsUtil.rotLabel(r), selected: nds.rot == r) { nds.rot = r }
                        }
                    }
                }
                ChipFlow(spacing: 8) {
                    PadButton("Swap screens") { nds.swapScreens() }
                        .buttonStyle(SheetButtonStyle())
                    PadButton(nds.lidClosed ? "Open the lid" : "Close the lid") { nds.setLid(!nds.lidClosed) }
                        .buttonStyle(SheetButtonStyle(kind: nds.lidClosed ? .primary : .normal))
                    micButton
                    blowButton
                }
                if UIDevice.current.userInterfaceIdiom == .phone {
                    HStack(spacing: 12) {
                        Text("Hide the top bar (phone held upright)")
                            .font(.system(size: 13.5))
                            .foregroundColor(palette.text)
                        Spacer(minLength: 0)
                        Toggle("", isOn: $nds.barHide)
                            .labelsHidden()
                            .toggleStyle(SheetSwitchStyle())
                            .accessibilityLabel("Hide the top bar")
                    }
                }
            }
            .padding(14)
            .frame(width: 340)
            .background(RoundedRectangle(cornerRadius: 14).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.border2, lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
            .padding(.top, 58)
            .padding(.trailing, 10)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
        }
        .environment(\.padScope, "nds-panel")
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { nds.panelOpen = false }
    }

    private func group<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundColor(palette.textDim)
            content()
        }
    }

    /// The live microphone, a toggle; its fill is the level (web
    /// [data-nds-action="mic"]).
    private var micButton: some View {
        Button { mic.toggle() } label: {
            Text("Microphone")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(mic.on ? palette.accent : palette.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 8).fill(palette.surface3)
                            if mic.on {
                                Rectangle().fill(palette.accent.opacity(0.2))
                                    .frame(width: g.size.width * mic.level)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    })
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(mic.on ? palette.accent.opacity(0.55) : palette.border2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Microphone")
        .accessibilityValue(mic.on ? "On" : "Off")
    }

    /// Blow, held: noise into the microphone while the finger stays down
    /// (web [data-nds-action="blow"]).
    private var blowButton: some View {
        Text("Blow")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(blowHeld ? palette.accent : palette.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface3))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(blowHeld ? palette.accent.opacity(0.55) : palette.border2, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).updating($blowHeld) { _, held, _ in held = true })
            .onChange(of: blowHeld) { nds.blow("panel", $0) }
            .onDisappear { nds.blow("panel", false) }
            .accessibilityLabel("Blow: hold to blow into the microphone")
            .accessibilityAddTraits(.isButton)
    }
}

/// Chips that wrap onto further lines (web .chip-row flex-wrap).
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let h = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let w = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - s.height) / 2), proposal: .unspecified)
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + s.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
