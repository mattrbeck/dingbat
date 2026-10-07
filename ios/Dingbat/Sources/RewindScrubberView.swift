import SwiftUI

/// Rewind to a moment (web #rewind-modal, openRewindScrubber on
/// createFilmStrip): the rewind ring's thumbnails as a film strip, oldest
/// left, now right. Dragging only paints thumbnails; the core goes back once,
/// on commit, which asks first — and asks again when the in-game save would
/// roll back with it.
struct RewindScrubberView: View {
    @ObservedObject private var settings = Settings.shared
    @Environment(\.palette) private var palette
    @State private var thumbs: [UIImage] = []
    @State private var tenths: [Int] = []
    /// Samples back from the newest: 0 = now.
    @State private var sel = 0
    /// 0 pick, 1 confirm the discard, 2 confirm the save loss.
    @State private var stage = 0

    private static let maxSamples = 96

    var body: some View {
        SheetChrome(title: "Rewind") {
            SheetHint(thumbs.count > 1
                      ? "Drag the strip, or the bar for longer jumps. Everything right of the line is discarded."
                      : settings.rewind ? "No rewind history yet — it builds up as you play."
                                        : "Rewind is off. Turn it on in Settings › General to keep a timeline you can go back through.")
            scrubBox
            if stage > 0 && sel > 0 {
                SheetWarning(text: stage == 1
                             ? "The last \(cost) will be thrown away. You will not be able to move forward again."
                             : "This also rolls your in-game save back to how it was \(cost) ago. Anything the game has saved to the cartridge since then will be gone.",
                             severe: stage == 2)
                    .padding(.top, 14)
            }
            HStack(spacing: 10) {
                Button("Cancel") { SheetNav.close() }
                    .buttonStyle(SheetButtonStyle(small: false))
                Button(commitLabel, action: commitTapped)
                    .buttonStyle(SheetButtonStyle(kind: stage > 0 ? .armed : .primary, small: false, fill: true))
                    .disabled(sel == 0)
            }
            .padding(.top, 14)
        }
        .onAppear(perform: load)
        .onChange(of: sel) { _ in stage = 0 }
    }

    private var cost: String { fmtDuration(tenths: tenthsAt(sel)) }

    private var commitLabel: String {
        if sel == 0 { return "Rewind to this point" }
        switch stage {
        case 0: return "Rewind to this point · discards \(cost)"
        case 1: return "Yes, discard \(cost)"
        default: return "Rewind and lose that save"
        }
    }

    private func tenthsAt(_ s: Int) -> Int { s > 0 && s < tenths.count ? tenths[s] : 0 }

