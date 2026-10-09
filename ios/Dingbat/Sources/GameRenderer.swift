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
        if dingbat_is_nds() != 0 {
            drawNds(in: view)
            return
        }
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
        cmd.present(drawable)
        cmd.commit()
    }

    /// A DS frame: the stage's colour, then each shown screen into its rect,
    /// turned, filtered as the web filters DS screens (no colour correction,
    /// no palette: the DS's own panels). With HD 3D the texture is k x the
    /// composite and each screen's texels are k x too: the filters, the
    /// grid and the subpixel look work on the HD pixels, as the web's do.
    private func drawNds(in view: MTKView) {
        view.clearColor = ndsClear
        guard let ndsPipeline, let queue, let gameTex, let borderTex,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
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
