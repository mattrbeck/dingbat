import CoreGraphics
import Foundation

/// The ambient glow behind the game (web/glpresent.js createGlowComposer, a
/// line-for-line port): a coarse sample of the picture, blurred and faded to
/// a soft ellipse, composed once per sample (10 Hz) and not at all while the
/// picture holds still. The model is the CSS the web replaced, in the box's
/// own points: the sw x sh sample stretched bilinearly over the box, a
/// Gaussian of sigma 32 pt with nothing outside the box, then
/// radial-gradient(ellipse at center, black 40%, transparent 78%) as alpha.
final class GlowComposer {
    private let sigmaPt: Float = 32
    private let texelsPerSigma: Float = 1.6   // the grid only has to hold a blurred image
    private let settled: Float = 0.25          // largest change, in 8-bit levels, not redrawn
    private let minSigma: Float = 0.8          // a sampled Gaussian narrower than this is not one

    let sw: Int, sh: Int
    private var ema: [Float]
    private var gw = 0, gh = 0, lw = 0, lh = 0, dirty = true
    private var work: [Float] = [], lo: [Float] = [], lotmp: [Float] = []
    private var ksx: [Float] = [], ksy: [Float] = [], kSigX: Float = 0, kSigY: Float = 0
    private var losum: [Float] = [], alpha: [Float] = []
    private var ux: Taps = .empty, uy: Taps = .empty, sx: Taps = .empty, sy: Taps = .empty
    private var pixels: [UInt8] = []

    private struct Taps {
        var i0: [Int], i1: [Int], f: [Float]
        static let empty = Taps(i0: [], i1: [], f: [])
    }

    init(sw: Int, sh: Int) {
        self.sw = sw
        self.sh = sh
        ema = [Float](repeating: 0, count: sw * sh * 3)
    }

    private func gauss(_ sigma: Float) -> [Float] {
        let rad = Int((3 * sigma).rounded(.up))
        var k = [Float](repeating: 0, count: 2 * rad + 1)
        var sum: Float = 0
        for i in -rad...rad {
            let v = exp(-Float(i * i) / (2 * sigma * sigma))
            k[i + rad] = v
            sum += v
        }
        return k.map { $0 / sum }
    }

