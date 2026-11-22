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
    /// Where a finger left the strip's film; nil lets the strip frame the clip.
    @State private var held: CGFloat?

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
                    ClipStrip(thumbs: thumbs, inS: $inS, outS: $outS, active: $active, held: $held)
                        .frame(height: 48)
                    HStack {
                        Text(fmtDuration(tenths: tenths(ago.last ?? 0)) + " ago")
                        Spacer()
                        Text("now")
                    }
                    .font(.system(size: 11)).foregroundColor(palette.textFaint)
                    DualRange(count: thumbs.count, inS: $inS, outS: $outS, active: $active, held: $held)
                        .frame(height: 30)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 11).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.border, lineWidth: 1))
            HStack(spacing: 8) {
                PadButton("Last 10s") { preset(10) }
                PadButton("Last 30s") { preset(30) }
                PadButton("Everything") { preset(0) }
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
                PadButton("Cancel") { SheetNav.close() }
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
                PicturePreview(image: thumbs[s])
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
        held = nil
    }

    private func load() {
        guard GameSession.shared.game != nil else { return }
        let n = Int(dingbat_clip_scrub_generate(Int32(Self.maxSamples)))
        guard n > 0, let base = dingbat_clip_scrub_thumbs() else { return }
        defer { dingbat_clip_scrub_release() }
        let shades = GameSession.pictureShades(), lut = dingbat_color_lut()
        let w = Int(dingbat_clip_scrub_thumb_w()), h = Int(dingbat_clip_scrub_thumb_h())
        var imgs: [UIImage] = []
        var ages: [Int] = []
        for i in 0..<n {
            guard let img = GameSession.bgr555Image(base + i * w * h * 2, width: w, height: h, shades: shades, lut: lut) else { break }
            imgs.append(img)
            ages.append(Int(dingbat_clip_scrub_frames_ago(Int32(i))))
        }
        thumbs = imgs
        ago = ages
        outS = 0
        inS = max(1, min(n - 1, nearest(Self.quickSeconds)))
        active = 0
        held = nil
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

/// The strip (web createFilmStrip, direct): every second's picture on a film
/// at a fixed pitch, oldest left, the kept span in colour between two
/// markers. A drag begun on a marker carries it, the film scrolling while the
/// finger is held at either end; one begun anywhere else scrolls the film. A
/// tap moves the nearer marker to the frame under the finger.
private struct ClipStrip: View {
    let thumbs: [UIImage]   // newest first, as the core gives them
    @Binding var inS: Int
    @Binding var outS: Int
    @Binding var active: Int
    /// The film's offset once a finger has placed it; nil frames the clip.
    @Binding var held: CGFloat?
    @Environment(\.palette) private var palette
    @State private var grab: Grab?
    /// The carried marker mid-drag, in samples; it settles on a whole one.
    @State private var live: CGFloat?
    @GestureState private var pressed = false

    private static let gap: CGFloat = 2
    /// Half a marker's touch target (web STRIP_MARKER_REACH).
    private static let reach: CGFloat = 22
    private static let tapSlop: CGFloat = 5
    /// How near either end a carried marker scrolls the film, and how fast
    /// at the very edge (points a second).
    private static let edge: CGFloat = 28
    private static let edgeSpeed: CGFloat = 700

    private struct Grab {
        var marker: Int
        /// The press missed both markers: it has the film.
        var panning: Bool
        /// Finger x less the grabbed marker's, at the press.
        var dx: CGFloat
        var off: CGFloat
        var lastX: CGFloat
        var travel: CGFloat = 0
        var heading: CGFloat = 0
    }

    private struct Film {
        let n: Int
        let width: CGFloat
        let fw: CGFloat
        let fh: CGFloat
        var pitch: CGFloat { fw + ClipStrip.gap }

        /// A film shorter than the strip sits centred.
        func clamp(_ off: CGFloat) -> CGFloat {
            let slack = width - CGFloat(n) * pitch
            return slack >= 0 ? slack / 2 : min(0, max(slack, off))
        }
        /// Film x of a marker: the in point on its frame's left edge, the
        /// out point on its frame's right.
        func x(_ v: CGFloat, _ marker: Int) -> CGFloat { (CGFloat(marker == 0 ? n - 1 : n) - v) * pitch }
        func value(_ x: CGFloat, _ marker: Int) -> CGFloat { CGFloat(marker == 0 ? n - 1 : n) - x / pitch }
    }

    /// Eleven frames across (the quick range and both its brackets must land
    /// inside the width), no taller than the strip.
    private func film(_ size: CGSize) -> Film {
        let aspect = thumbs.first.map { $0.size.width / max(1, $0.size.height) } ?? 1.5
        let maxH = max(8, size.height - 6)
        var fw = min(40, max(26, size.width / 11)).rounded()
        fw = max(16, min(fw, (size.width / CGFloat(ClipRangeView.quickSeconds + 1)).rounded(.down) - Self.gap))
        var fh = (fw / aspect).rounded()
        if fh > maxH {
            fh = maxH
            fw = max(12, (fh * aspect).rounded())
        }
        return Film(n: thumbs.count, width: size.width, fw: fw, fh: fh)
    }

    private var values: [CGFloat] {
        var v = [CGFloat(inS), CGFloat(outS)]
        if let live, let g = grab, !g.panning { v[g.marker] = live }
        return v
    }

    /// The clip rides the middle when it fits, else the marker last moved,
    /// until the film runs out.
    private func offset(_ f: Film, _ v: [CGFloat]) -> CGFloat {
        if let held { return f.clamp(held) }
        let a = f.x(v[0], 0), b = f.x(v[1], 1)
        return f.clamp(f.width / 2 - (b - a <= f.width ? (a + b) / 2 : (active == 0 ? a : b)))
    }

    var body: some View {
        GeometryReader { geo in
            let f = film(geo.size)
            let v = values
            let off = offset(f, v)
            Canvas { ctx, size in
                draw(ctx, size, f, off, off + f.x(v[0], 0), off + f.x(v[1], 1))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($pressed) { _, on, _ in on = true }
                .onChanged { moved($0, f) }
                .onEnded { ended($0, f) })
            // A drag the sheet's scrolling took never ends; it only lets go.
            .onChange(of: pressed) { if !$0 { release() } }
            .task(id: grab.map { !$0.panning } ?? false) { await scrollAtEnds(f) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .background(RoundedRectangle(cornerRadius: 4).fill(palette.stage))
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ f: Film, _ off: CGFloat,
                      _ x0: CGFloat, _ x1: CGFloat) {
        let top = ((size.height - f.fh) / 2).rounded()
        func frames(_ c: GraphicsContext, _ a: CGFloat, _ b: CGFloat) {
            let first = max(0, Int(((a - off) / f.pitch).rounded(.down)))
            let last = min(f.n - 1, Int(((b - off) / f.pitch).rounded(.down)))
            guard first <= last else { return }
            for i in first...last {
                let r = CGRect(x: off + CGFloat(i) * f.pitch + Self.gap / 2, y: top, width: f.fw, height: f.fh)
                c.draw(c.resolve(Image(uiImage: thumbs[f.n - 1 - i]).interpolation(.high)), in: r)
            }
        }
        let (keptA, keptB) = (max(0, x0), min(size.width, x1))
        if keptB > keptA {
            var lit = ctx
            lit.clip(to: Path(CGRect(x: keptA, y: 0, width: keptB - keptA, height: size.height)))
            frames(lit, keptA, keptB)
        }
        // Outside the clip: grey and dark, never mistaken for the kept side.
        for (a, b) in [(0, min(x0, size.width)), (max(0, x1), size.width)] where b > a {
            let band = Path(CGRect(x: a, y: 0, width: b - a, height: size.height))
            var dim = ctx
            dim.clip(to: band)
            dim.addFilter(.grayscale(1))
            dim.opacity = 0.5
            frames(dim, a, b)
            ctx.fill(band, with: .color(.black.opacity(0.35)))
        }
        // A marker off the strip is not drawn: pinned to the edge it would
        // claim the clip ends there.
        for (i, x) in [x0, x1].enumerated() where x >= -1 && x <= size.width + 1 {
            let mx = min(max(x, 2), size.width - 2)
            var p = Path(CGRect(x: mx - 1.5, y: 0, width: 3, height: size.height))
            // Chevrons point into the clip.
            let d: CGFloat = i == 0 ? 1 : -1
            for y in [0, size.height - 9] {
                p.move(to: CGPoint(x: mx + d * 1.5, y: y))
                p.addLine(to: CGPoint(x: mx + d * 10.5, y: y + 4.5))
                p.addLine(to: CGPoint(x: mx + d * 1.5, y: y + 9))
                p.closeSubpath()
            }
            var m = ctx
            m.addFilter(.shadow(color: palette.accentGlow, radius: 3))
            m.fill(p, with: .color(palette.accent))
        }
    }

    private func nearest(_ x: CGFloat, _ xs: [CGFloat]) -> Int {
        abs(xs[0] - x) <= abs(xs[1] - x) ? 0 : 1
    }

    private func press(_ x: CGFloat, _ f: Film) -> Grab {
        let v = values, off = offset(f, v)
        let xs = [off + f.x(v[0], 0), off + f.x(v[1], 1)]
        let near = nearest(x, xs)
        let dx = x - xs[near]
        // A marker off the strip has no target to press.
        let panning = abs(dx) > Self.reach || xs[near] < -1 || xs[near] > f.width + 1
        if !panning { active = near }
        held = off
        return Grab(marker: near, panning: panning, dx: dx, off: off, lastX: x)
    }

    private func moved(_ e: DragGesture.Value, _ f: Film) {
        var g = grab ?? press(e.startLocation.x, f)
        let dx = e.location.x - g.lastX
        g.lastX = e.location.x
        g.travel += abs(dx)
        if dx != 0 { g.heading = dx < 0 ? -1 : 1 }
        if g.panning {
            g.off = f.clamp(g.off + dx)
            held = g.off
        } else if dx != 0 {
            carry(g, f)
        }
        grab = g
    }

    /// The grabbed marker goes where the finger is, over a film held still;
    /// neither marker crosses the other.
    private func carry(_ g: Grab, _ f: Film) {
        let lo = g.marker == 0 ? CGFloat(outS + 1) : 0
        let hi = g.marker == 0 ? CGFloat(f.n - 1) : CGFloat(inS - 1)
        let v = max(lo, min(hi, f.value(g.lastX - g.dx - g.off, g.marker)))
        live = v
        let s = Int(v.rounded())
        if g.marker == 0 {
            if inS != s { inS = s }
        } else if outS != s {
            outS = s
        }
    }

    /// While a marker is carried: a finger near either end, having moved
    /// toward it, scrolls the film that way, faster the nearer the edge, so a
    /// marker can be pulled past what is on screen.
    private func scrollAtEnds(_ f: Film) async {
        guard let g = grab, !g.panning else { return }
        var last = CACurrentMediaTime()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 16_000_000)
            let now = CACurrentMediaTime()
            let dt = min(0.05, now - last)
            last = now
            guard var g = grab, !g.panning else { return }
            let x = g.lastX
            let push: CGFloat = x < Self.edge && g.heading < 0 ? (Self.edge - x) / Self.edge
                : x > f.width - Self.edge && g.heading > 0 ? -(x - (f.width - Self.edge)) / Self.edge : 0
            let next = f.clamp(g.off + max(-1, min(1, push)) * Self.edgeSpeed * CGFloat(dt))
            guard next != g.off else { continue }
            g.off = next
            grab = g
            held = next
            carry(g, f)
        }
    }

    private func ended(_ e: DragGesture.Value, _ f: Film) {
        defer { release() }
        guard let g = grab, g.travel <= Self.tapSlop else { return }
        let v = values
        let m = g.panning ? nearest(e.location.x, [g.off + f.x(v[0], 0), g.off + f.x(v[1], 1)]) : g.marker
        let s = f.n - 1 - Int(((e.location.x - g.off) / f.pitch).rounded(.down))
        active = m
        if m == 0 { inS = min(f.n - 1, max(outS + 1, s)) } else { outS = max(0, min(inS - 1, s)) }
    }

    private func release() {
        grab = nil
        live = nil
    }
}

/// One rail, two knobs (web .dual-range): the knob nearer the finger moves.
private struct DualRange: View {
    let count: Int
    @Binding var inS: Int
    @Binding var outS: Int
    @Binding var active: Int
    @Binding var held: CGFloat?
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
                held = nil   // the strip goes to the marker that moved
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
                    FlappingBat().frame(width: 104, height: 56)
                    Text("Recording clip").font(.system(size: 17, weight: .semibold)).foregroundColor(palette.text)
                    Text(e.label).font(.system(size: 13)).foregroundColor(palette.textDim)
                    HStack(spacing: 12) {
                        ProgressView(value: e.progress).tint(palette.accent)
                        Text("\(Int(e.progress * 100))%")
                            .font(.system(size: 12, design: .monospaced)).foregroundColor(palette.textDim)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(width: 240)
                    PadButton("Cancel") { ClipExporter.shared.cancelExport() }
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

/// The dingbat flapping (web flap.png: 16 frames of 52x28 in 667 ms, at 2x).
/// The frame box is LaunchIntro.box, the strip both share. "FlapDusk" is the
/// dusk bat's beat, the link screen's friend; the "…Crown" strips are 5 rows
/// taller for a supporter's crown (tools/logo_flap/crown.py).
struct FlappingBat: View {
    var image = "Flap"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static var cache: [String: [UIImage]] = [:]

    private static func frames(_ name: String) -> [UIImage] {
        if let f = cache[name] { return f }
        guard let img = UIImage(named: name)?.cgImage else { return [] }
        let w = Int(LaunchIntro.box.width), h = img.height
        let f = (0..<16).compactMap { i in
            img.cropping(to: CGRect(x: i * w, y: 0, width: w, height: h)).map { UIImage(cgImage: $0) }
        }
        cache[name] = f
        return f
    }

    var body: some View {
        let frames = Self.frames(image)
        TimelineView(.periodic(from: .now, by: 0.667 / 16)) { ctx in
            let i = reduceMotion ? 0 : Int(ctx.date.timeIntervalSinceReferenceDate / (0.667 / 16)) % max(1, frames.count)
            if i < frames.count {
                Image(uiImage: frames[i]).resizable().interpolation(.none)
            }
        }
        .accessibilityHidden(true)
    }
}
