import MetalKit
import SwiftUI

/// What the presenter draws with, from Settings › Video.
struct PresentOptions: Equatable {
    var colorCorrect = true
    var filter = 0          // 0 none, 1 hq4x, 2 xBR
    var grid = false        // "LCD grid"
    var subpixel = false    // "RGB subpixels"
    var dmgPalette: [UInt32]? // four 0xRRGGBB shades (lightest first), monochrome games only
}

/// Matches PresentUniforms in Present.metal (std layout: float4s 16-aligned).
private struct PresentUniforms {
    var texSize: SIMD2<Float> = .zero
    var scanWidth: Float = 0
    var scanHeight: Float = 0
    var filter: Int32 = 0
    var colorCorrect: Int32 = 0
    var panelGbc: Int32 = 0
    var grid: Int32 = 0
    var subpixel: Int32 = 0
    var dmgRemap: Int32 = 0
    var sgbBorder: Int32 = 0
    var pad0: Int32 = 0
    var sgbBackdrop: SIMD4<Float> = .zero
    var dmgPal: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var texOrigin: SIMD2<Float> = .zero
    var pad2: SIMD2<Float> = .zero
}

/// Matches ViewUniforms in the shader: a DS view's clip-space rect and turn.
private struct ViewUniforms {
    var dst: SIMD4<Float> = .zero
    var rot: Int32 = 0
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0
}

/// Uploads the core's raw BGR555 frame to an R16Uint texture and runs the
/// presenter shader into an MTKView the session redraws after each tick.
final class GameRenderer: NSObject, MTKViewDelegate {
    static let shared = GameRenderer()

    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var ndsPipeline: MTLRenderPipelineState?
    private var gameTex: MTLTexture?
    private var borderTex: MTLTexture?
    /// The DS's 3D on Metal (NdsGpu3d.swift), built on first use; nil where
    /// it can't be, or after it failed while drawing (then the core draws).
    private lazy var ndsGpu: NdsGpu3d? = {
        guard let device else { ndsGpuFailure = "this device has no Metal"; return nil }
        do { return try NdsGpu3d(device: device) } catch {
            NSLog("NdsGpu3d: %@", "\(error)")
            ndsGpuFailure = "the graphics card can't run the renderer"
            return nil
        }
    }()
    var ndsGpuAvailable: Bool { ndsGpu != nil }
    /// Why the renderer isn't drawing: nil while it can, "" once it failed
    /// mid-run, else the reason it couldn't be built (NdsState.gpuStatus).
    private(set) var ndsGpuFailure: String?
    /// The core exports its 3D for ndsGpu, and the export is of the frame
    /// it shows (after a state load or a rewind, until a frame runs, the
    /// core's own screens are the picture: dingbat_nds_gpu_current).
    private var ndsGpuDrawing: Bool { dingbat_is_nds() != 0 && dingbat_nds_gpu_current() != 0 }
    private var ndsReadBuf: MTLBuffer?

