import Metal

/// The DS's 3D drawn by Metal (docs/nds/gpu3d.md): web/nds/gpu3d.js ported,
/// fed by the same export (dingbat_nds_gpu_*, src/dingbat_ios.nim). After a
/// frame runs, `encode` draws its 3D scene at k x 256x192 and composites it
/// with engine A's 2D layers into `screens` (R16Uint BGR555, 256k x 384k,
/// top over bottom), the texture the presenter shows. The core's own 1x
/// picture stays the machine's; this one is for display only.
///
/// The CPU side is the web renderer's setScene: vertices placed at k, each
/// polygon's extent, its rows' records and the tiles its box touches (the
/// raster kernel's bins). Each frame's inputs go to one of three sets of
/// shared buffers (the frames the GPU may still be reading); the rest
/// (records, raster target, 3D frame, the banks' HD copies) live on the GPU.
/// Every pass is a compute kernel (NdsGpu3dShader.swift) in one serial
/// encoder, so each sees the one before it.
final class NdsGpu3d {
    static let header = 48, polyWords = 4, vertWords = 8
    static let maxPolys = 2048
    static let tileW = 32, tileH = 8
    static let maxBins = 1 << 22

    enum Failure: Error { case noDevice, library(String), pipeline(String), scene(String) }

    let device: MTLDevice
    private let rowsPS, rasterPS, postPS, compositePS, capturePS: MTLComputePipelineState

    /// The picture: both screens at k (nil until the first frame at this k).
    private(set) var screens: MTLTexture?
    private(set) var k = 0

    // The last frame drawn: the export's frame count, scene generation,
    // whether it had late parts (render-register writes mid-frame).
    // (the frame is the export's epoch, process-wide and never repeated: a
    // core's frame count starts again at each new game)
    private var drawnEpoch: Int64 = -1, gen: Int64 = -1, hadLate = false

    // Per scale, on the GPU.
    private var rast, out3d: MTLBuffer?
    private var recs: MTLBuffer?
    private var recCap = 0
    private var caps: [(cur: MTLBuffer, next: MTLBuffer)] = []
    private var tilesX = 0, tilesY = 0

    // CPU-side scratch for setScene.
    private var tileCounts: [UInt32] = []
    private var box: [Int32] = []

    /// One render's inputs (a frame has one, or more with late parts).
    private final class SceneBufs {
        let polys, geo: MTLBuffer
        var verts: MTLBuffer, vertCap: Int
        var bins: MTLBuffer, binCap: Int
        var head: MTLBuffer?, headTiles = 0
        var recPoly: MTLBuffer, recPolyCap: Int
        var u = [UInt32](repeating: 0, count: 48)   // U in the shader
        var recTotal = 0
        init(_ d: MTLDevice) {
            polys = d.makeBuffer(length: NdsGpu3d.maxPolys * 16, options: .storageModeShared)!
            geo = d.makeBuffer(length: NdsGpu3d.maxPolys * 32, options: .storageModeShared)!
            vertCap = 6144
            verts = d.makeBuffer(length: vertCap * 32, options: .storageModeShared)!
            binCap = 1 << 16
            bins = d.makeBuffer(length: binCap * 4, options: .storageModeShared)!
            recPolyCap = 1 << 14
            recPoly = d.makeBuffer(length: recPolyCap * 4, options: .storageModeShared)!
        }
    }

    /// One frame's inputs.
    private final class Slot {
        var scenes: [SceneBufs] = []
        let vram, pal, screens1x, plane, plane2, lines: MTLBuffer
        var texVer: Int64 = -1, epoch: Int64 = -1
        init(_ d: MTLDevice) {
            vram = d.makeBuffer(length: 0x80000, options: .storageModeShared)!
            pal = d.makeBuffer(length: 0x18000, options: .storageModeShared)!
            screens1x = d.makeBuffer(length: 256 * 384 * 2, options: .storageModeShared)!
            plane = d.makeBuffer(length: 256 * 192 * 16, options: .storageModeShared)!
            plane2 = d.makeBuffer(length: 256 * 192 * 16, options: .storageModeShared)!
            lines = d.makeBuffer(length: 192 * 32, options: .storageModeShared)!
        }
    }
    private var slots: [Slot] = []
    private var slotAt = 0
    private let inFlight = DispatchSemaphore(value: 3)

    /// Measurements only (tools/gpu3d/metal --ablate): passes left out, 1
    /// rows, 2 raster, 4 post, 8 composite, 16 capture.
    var ablate = 0

