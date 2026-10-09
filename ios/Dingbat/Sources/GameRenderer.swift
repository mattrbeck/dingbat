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
}

/// Uploads the core's raw BGR555 frame to an R16Uint texture and runs the
/// presenter shader into an MTKView the session redraws after each tick.
final class GameRenderer: NSObject, MTKViewDelegate {
    static let shared = GameRenderer()

    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var gameTex: MTLTexture?
    private var borderTex: MTLTexture?
    private var lastBorderGen: Int32 = -1
    #if DEBUG
    /// The last picture sent to the screen (`-present-check`).
    private(set) var uploadedHash: UInt64 = 0
    #endif
    private(set) weak var view: MTKView?

    var options = PresentOptions()

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
    }

    /// Upload the current picture and draw it. Main thread, after frames run.
    func present() {
        guard let view, dingbat_loaded() != 0 else { return }
        uploadGame()
        view.draw()
    }

    /// Redraw without new pixels (an options change while paused).
    func redraw() {
        view?.draw()
    }

    private func uploadGame() {
        guard let device, let ptr = dingbat_game_fb() else { return }
        let w = Int(dingbat_fb_width()), h = Int(dingbat_fb_height())
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

    /// Late start (GameSession): the refresh the next draw aims at, and
    /// whether it made it, reported on the main queue. On a device, from
    /// when the drawable reached the screen (no presented time: dropped); in
    /// the simulator, whose SDK has no presented handler, from when the GPU
    /// finished. Each draw captures its own target.
    var presentTarget: CFTimeInterval = 0
    var onLateResult: ((Bool) -> Void)?
    #if DEBUG
    /// The pacing test (GameSession `-pacing-test`): the refresh the next
    /// draw aims at, and (target, when it reached the screen) reported on the
    /// main queue: on a device the presented time (0: never shown), in the
    /// simulator the GPU's end.
    var pacingTarget: CFTimeInterval = 0
    var onPacing: ((CFTimeInterval, CFTimeInterval) -> Void)?
    #endif

    func draw(in view: MTKView) {
        guard let pipeline, let queue, let gameTex, let borderTex,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
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
        if let pal = options.dmgPalette, pal.count == 4,
           dingbat_is_gb() != 0, dingbat_is_cgb() == 0 {
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
        let target = presentTarget
        presentTarget = 0
        if target > 0, let report = onLateResult {
            #if targetEnvironment(simulator)
            cmd.addCompletedHandler { c in
                let end = c.gpuEndTime
                DispatchQueue.main.async { report(end > target - 0.001) }
            }
            #else
            drawable.addPresentedHandler { d in
                let shown = d.presentedTime
                DispatchQueue.main.async { report(shown == 0 || shown > target + 0.002) }
            }
            #endif
        }
        #if DEBUG
        let pt = pacingTarget
        pacingTarget = 0
        if pt > 0, let rec = onPacing {
            #if targetEnvironment(simulator)
            cmd.addCompletedHandler { c in
                let end = c.gpuEndTime
                DispatchQueue.main.async { rec(pt, end) }
            }
            #else
            drawable.addPresentedHandler { d in
                let shown = d.presentedTime
                DispatchQueue.main.async { rec(pt, shown) }
            }
            #endif
        }
        #endif
        cmd.present(drawable)
        cmd.commit()
    }
}

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