    /// Before the app takes a picture of a DS game (the library's, a
    /// thumbnail, the hero, a state's own screens, a screenshot): the GPU's
    /// screens at 1x into the core's, which lack the 3D under the skip (web
    /// ndsGpuRgba: every k-th dot of an HD picture). This frame's GPU work is
    /// encoded first if the display link hasn't drawn it yet. Waits for the
    /// GPU (on demand only, a few ms at 4x).
    func syncNdsScreens() {
        guard ndsGpuDrawing, let gpu = ndsGpu, let device, let queue,
              let cmd = queue.makeCommandBuffer() else { return }
        let k = NdsState.shared.hd
        var tex: MTLTexture?
        do { tex = try gpu.encode(cmd, k: k) } catch {
            NSLog("NdsGpu3d: %@", "\(error)")
            ndsGpu = nil
            ndsGpuFailure = ""
            cmd.commit()
            NdsState.shared.gpuFailed()
            return
        }
        guard let tex, tex.width == 256 * k, let blit = cmd.makeBlitCommandEncoder() else { cmd.commit(); return }
        let w = tex.width, h = tex.height
        if ndsReadBuf == nil || ndsReadBuf!.length < w * h * 2 {
            ndsReadBuf = device.makeBuffer(length: w * h * 2, options: .storageModeShared)
        }
        guard let buf = ndsReadBuf else { blit.endEncoding(); cmd.commit(); return }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: w * 2, destinationBytesPerImage: w * h * 2)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let src = buf.contents().assumingMemoryBound(to: UInt16.self)
        var one = [UInt16](repeating: 0, count: 256 * 384)
        for y in 0..<384 {
            for x in 0..<256 { one[y * 256 + x] = src[(y * k) * w + x * k] }
        }
        one.withUnsafeBufferPointer { p in dingbat_nds_put_screens(p.baseAddress!, p.baseAddress! + 256 * 192) }
    }
    private var lastBorderGen: Int32 = -1
    #if DEBUG
    /// The last picture sent to the screen (`-present-check`).
    private(set) var uploadedHash: UInt64 = 0
    #endif
    private(set) weak var view: MTKView?

    var options = PresentOptions()

    /// A DS game's arrangement (GameStage sets it with the picture's box):
    /// the views in layout pixels of the turned picture (w x h), and the
    /// stage's colour for the gaps and Focus's empty corner (web: the
    /// presenter clears in the stage's colour).
    var ndsViews: [NdsUtil.View] = []
    var ndsSize = CGSize(width: 256, height: 392)
    var ndsClear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    override init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init()
        buildPipeline()
    }

    private func buildPipeline() {
        guard let device, let lib = try? device.makeLibrary(source: presentShaderSource, options: nil) else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "present_vertex")
        desc.fragmentFunction = lib.makeFunction(name: "present_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        desc.vertexFunction = lib.makeFunction(name: "nds_vertex")
        ndsPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        let bd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: 256, height: 224, mipmapped: false)
        bd.usage = .shaderRead
        borderTex = device.makeTexture(descriptor: bd)
    }

    func attach(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.isOpaque = true
        view.backgroundColor = .black
        view.delegate = self
        self.view = view
        if metalLinkHandler != nil { restartMetalLink() }
    }

    // MARK: CAMetalDisplayLink (DS games)

    /// The session's tick, run from each update of a CAMetalDisplayLink on
    /// the picture's layer; nil while a CADisplayLink paces the game
    /// (GameSession.startLink chooses).
    private var metalLinkHandler: ((DisplayTick) -> Void)?
    private var metalLink: AnyObject?  // CAMetalDisplayLink (iOS 17)
    /// The update's drawable while its tick runs.
    private var updateDrawable: CAMetalDrawable?
    /// The refresh period, learnt from the updates' planned presentations
    /// (an update does not give its own).
    private var refreshPeriod = 1.0 / 60
    private var lastPresentAt = 0.0

    @available(iOS 17, *)
    func startMetalLink(_ handler: @escaping (DisplayTick) -> Void) {
        metalLinkHandler = handler
        restartMetalLink()
    }

    func stopMetalLink() {
        // Stopped inside an update (a core fault pauses): its drawable still
        // goes back presented.
        drawIntoUpdate()
        metalLinkHandler = nil
        if #available(iOS 17, *) { (metalLink as? CAMetalDisplayLink)?.invalidate() }
        metalLink = nil
        updateDrawable = nil
    }

    private func restartMetalLink() {
        guard #available(iOS 17, *) else { return }
        (metalLink as? CAMetalDisplayLink)?.invalidate()
        metalLink = nil
        guard let layer = view?.layer as? CAMetalLayer else { return }
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        // A picture on glass the refresh after its update's (33 ms from the
        // tick at 60 Hz; 2 would be 50 ms).
        link.preferredFrameLatency = 1
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        metalLink = link
        lastPresentAt = 0
    }

    @available(iOS 17, *)
    fileprivate func updateMetalLink(_ update: CAMetalDisplayLink.Update) {
        let at = update.targetPresentationTimestamp
        if lastPresentAt > 0 {
            let d = at - lastPresentAt
            if d > refreshPeriod * 0.5 && d < refreshPeriod * 1.5 { refreshPeriod += (d - refreshPeriod) * 0.1 }
        }
        lastPresentAt = at
        updateDrawable = update.drawable
        metalLinkHandler?(DisplayTick(timestamp: at - refreshPeriod, targetTimestamp: update.targetTimestamp,
                                      period: refreshPeriod))
        #if DEBUG
        if FFTrace.on { FFTrace.shared.planned(at) }
        #endif
        // Every update's drawable is presented, the same picture again when
        // the tick brought none: one handed back unpresented made iOS drop
        // the next present (about half the pictures after a still one were
        // never shown, an iPhone 13 mini on iOS 27).
        drawIntoUpdate()
    }

    /// Draw the uploaded picture into the update's drawable (once).
    private func drawIntoUpdate() {
        guard let drawable = updateDrawable else { return }
        updateDrawable = nil
        let nds = dingbat_is_nds() != 0
        if nds { view?.clearColor = ndsClear }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = nds ? ndsClear : view?.clearColor ?? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if canEncode {
            encode(pass: pass, drawable: drawable)
            return
        }
        // No picture yet: the drawable still goes back presented, cleared.
        guard let cmd = queue?.makeCommandBuffer() else { return }
        cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Whether encode has what it draws with (checked before a drawable is
    /// taken: one taken and not presented costs the next present).
    private var canEncode: Bool {
        queue != nil && borderTex != nil
            && (dingbat_is_nds() != 0 ? ndsPipeline != nil && (gameTex != nil || ndsGpuDrawing)
                                      : pipeline != nil && gameTex != nil)
    }

    /// Upload the current picture and draw it. Main thread, after frames run.
    func present() {
        guard let view, dingbat_loaded() != 0 else { return }
        uploadGame()
        #if DEBUG
        drawableWait = 0
        #endif
        // On a CAMetalDisplayLink, into the update's drawable (outside an
        // update, the next one draws it).
        if metalLinkHandler != nil { drawIntoUpdate() } else { view.draw() }
        #if DEBUG
        if FFTrace.on { FFTrace.shared.afterPresent(wait: drawableWait) }
        #endif
    }
    #if DEBUG
    private var drawableWait = 0.0
    #endif

    /// Redraw without new pixels (an options change while paused).
    func redraw() {
        if metalLinkHandler != nil { drawIntoUpdate() } else { view?.draw() }
    }

    /// The picture to upload: a DS game's HD composite while HD 3D is on
    /// (256k x 384k, the web's ndsFrame), else dingbat_game_fb.
    static func picture() -> (ptr: UnsafePointer<UInt16>, w: Int, h: Int)? {
        if dingbat_is_nds() != 0, let hd = dingbat_nds_hd_fb() {
            return (hd, Int(dingbat_nds_hd_fb_width()), Int(dingbat_nds_hd_fb_height()))
        }
        guard let ptr = dingbat_game_fb() else { return nil }
        return (ptr, Int(dingbat_fb_width()), Int(dingbat_fb_height()))
    }

    private func uploadGame() {
        // (the GPU's DS picture is drawn in encodeNds, nothing to upload)
        if ndsGpuDrawing { return }
        guard let device, let pic = Self.picture() else { return }
        let (ptr, w, h) = pic
        if gameTex == nil || gameTex!.width != w || gameTex!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Uint, width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            gameTex = device.makeTexture(descriptor: d)
        }
        gameTex?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                         withBytes: ptr, bytesPerRow: w * 2)
        #if DEBUG
        if GameSession.presentCheck { uploadedHash = GameSession.hash16(ptr, w * h) }
        #endif
        if dingbat_sgb_border() != 0, let bptr = dingbat_sgb_border_ptr() {
            let gen = dingbat_sgb_border_gen()
            if gen != lastBorderGen {
                lastBorderGen = gen
                borderTex?.replace(region: MTLRegionMake2D(0, 0, 256, 224), mipmapLevel: 0,
                                   withBytes: bptr, bytesPerRow: 512)
            }
        } else {
            lastBorderGen = -1
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if dingbat_is_nds() != 0 { view.clearColor = ndsClear }
        #if DEBUG
        let w0 = CACurrentMediaTime()
        #endif
        guard canEncode, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        #if DEBUG
        drawableWait = CACurrentMediaTime() - w0
        #endif
        encode(pass: pass, drawable: drawable)
    }

    private func encode(pass: MTLRenderPassDescriptor, drawable: CAMetalDrawable) {
        if dingbat_is_nds() != 0 {
            encodeNds(pass: pass, drawable: drawable)
            return
        }
        guard let pipeline, let queue, let gameTex, let borderTex,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        #if DEBUG
        if FFTrace.on { FFTrace.shared.drawable(drawable, cmd) }
        #endif
        var u = PresentUniforms()
        let border = dingbat_sgb_border() != 0
        u.texSize = SIMD2(Float(gameTex.width), Float(gameTex.height))
        u.scanWidth = Float(border ? 256 : gameTex.width)
        u.scanHeight = Float(border ? 224 : gameTex.height)
        u.filter = Int32(options.filter)
        u.colorCorrect = options.colorCorrect ? 1 : 0
        u.panelGbc = dingbat_panel_gbc()
        u.grid = options.grid ? 1 : 0
        u.subpixel = options.subpixel ? 1 : 0
        u.sgbBorder = border ? 1 : 0
        if border {
            let bd = UInt32(bitPattern: dingbat_sgb_backdrop())
            u.sgbBackdrop = SIMD4(Float(bd & 31) / 31, Float((bd >> 5) & 31) / 31,
                                  Float((bd >> 10) & 31) / 31, 1)
        }
        // Not under SGB colour: its palettes' white and black are the
        // core's grey codes too (web drawGame's gate).
        if let pal = options.dmgPalette, pal.count == 4,
           dingbat_is_gb() != 0, dingbat_is_cgb() == 0, dingbat_sgb_active() == 0 {
            u.dmgRemap = 1
            func c(_ v: UInt32) -> SIMD4<Float> {
                SIMD4(Float((v >> 16) & 255) / 255, Float((v >> 8) & 255) / 255,
                      Float(v & 255) / 255, 1)
            }
            u.dmgPal = (c(pal[0]), c(pal[1]), c(pal[2]), c(pal[3]))
        }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(gameTex, index: 0)
        enc.setFragmentTexture(borderTex, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<PresentUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// A DS frame: the stage's colour, then each shown screen into its rect,
    /// turned, filtered as the web filters DS screens (no colour correction,
    /// no palette: the DS's own panels). With HD 3D the texture is k x the
    /// composite and each screen's texels are k x too: the filters, the
    /// grid and the subpixel look work on the HD pixels, as the web's do.
    private func encodeNds(pass: MTLRenderPassDescriptor, drawable: CAMetalDrawable) {
        guard let ndsPipeline, let queue, let borderTex,
              let cmd = queue.makeCommandBuffer() else { return }
        #if DEBUG
        if FFTrace.on { FFTrace.shared.drawable(drawable, cmd) }
        #endif
        // HD 3D on the GPU: this frame's 3D and composite, in this command
        // buffer before the screens are drawn from it (a failure there: the
        // core's software HD from the next frame). Drawn again for the same
        // frame (a display-link update with no new tick), it encodes nothing.
        var tex = gameTex
        #if DEBUG
        if PerfStats.on {
            cmd.addCompletedHandler { c in PerfStats.shared.gpu(c.gpuEndTime - c.gpuStartTime) }
        }
        let pe0 = PerfStats.on ? CACurrentMediaTime() : 0
        defer { if PerfStats.on && ndsGpuDrawing { PerfStats.shared.encode(CACurrentMediaTime() - pe0) } }
        #endif
        if ndsGpuDrawing, let gpu = ndsGpu {
            do { tex = try gpu.encode(cmd, k: NdsState.shared.hd) ?? gameTex } catch {
                NSLog("NdsGpu3d: %@", "\(error)")
                ndsGpu = nil
                ndsGpuFailure = ""
                NdsState.shared.gpuFailed()
            }
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        // (no picture yet: the drawable still goes back presented, cleared)
        guard let gameTex = tex else {
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
            return
        }
        enc.setRenderPipelineState(ndsPipeline)
        enc.setFragmentTexture(gameTex, index: 0)
        enc.setFragmentTexture(borderTex, index: 1)
        let lw = Float(max(1, ndsSize.width)), lh = Float(max(1, ndsSize.height))
        let k = max(1, gameTex.width / 256)
        let sw = Float(256 * k), sh = Float(192 * k)
        for v in ndsViews where gameTex.height >= 384 * k {
            var u = PresentUniforms()
            u.texSize = SIMD2(sw, sh)
            u.scanWidth = sw
            u.scanHeight = sh
            u.filter = Int32(options.filter)
            u.grid = options.grid ? 1 : 0
            u.subpixel = options.subpixel ? 1 : 0
            u.texOrigin = SIMD2(0, v.screen == .top ? 0 : sh)
            var vu = ViewUniforms()
            let r = v.dst
            vu.dst = SIMD4(Float(r.minX) / lw * 2 - 1, 1 - Float(r.minY) / lh * 2,
                           Float(r.maxX) / lw * 2 - 1, 1 - Float(r.maxY) / lh * 2)
            vu.rot = Int32(v.rot)
            enc.setVertexBytes(&vu, length: MemoryLayout<ViewUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<PresentUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

#if DEBUG
/// `-gpu-stats`: a line a second into tmp/gpustats.txt, for measuring the
/// DS's Metal 3D on a phone (tools/gpu3d/metal measures the same on a Mac):
/// the core's frames and their ms, the session's present a tick (upload,
/// encode, commit), encodeNds's CPU ms (NdsGpu3d.encode and the screens'
/// draw) and each command buffer's GPU ms.
final class PerfStats {
    static let on = ProcessInfo.processInfo.arguments.contains("-gpu-stats")
    static let shared = PerfStats()
    private let lock = NSLock()
    private var frames = 0, coreS = 0.0, presents = 0, presentS = 0.0, presentMax = 0.0
    private var encodes = 0, encodeS = 0.0, cbs = 0, gpuS = 0.0, gpuMax = 0.0
    private var start = CACurrentMediaTime()

    func frame(_ s: Double) { frames += 1; coreS += s; flush() }
    func present(_ s: Double) { presents += 1; presentS += s; presentMax = max(presentMax, s) }
    func encode(_ s: Double) { encodes += 1; encodeS += s }
    func gpu(_ s: Double) {
        lock.lock(); cbs += 1; gpuS += s; gpuMax = max(gpuMax, s); lock.unlock()
    }

    private func flush() {
        let now = CACurrentMediaTime()
        guard now - start >= 1 else { return }
        lock.lock()
        let g = (cbs, gpuS, gpuMax)
        cbs = 0; gpuS = 0; gpuMax = 0
        lock.unlock()
        func ms(_ t: Double, _ n: Int) -> Double { n > 0 ? t * 1000 / Double(n) : 0 }
        let line = String(format: "frames=%d core=%.2f presents=%d present=%.2f presentMax=%.2f encode=%.2f gpu=%.2f gpuMax=%.2f cbs=%d hd=%d gpu3d=%d\n",
                          frames, ms(coreS, frames), presents, ms(presentS, presents), presentMax * 1000,
                          ms(encodeS, encodes), ms(g.1, g.0), g.2 * 1000, g.0,
                          Int(NdsState.shared.hd), Int(dingbat_nds_gpu_frames() > 0 ? 1 : 0))
        frames = 0; coreS = 0; presents = 0; presentS = 0; presentMax = 0; encodes = 0; encodeS = 0
        start = now
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gpustats.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
#endif

/// The game picture. The session drives redraws; SwiftUI only sizes it.
struct GameScreenView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        GameRenderer.shared.attach(v)
        DispatchQueue.main.async { GameRenderer.shared.present() }
        return v
    }

    func updateUIView(_ view: MTKView, context: Context) {
        if GameRenderer.shared.view !== view { GameRenderer.shared.attach(view) }
    }
}

@available(iOS 17, *)
extension GameRenderer: CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        updateMetalLink(update)
    }
}