    /// What the last encode did (for measurements).
    struct Stats { var drew = false, renders = 0, polys = 0, recs = 0, bins = 0, captured = false, cpuMs = 0.0 }
    private(set) var last = Stats()

    init(device: MTLDevice) throws {
        self.device = device
        let opts = MTLCompileOptions()
        // (pfac's float guess is corrected in integers, but keep it IEEE)
        if #available(iOS 18.0, macOS 15.0, *) { opts.mathMode = .safe } else { opts.fastMathEnabled = false }
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: ndsGpu3dShaderSource, options: opts) }
        catch { throw Failure.library("\(error)") }
        func ps(_ name: String) throws -> MTLComputePipelineState {
            guard let f = lib.makeFunction(name: name) else { throw Failure.pipeline(name) }
            do { return try device.makeComputePipelineState(function: f) }
            catch { throw Failure.pipeline("\(name): \(error)") }
        }
        rowsPS = try ps("nds_rows")
        rasterPS = try ps("nds_raster")
        postPS = try ps("nds_post")
        compositePS = try ps("nds_composite")
        capturePS = try ps("nds_capture")
        slots = (0..<3).map { _ in Slot(device) }
    }

    func setScale(_ k: Int, _ cb: MTLCommandBuffer) {
        if k == self.k { return }
        self.k = k
        let W = 256 * k, H = 192 * k, n = 256 * k
        rast = device.makeBuffer(length: W * H * 16, options: .storageModePrivate)
        out3d = device.makeBuffer(length: W * H * 4, options: .storageModePrivate)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: W, height: 2 * H, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite]
        td.storageMode = .private
        screens = device.makeTexture(descriptor: td)
        // banks A-D's HD copies, current and next, zero to start (as the
        // web's are made)
        caps = (0..<4).map { _ in
            (device.makeBuffer(length: n * n * 2, options: .storageModePrivate)!,
             device.makeBuffer(length: n * n * 2, options: .storageModePrivate)!)
        }
        if let blit = cb.makeBlitCommandEncoder() {
            for c in caps {
                blit.fill(buffer: c.cur, range: 0..<c.cur.length, value: 0)
                blit.fill(buffer: c.next, range: 0..<c.next.length, value: 0)
            }
            blit.fill(buffer: out3d!, range: 0..<out3d!.length, value: 0)
            blit.endEncoding()
        }
        tilesX = (W + Self.tileW - 1) / Self.tileW
        tilesY = (H + Self.tileH - 1) / Self.tileH
        tileCounts = [UInt32](repeating: 0, count: tilesX * tilesY)
        drawnEpoch = -1; gen = -1; hadLate = false
    }

    /// This frame's work, after dingbat_run_frame, into cb (whose
    /// completion frees its inputs). Returns the screens, or nil when the
    /// core exports nothing (the GPU path off, or no frame yet).
    func encode(_ cb: MTLCommandBuffer, k: Int) throws -> MTLTexture? {
        setScale(k, cb)
        if dingbat_nds_gpu_frames() == 0 { return nil }
        let epoch0 = Int64(dingbat_nds_gpu_epoch())
        if epoch0 == drawnEpoch { last = Stats(); return screens }
        let t0 = DispatchTime.now().uptimeNanoseconds
        drawnEpoch = epoch0
        inFlight.wait()
        cb.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        slotAt = (slotAt + 1) % slots.count
        let slot = slots[slotAt]
        var st = Stats()
        guard let enc = cb.makeComputeCommandEncoder(dispatchType: .serial) else { return nil }
        defer { enc.endEncoding() }

        // the scene, when it is a new one (late parts this frame or the
        // last one drawn: out3d holds a mix; a frame the CPU drew whole
        // exports none, its lines show the core's screens as they are)
        if let sp = dingbat_nds_gpu_scene() {
            let len = Int(dingbat_nds_gpu_scene_len())
            let g: Int64 = len > 6 ? Int64(sp[6]) : -1
            let lateN = Int(dingbat_nds_gpu_late_count())
            if dingbat_nds_gpu_frame_cpu() == 0 && (g < 0 || g != gen || lateN > 0 || hadLate) {
                let texVer = Int64(sp[7])
                if texVer != slot.texVer, let tex = dingbat_nds_gpu_tex(), let pal = dingbat_nds_gpu_pal() {
                    slot.vram.contents().copyMemory(from: tex, byteCount: 0x80000)
                    slot.pal.contents().copyMemory(from: pal, byteCount: 0x18000)
                    slot.texVer = texVer
                }
                var parts: [(UnsafePointer<UInt32>, Int, Int)] = [(sp, len, 0)]
                for i in 0..<lateN {
                    parts.append((dingbat_nds_gpu_late(Int32(i))!, Int(dingbat_nds_gpu_late_len(Int32(i))),
                                  Int(dingbat_nds_gpu_late_line(Int32(i)))))
                }
                while slot.scenes.count < parts.count { slot.scenes.append(SceneBufs(device)) }
                for (i, p) in parts.enumerated() {
                    let sb = slot.scenes[i]
                    st.bins += try setScene(sb, p.0, p.1)
                    let to = i + 1 < parts.count ? parts[i + 1].2 : 192
                    render(enc, slot, sb, from: p.2, to: to)
                    st.polys += Int(p.0[1]); st.recs += sb.recTotal
                }
                st.drew = true; st.renders = parts.count
                gen = g
                hadLate = lateN > 0
            }
        }

        // engine A: the 1x screens, the planes' rows written since this
        // slot's last upload, the lines
        if let fb = dingbat_game_fb() {
            slot.screens1x.contents().copyMemory(from: fb, byteCount: 256 * 384 * 2)
        }
        let epoch = Int64(dingbat_nds_gpu_epoch())
        for second in 0..<2 {
            guard let data = dingbat_nds_gpu_plane(Int32(second)), let rows = dingbat_nds_gpu_rows(Int32(second)) else { continue }
            let dst = (second == 0 ? slot.plane : slot.plane2).contents().assumingMemoryBound(to: UInt32.self)
            var y = 0
            while y < 192 {
                if slot.epoch >= 0 && Int64(rows[y]) <= slot.epoch { y += 1; continue }
                var e = y + 1
                while e < 192 && (slot.epoch < 0 || Int64(rows[e]) > slot.epoch) { e += 1 }
                (dst + y * 1024).update(from: data + y * 1024, count: (e - y) * 1024)
                y = e
            }
        }
        slot.epoch = epoch
        // (no lines: nothing composited into screens this frame; a new
        // scale's texture holds nothing yet)
        guard let lp = dingbat_nds_gpu_lines() else { return nil }
        slot.lines.contents().copyMemory(from: lp, byteCount: 192 * 32)

        var u = [UInt32](repeating: 0, count: 48)
        u[41] = UInt32(k)
        func comp() {
            enc.setBuffer(slot.screens1x, offset: 0, index: 1)
            enc.setBuffer(slot.plane, offset: 0, index: 2)
            enc.setBuffer(slot.plane2, offset: 0, index: 3)
            enc.setBuffer(slot.lines, offset: 0, index: 4)
            enc.setBuffer(out3d, offset: 0, index: 5)
            for b in 0..<4 { enc.setBuffer(caps[b].cur, offset: 0, index: 6 + b) }
        }
        enc.setComputePipelineState(compositePS)
        enc.setBytes(u, length: 192, index: 0)
        comp()
        enc.setTexture(screens, index: 0)
        if ablate & 8 == 0 { dispatch2(enc, compositePS, 256 * k, 384 * k) }

        // display capture: the first captured line's settings say where
        let ld = lp
        var y = 0
        while y < 192 && ld[y * 8] & 16 == 0 { y += 1 }
        if y < 192 {
            let capc = ld[y * 8 + 4], dst = Int((capc >> 16) & 3)
            u[44] = capc
            enc.setComputePipelineState(capturePS)
            enc.setBytes(u, length: 192, index: 0)
            comp()
            enc.setBuffer(caps[dst].cur, offset: 0, index: 10)
            enc.setBuffer(caps[dst].next, offset: 0, index: 11)
            if ablate & 16 == 0 { dispatch2(enc, capturePS, 256 * k, 256 * k) }
            caps[dst] = (caps[dst].next, caps[dst].cur)
            st.captured = true
        }
        st.cpuMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        last = st
        return screens
    }

    private func dispatch2(_ enc: MTLComputeCommandEncoder, _ ps: MTLComputePipelineState, _ w: Int, _ h: Int) {
        // a tile's 32 x 8, fewer rows where the pipeline can't take 256
        let th = max(1, min(Self.tileH, ps.maxTotalThreadsPerThreadgroup / Self.tileW))
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: Self.tileW, height: th, depth: 1))
    }

    /// The scene at k: rows, raster, then the post passes into out3d (its
    /// lines from..<to at 1x; the rest stay as they were).
    private func render(_ enc: MTLComputeCommandEncoder, _ slot: Slot, _ sb: SceneBufs, from: Int, to: Int) {
        let W = 256 * k, H = 192 * k
        if sb.recTotal > 0 {
            if recs == nil || recCap < sb.recTotal {
                recCap = max(1 << 14, 1 << Int(ceil(log2(Double(sb.recTotal)))))
                recs = device.makeBuffer(length: recCap * 80, options: .storageModePrivate)
            }
            enc.setComputePipelineState(rowsPS)
            enc.setBytes(sb.u, length: 192, index: 0)
            enc.setBuffer(sb.polys, offset: 0, index: 1)
            enc.setBuffer(sb.geo, offset: 0, index: 2)
            enc.setBuffer(sb.verts, offset: 0, index: 3)
            enc.setBuffer(sb.recPoly, offset: 0, index: 4)
            enc.setBuffer(recs, offset: 0, index: 5)
            if ablate & 1 == 0 {
                enc.dispatchThreads(MTLSize(width: sb.recTotal, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(64, rowsPS.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            }
        }
        enc.setComputePipelineState(rasterPS)
        enc.setBytes(sb.u, length: 192, index: 0)
        enc.setBuffer(sb.polys, offset: 0, index: 1)
        enc.setBuffer(sb.geo, offset: 0, index: 2)
        enc.setBuffer(sb.bins, offset: 0, index: 3)
        enc.setBuffer(sb.head, offset: 0, index: 4)
        enc.setBuffer(slot.vram, offset: 0, index: 5)
        enc.setBuffer(slot.pal, offset: 0, index: 6)
        enc.setBuffer(recs ?? sb.recPoly, offset: 0, index: 7)
        enc.setBuffer(rast, offset: 0, index: 8)
        if ablate & 2 == 0 { dispatch2(enc, rasterPS, W, H) }
        var u = sb.u
        u[46] = UInt32(from); u[47] = UInt32(to)
        enc.setComputePipelineState(postPS)
        enc.setBytes(u, length: 192, index: 0)
        enc.setBuffer(rast, offset: 0, index: 1)
        enc.setBuffer(out3d, offset: 0, index: 2)
        if ablate & 4 == 0 { dispatch2(enc, postPS, W, H) }
    }

    @inline(__always) private static func fdiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }

    /// The scene words (gpuexport.nim) into sb: web/nds/gpu3d.js setScene.
    /// Returns the bin entries.
    private func setScene(_ sb: SceneBufs, _ scene: UnsafePointer<UInt32>, _ len: Int) throws -> Int {
        let k = self.k, HS = 192 * k, WS = 256 * k
        let np = Int(scene[1]), nv = Int(scene[2])
        guard np <= Self.maxPolys, len >= Self.header + np * Self.polyWords + nv * Self.vertWords else {
            throw Failure.scene("\(np) polygons, \(nv) vertices in \(len) words")
        }
        for i in 0..<40 { sb.u[i] = scene[8 + i] }
        sb.u[40] = scene[3]; sb.u[41] = UInt32(k); sb.u[42] = scene[4]; sb.u[45] = UInt32(tilesX)
        // vertices at k: floor(position * k / 192), render_hd's placement
        if nv > sb.vertCap {
            sb.vertCap = max(nv, 2 * sb.vertCap)
            sb.verts = device.makeBuffer(length: sb.vertCap * 32, options: .storageModeShared)!
        }
        let v0 = Self.header + np * Self.polyWords
        let vd = sb.verts.contents().assumingMemoryBound(to: Int32.self)
        for i in 0..<nv {
            let o = v0 + i * Self.vertWords
            vd[i * 8] = Int32(Self.fdiv(Int(Int32(bitPattern: scene[o])) * k, 192))
            vd[i * 8 + 1] = Int32(Self.fdiv(Int(Int32(bitPattern: scene[o + 1])) * k, 192))
            for w in 2..<7 { vd[i * 8 + w] = Int32(bitPattern: scene[o + w]) }
            vd[i * 8 + 7] = 0
        }
        sb.polys.contents().copyMemory(from: scene + Self.header, byteCount: np * 16)
        let gd = sb.geo.contents().assumingMemoryBound(to: Int32.self)
        let tx = tilesX, nt = tilesX * tilesY
        if sb.head == nil || sb.headTiles != nt {
            sb.head = device.makeBuffer(length: max(1, nt) * 8, options: .storageModeShared)
            sb.headTiles = nt
        }
        let head = sb.head!.contents().assumingMemoryBound(to: UInt32.self)
        if box.count < np * 4 { box = [Int32](repeating: 0, count: max(np * 4, 4 * Self.maxPolys)) }
        var recs = 0, binTotal = 0
        try tileCounts.withUnsafeMutableBufferPointer { counts in
            try box.withUnsafeMutableBufferPointer { box in
                for t in 0..<nt { counts[t] = 0 }
                for p in 0..<np {
                    let w3 = scene[Self.header + p * 4 + 3]
                    let first = Int(w3 & 0xFFFF), n = Int((w3 >> 16) & 0xFF)
                    var xmin = 1 << 30, xmax = -(1 << 30), ymin = 1 << 30, ymax = -(1 << 30), top = 0
                    var line = true, o = -1, bx = -1, flat = false
                    @inline(__always) func vx(_ i: Int) -> Int { Int(vd[(first + i) * 8]) }
                    @inline(__always) func vy(_ i: Int) -> Int { Int(vd[(first + i) * 8 + 1]) }
                    for i in 0..<n {
                        let x = vx(i), y = vy(i)
                        xmin = min(xmin, x); xmax = max(xmax, x)
                        ymin = min(ymin, y); ymax = max(ymax, y)
                        if i > 0 && y < vy(top) { top = i }
                        if i > 0 && (x != vx(0) || y != vy(0)) {
                            if o < 0 { o = i } else if x != vx(o) || y != vy(o) { line = false }
                        }
                    }
                    for i in 0..<n where vy(i) == ymax {
                        let x = vx(i)
                        if bx < 0 { bx = x } else if x != bx { flat = true }
                    }
                    let last = ymin == ymax ? ymin : ymax - 1
                    let g = gd + p * 8
                    g[0] = Int32(truncatingIfNeeded: xmin - 1); g[1] = Int32(truncatingIfNeeded: xmax + 1)
                    g[2] = Int32(truncatingIfNeeded: ymin); g[3] = Int32(truncatingIfNeeded: last)
                    g[4] = Int32(top); g[5] = Int32((line ? 1 : 0) | (flat ? 2 : 0))
                    g[6] = Int32(truncatingIfNeeded: ymax); g[7] = Int32(recs)
                    // (dots lie within one of the vertices' columns: a
                    // vertical right edge covers the dot left of it)
                    let x0 = max(0, xmin - 1), x1 = min(WS - 1, xmax + 1)
                    let y0 = max(0, ymin), y1 = min(HS - 1, last)
                    if n < 1 || n > 16 || x0 > x1 || y0 > y1 { box[p * 4] = 1; box[p * 4 + 1] = 0; continue }
                    let rows = y1 - y0 + 1
                    if recs + rows > sb.recPolyCap {
                        let cap = max(recs + rows, 2 * sb.recPolyCap)
                        let nb = device.makeBuffer(length: cap * 4, options: .storageModeShared)!
                        nb.contents().copyMemory(from: sb.recPoly.contents(), byteCount: recs * 4)
                        sb.recPoly = nb; sb.recPolyCap = cap
                    }
                    let rp = sb.recPoly.contents().assumingMemoryBound(to: UInt32.self)
                    for r in recs..<(recs + rows) { rp[r] = UInt32(p) }
                    recs += rows
                    box[p * 4] = Int32(x0 / Self.tileW); box[p * 4 + 1] = Int32(x1 / Self.tileW)
                    box[p * 4 + 2] = Int32(y0 / Self.tileH); box[p * 4 + 3] = Int32(y1 / Self.tileH)
                    for ty in Int(box[p * 4 + 2])...Int(box[p * 4 + 3]) {
                        for t in Int(box[p * 4])...Int(box[p * 4 + 1]) { counts[ty * tx + t] += 1 }
                    }
                }
                var total = 0
                for t in 0..<nt { head[t * 2] = UInt32(total); head[t * 2 + 1] = 0; total += Int(counts[t]) }
                if total > Self.maxBins { throw Failure.scene("\(total) bin entries") }
                if total > sb.binCap {
                    sb.binCap = max(total, 2 * sb.binCap)
                    sb.bins = device.makeBuffer(length: sb.binCap * 4, options: .storageModeShared)!
                }
                let bins = sb.bins.contents().assumingMemoryBound(to: UInt32.self)
                for p in 0..<np where box[p * 4] <= box[p * 4 + 1] {
                    for ty in Int(box[p * 4 + 2])...Int(box[p * 4 + 3]) {
                        for t in Int(box[p * 4])...Int(box[p * 4 + 1]) {
                            let i = ty * tx + t
                            bins[Int(head[i * 2] + head[i * 2 + 1])] = UInt32(p)
                            head[i * 2 + 1] += 1
                        }
                    }
                }
                binTotal = total
            }
        }
        sb.recTotal = recs
        sb.u[43] = UInt32(recs)
        return binTotal
    }
}