    private var scrubBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Rewind to")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(palette.textDim)
                Spacer()
                Text(sel == 0 ? "now" : "\(cost) ago")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(palette.accent)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            preview
            if thumbs.count > 0 {
                FilmStrip(thumbs: thumbs, sel: $sel)
                    .frame(height: 44)
                HStack {
                    Text(thumbs.count > 1 ? "\(fmtDuration(tenths: tenthsAt(thumbs.count - 1))) ago" : "")
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 11))
                .foregroundColor(palette.textFaint)
                if thumbs.count > 1 {
                    Slider(value: Binding(
                        get: { Double(thumbs.count - 1 - sel) },
                        set: { sel = thumbs.count - 1 - Int($0.rounded()) }
                    ), in: 0...Double(thumbs.count - 1), step: 1)
                    .tint(palette.accent)
                    .accessibilityLabel("Rewind timeline")
                    .accessibilityValue(sel == 0 ? "now" : "\(cost) ago")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(palette.surface2))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.border, lineWidth: 1))
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(palette.stage)
            if sel < thumbs.count {
                Image(uiImage: thumbs[sel])
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .aspectRatio(thumbs.first.map { $0.size.width / max(1, $0.size.height) } ?? 1.5, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    private func load() {
        stage = 0
        sel = 0
        guard GameSession.shared.game != nil, settings.rewind else { return }
        let n = Int(dingbat_rewind_scrub_generate(Int32(Self.maxSamples)))
        guard n > 0, let base = dingbat_rewind_scrub_thumbs() else { return }
        let w = Int(dingbat_rewind_scrub_thumb_w()), h = Int(dingbat_rewind_scrub_thumb_h())
        var imgs: [UIImage] = []
        var ages: [Int] = []
        for i in 0..<n {
            guard let img = GameSession.bgr555Image(base + i * w * h * 2, width: w, height: h) else { break }
            imgs.append(img)
            ages.append(Int(dingbat_rewind_scrub_seconds_ago(Int32(i))))
        }
        thumbs = imgs
        tenths = ages
    }

    private func commitTapped() {
        guard sel > 0 else { return }
        if stage == 0 { stage = 1; return }
        if stage == 1 && dingbat_rewind_scrub_save_differs(Int32(sel)) == 1 { stage = 2; return }
        commit()
    }

    private func commit() {
        let session = GameSession.shared
        let what = cost
        let undo = session.captureState()   // where the game is now, before the cut
        guard dingbat_rewind_commit(Int32(sel)) == 1 else {
            SheetNav.close()
            AppModel.shared.toast("That moment is no longer in the rewind history")
            return
        }
        GameRenderer.shared.present()
        SheetNav.close()
        let game = session.game
        AppModel.shared.toast("Rewound \(what)", action: undo.map { u in
            ("Undo", {
                guard session.game == game else { return }
                // keepRewind: the ring still holds this state's past.
                if session.apply(state: u, keepRewind: true) == nil {
                    AppModel.shared.toast("Back to where you were")
                }
            })
        }, duration: 8, game: true)
    }
}

/// The strip itself: frames at a fixed pitch under a playhead that marks
/// the selected frame's right edge; the discarded future is greyed. A drag
/// scrolls the film under the line, a tap picks a frame.
private struct FilmStrip: View {
    let thumbs: [UIImage]   // newest first, as the core gives them
    @Binding var sel: Int
    @Environment(\.palette) private var palette
    @State private var dragStart: Int?

    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let n = thumbs.count
            let h = geo.size.height
            let aspect = thumbs.first.map { $0.size.width / max(1, $0.size.height) } ?? 1.5
            let fw = (h * aspect).rounded()
            let pitch = fw + gap
            let total = CGFloat(n) * pitch - gap
            let d = n - 1 - sel   // display index, oldest = 0
            let offset: CGFloat = total <= geo.size.width
                ? geo.size.width - total
                : min(0, max(geo.size.width - total, geo.size.width * 0.55 - CGFloat(d + 1) * pitch))
            let lineX = offset + CGFloat(d + 1) * pitch - gap
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for i in 0..<n {
                        let x = offset + CGFloat(i) * pitch
                        guard x + fw >= 0, x <= size.width else { continue }
                        let r = CGRect(x: x, y: 0, width: fw, height: h)
                        var c = ctx
                        if i > d {
                            c.addFilter(.grayscale(1))
                            c.opacity = 0.45
                        }
                        c.draw(c.resolve(Image(uiImage: thumbs[n - 1 - i]).interpolation(.none)), in: r)
                    }
                }
                Rectangle()
                    .fill(palette.accent)
                    .frame(width: 3, height: h + 6)
                    .shadow(color: palette.accentGlow, radius: 4)
                    .offset(x: lineX - 1.5, y: -3)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if dragStart == nil { dragStart = sel }
                    guard abs(v.translation.width) > 5, let s = dragStart else { return }
                    // Film moves right: older frames come under the line.
                    let step = Int((v.translation.width / pitch).rounded())
                    sel = min(n - 1, max(0, s + step))
                }
                .onEnded { v in
                    defer { dragStart = nil }
                    guard abs(v.translation.width) <= 5 else { return }
                    let i = Int(((v.location.x - offset) / pitch).rounded(.down))
                    if i >= 0 && i < n { sel = n - 1 - i }
                })
        }
        .clipped()
        .background(RoundedRectangle(cornerRadius: 4).fill(palette.stage))
    }
}