    /// Weight of the kernel that lands inside [0, n) from texel i: the blur
    /// of the box's own (opaque) alpha.
    private func coverage(_ k: [Float], _ n: Int) -> [Float] {
        let rad = (k.count - 1) >> 1
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            for j in -rad...rad where i + j >= 0 && i + j < n { out[i] += k[j + rad] }
        }
        return out
    }

    /// Bilinear source taps for a stretch of `src` texels over `dst`, edges
    /// clamped, centres aligned.
    private func taps(_ src: Int, _ dst: Int) -> Taps {
        var t = Taps(i0: [Int](repeating: 0, count: dst), i1: [Int](repeating: 0, count: dst),
                     f: [Float](repeating: 0, count: dst))
        for i in 0..<dst {
            let s = min(Float(src - 1), max(0, (Float(i) + 0.5) * Float(src) / Float(dst) - 0.5))
            t.i0[i] = Int(s.rounded(.down))
            t.i1[i] = min(src - 1, t.i0[i] + 1)
            t.f[i] = s - Float(t.i0[i])
        }
        return t
    }

    /// Grid for a box of w x h points; an unchanged box costs nothing.
    func layout(width boxW: CGFloat, height boxH: CGFloat) {
        let cssW = Float(boxW), cssH = Float(boxH)
        guard cssW > 0, cssH > 0 else { return }
        let w = max(32, min(64, Int((texelsPerSigma * cssW / sigmaPt).rounded())))
        let h = max(16, min(64, Int((Float(w) * cssH / cssW).rounded())))
        // Blur and stretch are both linear, so the blur runs on the sample
        // (a big box first stretches it 2x or more so the kernel stays a
        // Gaussian) and the stretch to the grid follows.
        let mx = Int((minSigma * cssW / (sigmaPt * Float(sw))).rounded(.up))
        let my = Int((minSigma * cssH / (sigmaPt * Float(sh))).rounded(.up))
        let sigX = sigmaPt * Float(sw * mx) / cssW, sigY = sigmaPt * Float(sh * my) / cssH
        if w == gw && h == gh && lw == sw * mx && lh == sh * my &&
            abs(kSigX - sigX) < 0.02 && abs(kSigY - sigY) < 0.02 { return }
        gw = w; gh = h; lw = sw * mx; lh = sh * my; dirty = true
        ksx = gauss(sigX); kSigX = sigX
        ksy = gauss(sigY); kSigY = sigY
        let lcx = coverage(ksx, lw), lcy = coverage(ksy, lh)
        losum = [Float](repeating: 0, count: lw * lh)
        for y in 0..<lh { for x in 0..<lw { losum[y * lw + x] = lcx[x] * lcy[y] } }
        work = [Float](repeating: 0, count: lw * lh * 3)
        lo = work
        lotmp = work
        ux = taps(sw, lw)
        uy = taps(sh, lh)
        let cx = coverage(gauss(sigmaPt * Float(gw) / cssW), gw)
        let cy = coverage(gauss(sigmaPt * Float(gh) / cssH), gh)
        alpha = [Float](repeating: 0, count: gw * gh)
        for y in 0..<gh {
            let v = (Float(y) + 0.5) / Float(gh) - 0.5
            for x in 0..<gw {
                let u = (Float(x) + 0.5) / Float(gw) - 0.5
                // farthest-corner ellipse: radii sqrt(2) x the half box
                let t = Float(2).squareRoot() * (u * u + v * v).squareRoot()
                alpha[y * gw + x] = 255 * min(1, max(0, (0.78 - t) / 0.38)) * cx[x] * cy[y]
            }
        }
        sx = taps(lw, gw)
        sy = taps(lh, gh)
        pixels = [UInt8](repeating: 0, count: gw * gh * 4)
    }

    private func stretch(_ from: [Float], _ w: Int, _ to: inout [Float], _ dw: Int, _ dh: Int,
                         _ tx: Taps, _ ty: Taps) {
        for y in 0..<dh {
            let a0 = ty.i0[y] * w, a1 = ty.i1[y] * w, wy = ty.f[y]
            for x in 0..<dw {
                let wx = tx.f[x], q = (y * dw + x) * 3
                let p00 = (a0 + tx.i0[x]) * 3, p01 = (a0 + tx.i1[x]) * 3
                let p10 = (a1 + tx.i0[x]) * 3, p11 = (a1 + tx.i1[x]) * 3
                let w00 = (1 - wx) * (1 - wy), w01 = wx * (1 - wy), w10 = (1 - wx) * wy, w11 = wx * wy
                for c in 0..<3 {
                    to[q + c] = from[p00 + c] * w00 + from[p01 + c] * w01 + from[p10 + c] * w10 + from[p11 + c] * w11
                }
            }
        }
    }

    /// One sample: `rgba` is sw x sh RGBA8888 (R first). Saturation x1.5
    /// (luma kept), blended over the running picture at 0.3, or taken whole
    /// when `fresh`. The composed glow (premultiplied RGBA), or nil when
    /// nothing moved.
    func compose(_ rgba: UnsafePointer<UInt32>, fresh: Bool) -> CGImage? {
        guard gw > 0 else { return nil }
        var moved: Float = 0
        for i in 0..<(sw * sh) {
            let px = rgba[i]
            let r = Float(px & 255), g = Float((px >> 8) & 255), b = Float((px >> 16) & 255)
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            let s0 = min(255, max(0, luma + (r - luma) * 1.5))
            let s1 = min(255, max(0, luma + (g - luma) * 1.5))
            let s2 = min(255, max(0, luma + (b - luma) * 1.5))
            let o = i * 3
            if fresh { ema[o] = s0; ema[o + 1] = s1; ema[o + 2] = s2; continue }
            let d0 = (s0 - ema[o]) * 0.3, d1 = (s1 - ema[o + 1]) * 0.3, d2 = (s2 - ema[o + 2]) * 0.3
            ema[o] += d0; ema[o + 1] += d1; ema[o + 2] += d2
            moved = max(moved, abs(d0), abs(d1), abs(d2))
        }
        if !fresh && !dirty && moved < settled { return nil }
        dirty = false
        // The sample at blur resolution (itself, when the box is small enough).
        var src = ema
        if lw != sw || lh != sh {
            stretch(ema, sw, &work, lw, lh, ux, uy)
            src = work
        }
        // Blur: rows, then columns, zero outside the box, renormalised.
        let rx = (ksx.count - 1) >> 1, ry = (ksy.count - 1) >> 1
        for y in 0..<lh {
            for x in 0..<lw {
                var s0: Float = 0, s1: Float = 0, s2: Float = 0
                for j in max(-rx, -x)...min(rx, lw - 1 - x) {
                    let k = ksx[j + rx], p = (y * lw + x + j) * 3
                    s0 += src[p] * k; s1 += src[p + 1] * k; s2 += src[p + 2] * k
                }
                let q = (y * lw + x) * 3
                lotmp[q] = s0; lotmp[q + 1] = s1; lotmp[q + 2] = s2
            }
        }
        for y in 0..<lh {
            let j0 = max(-ry, -y), j1 = min(ry, lh - 1 - y)
            for x in 0..<lw {
                var s0: Float = 0, s1: Float = 0, s2: Float = 0
                for j in j0...j1 {
                    let k = ksy[j + ry], p = ((y + j) * lw + x) * 3
                    s0 += lotmp[p] * k; s1 += lotmp[p + 1] * k; s2 += lotmp[p + 2] * k
                }
                let n = 1 / losum[y * lw + x], q = (y * lw + x) * 3
                lo[q] = s0 * n; lo[q + 1] = s1 * n; lo[q + 2] = s2 * n
            }
        }
        // Stretch to the grid; the alpha is precomputed. Premultiplied for
        // Core Graphics.
        for y in 0..<gh {
            let a0 = sy.i0[y] * lw, a1 = sy.i1[y] * lw, wy = sy.f[y]
            for x in 0..<gw {
                let wx = sx.f[x]
                let p00 = (a0 + sx.i0[x]) * 3, p01 = (a0 + sx.i1[x]) * 3
                let p10 = (a1 + sx.i0[x]) * 3, p11 = (a1 + sx.i1[x]) * 3
                let w00 = (1 - wx) * (1 - wy), w01 = wx * (1 - wy), w10 = (1 - wx) * wy, w11 = wx * wy
                let k = y * gw + x, i = k * 4
                let a = alpha[k]
                for c in 0..<3 {
                    let v = lo[p00 + c] * w00 + lo[p01 + c] * w01 + lo[p10 + c] * w10 + lo[p11 + c] * w11
                    pixels[i + c] = UInt8(min(255, max(0, v * a / 255)))
                }
                pixels[i + 3] = UInt8(min(255, max(0, a)))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: gw, height: gh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: gw * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
