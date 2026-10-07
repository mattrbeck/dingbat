import SwiftUI

/// "Save a Clip" (web #clip-modal): two markers over the clip ring's strip
/// (one picture a second, the last minute), presets, and what it will cost.
struct ClipRangeView: View {
    @Environment(\.palette) private var palette
    @State private var thumbs: [UIImage] = []
    /// Frames-ago of each sample, newest first.
    @State private var ago: [Int] = []
    /// Samples back from the newest: the in point (first frame kept) and the
    /// out point (last kept; 0 is now). inS > outS.
    @State private var inS = 1
    @State private var outS = 0
    /// Which marker the preview shows (the last one moved).
    @State private var active = 0

    static let maxSamples = 96
    static let quickSeconds = 10

    var body: some View {
        SheetChrome(title: "Save a Clip") {
            SheetHint(thumbs.count > 1
                      ? "Drag either marker, or either knob on the slider. Everything between them is saved."
                      : "No gameplay history yet — it builds up as you play.")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Clip").font(.system(size: 12.5, weight: .semibold)).foregroundColor(palette.textDim)
                    Spacer()
                    Text(whenText)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundColor(palette.accent)
                }
                preview
                Text(active == 0 ? "first frame of the clip" : "last frame of the clip")
                    .font(.system(size: 11)).foregroundColor(palette.textFaint)
                    .frame(maxWidth: .infinity)
                if thumbs.count > 1 {
                    ClipStrip(thumbs: thumbs, inS: $inS, outS: $outS, active: $active)
                        .frame(height: 40)
                    HStack {
                        Text(fmtDuration(tenths: tenths(ago.last ?? 0)) + " ago")
                        Spacer()
                        Text("now")
                    }
                    .font(.system(size: 11)).foregroundColor(palette.textFaint)
                    DualRange(count: thumbs.count, inS: $inS, outS: $outS, active: $active)
                        .frame(height: 30)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 11).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.border, lineWidth: 1))
            HStack(spacing: 8) {
                Button("Last 10s") { preset(10) }
                Button("Last 30s") { preset(30) }
                Button("Everything") { preset(0) }
            }
            .buttonStyle(SheetButtonStyle())
            .padding(.top, 12)
            .disabled(thumbs.count <= 1)
            if len > 0 {
                Text(String(format: "%.1fs of video, roughly %d MB. It records off screen; you'll see how far along it is.",
                            Double(len) / 60, max(1, Int((Double(len) / 60).rounded()))))
                    .font(.system(size: 12)).foregroundColor(palette.textDim)
                    .padding(.top, 10)
            }
            HStack(spacing: 10) {
                Button("Cancel") { SheetNav.close() }
                    .buttonStyle(SheetButtonStyle(small: false))
                Button("Save this clip", action: save)
                    .buttonStyle(SheetButtonStyle(kind: .primary, small: false, fill: true))
                    .disabled(len <= 0)
            }
            .padding(.top, 14)
        }
        .onAppear(perform: load)
    }

    private func tenths(_ frames: Int) -> Int { Int((Double(frames) * 10 / 60).rounded()) }

    private func agoAt(_ s: Int, out: Bool) -> Int {
        if out && s <= 0 { return 0 }
        guard !ago.isEmpty else { return 0 }
        return ago[min(max(s, 0), ago.count - 1)]
    }
    private var start: Int { agoAt(inS, out: false) }
    private var end: Int { agoAt(outS, out: true) }
    private var len: Int { max(0, start - end) }

    private var whenText: String {
        end == 0 ? "the last " + fmtDuration(tenths: tenths(len))
            : fmtDuration(tenths: tenths(start)) + " to " + fmtDuration(tenths: tenths(end)) + " ago · " + fmtDuration(tenths: tenths(len))
    }

    private var preview: some View {
        let s = active == 0 ? inS : outS
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(palette.stage)
            if s < thumbs.count {
                Image(uiImage: thumbs[s]).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
            }
        }
        .aspectRatio(thumbs.first.map { $0.size.width / max(1, $0.size.height) } ?? 1.5, contentMode: .fit)
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    /// The sample closest to `seconds` back; 0 = everything.
    private func nearest(_ seconds: Int) -> Int {
        guard !ago.isEmpty else { return 0 }
        if seconds <= 0 { return ago.count - 1 }
        let want = seconds * 60
        var best = 0
        for i in 1..<ago.count where abs(ago[i] - want) < abs(ago[best] - want) { best = i }
        return best
    }

    private func preset(_ seconds: Int) {
        guard thumbs.count > 1 else { return }
        outS = 0
        inS = max(1, nearest(seconds))
        active = 0
    }

    private func load() {
        guard GameSession.shared.game != nil else { return }
        let n = Int(dingbat_clip_scrub_generate(Int32(Self.maxSamples)))
        guard n > 0, let base = dingbat_clip_scrub_thumbs() else { return }
        let w = Int(dingbat_clip_scrub_thumb_w()), h = Int(dingbat_clip_scrub_thumb_h())
        var imgs: [UIImage] = []
        var ages: [Int] = []
        for i in 0..<n {
            guard let img = GameSession.bgr555Image(base + i * w * h * 2, width: w, height: h) else { break }
            imgs.append(img)
            ages.append(Int(dingbat_clip_scrub_frames_ago(Int32(i))))
        }
        thumbs = imgs
        ago = ages
        outS = 0
        inS = max(1, min(n - 1, nearest(Self.quickSeconds)))
        active = 0
    }

    private func save() {
        guard len > 0 else { return }
        let seconds = max(1, Int((Double(len) / 60).rounded()))
        let (s, e) = (start, end)
        SheetNav.close()
        // After the sheet is gone: the replay owns the core from here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            ClipExporter.shared.exportClip(startAgo: s, endAgo: e, slug: "clip\(seconds)s",
                                           label: e == 0 ? "The last \(seconds)s" : "\(seconds)s of gameplay")
        }
    }
}

/// The strip: every second's picture, oldest left, the kept span bright and
/// bracketed, the rest dimmed. A tap moves the nearer marker.
private struct ClipStrip: View {
    let thumbs: [UIImage]
    @Binding var inS: Int
    @Binding var outS: Int
    @Binding var active: Int
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            let n = thumbs.count
            let pitch = geo.size.width / CGFloat(n)
            let h = geo.size.height
            let dIn = n - 1 - inS, dOut = n - 1 - outS   // display indexes, oldest = 0
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for i in 0..<n {
                        let r = CGRect(x: CGFloat(i) * pitch, y: 0, width: pitch + 0.5, height: h)
                        var c = ctx
                        if i < dIn || i > dOut { c.opacity = 0.35 }
                        c.draw(c.resolve(Image(uiImage: thumbs[n - 1 - i]).interpolation(.none)), in: r)
                    }
                }
                marker(x: CGFloat(dIn) * pitch, h: h)
                marker(x: CGFloat(dOut + 1) * pitch - 3, h: h)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let d = min(n - 1, max(0, Int(v.location.x / pitch)))
                let s = n - 1 - d
                // The nearer marker moves; neither crosses the other.
                if v.translation == .zero {
                    active = abs(d - dIn) <= abs(d - dOut) ? 0 : 1
                }
                if active == 0 { inS = max(outS + 1, s) } else { outS = min(inS - 1, s) }
            })
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .background(RoundedRectangle(cornerRadius: 4).fill(palette.stage))
    }

    private func marker(x: CGFloat, h: CGFloat) -> some View {
        Rectangle()
            .fill(palette.accent)
            .frame(width: 3, height: h)
            .shadow(color: palette.accentGlow, radius: 3)
            .offset(x: x)
    }
}

/// One rail, two knobs (web .dual-range): the knob nearer the finger moves.
private struct DualRange: View {
    let count: Int
    @Binding var inS: Int
    @Binding var outS: Int
    @Binding var active: Int
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 22
            let span = max(1, geo.size.width - knob)
            let maxSlot = CGFloat(max(1, count - 1))
            // Slots run oldest (0) to now (count-1).
            let xIn = CGFloat(count - 1 - inS) / maxSlot * span
            let xOut = CGFloat(count - 1 - outS) / maxSlot * span
            ZStack(alignment: .leading) {
                Capsule().fill(palette.surface3).frame(height: 4).padding(.horizontal, knob / 2)
                Capsule().fill(palette.accent)
                    .frame(width: max(0, xOut - xIn), height: 4)
                    .offset(x: knob / 2 + xIn)
                knobView.offset(x: xIn)
                knobView.offset(x: xOut)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let slot = Int(((v.location.x - knob / 2) / span * maxSlot).rounded())
                let s = count - 1 - min(count - 1, max(0, slot))
                if v.translation == .zero {
                    active = abs(v.location.x - knob / 2 - xIn) <= abs(v.location.x - knob / 2 - xOut) ? 0 : 1
                }
                if active == 0 { inS = max(outS + 1, s) } else { outS = min(inS - 1, s) }
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Clip range")
    }

    private var knobView: some View {
        Circle().fill(palette.accent2)
            .overlay(Circle().stroke(palette.accentInk.opacity(0.35), lineWidth: 1))
            .frame(width: 22, height: 22)
    }
}

/// The clip being made (web #clip-progress-modal): the replay is neither
/// shown nor heard; this says how far along it is.
struct ClipProgressView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var clips = ClipExporter.shared

    var body: some View {
        if let e = clips.export {
            ZStack {
                palette.stage.opacity(0.92).ignoresSafeArea()
                VStack(spacing: 10) {
                    FlappingBat().frame(width: 112, height: 80)
                    Text("Recording clip").font(.system(size: 17, weight: .semibold)).foregroundColor(palette.text)
                    Text(e.label).font(.system(size: 13)).foregroundColor(palette.textDim)
                    HStack(spacing: 12) {
                        ProgressView(value: e.progress).tint(palette.accent)
                        Text("\(Int(e.progress * 100))%")
                            .font(.system(size: 12, design: .monospaced)).foregroundColor(palette.textDim)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(width: 240)
                    Button("Cancel") { ClipExporter.shared.cancelExport() }
                        .buttonStyle(SheetButtonStyle())
                        .padding(.top, 6)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 16).fill(palette.surface1))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.border2, lineWidth: 1))
            }
        }
    }
}

/// The dingbat flapping (web flap.png: 16 frames of 56x40 in 667 ms).
struct FlappingBat: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let frames: [UIImage] = {
        guard let img = UIImage(named: "Flap")?.cgImage else { return [] }
        return (0..<16).compactMap { i in
            img.cropping(to: CGRect(x: i * 56, y: 0, width: 56, height: 40)).map { UIImage(cgImage: $0) }
        }
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.667 / 16)) { ctx in
            let i = reduceMotion ? 0 : Int(ctx.date.timeIntervalSinceReferenceDate / (0.667 / 16)) % max(1, Self.frames.count)
            if i < Self.frames.count {
                Image(uiImage: Self.frames[i]).resizable().interpolation(.none)
            }
        }
        .accessibilityHidden(true)
    }
}
