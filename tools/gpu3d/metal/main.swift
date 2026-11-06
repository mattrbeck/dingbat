// The Metal port of the DS's GPU 3D (ios/Dingbat/Sources/NdsGpu3d.swift)
// on a Mac: the iOS app's core library (src/dingbat_ios.nim, built for
// macOS) and renderer, without the app. Loads a DS game and a state, runs
// frames unpaced and silent, and
//  - checks the GPU picture against the core's software one, frame by
//    frame (--check: the core draws HD at k too and every frame's screens
//    are compared dot for dot);
//  - times each frame: the core's frame, the renderer's CPU work (encode)
//    and the GPU's, for the modes the app could run in.
//
//   tools/gpu3d/metal/build.sh
//   ndsmetal ROM STATE [--frames N] [--warm N] [--k K] [--mode cpu|hd|gpu|skip]
//            [--check [--then ROM2,STATE2]] [--press FILE] [--png FILE]
//            [--rewind] [--sync] [--ablate N]
//
// Modes: cpu (the core's 1x, no HD), hd (the core's software HD at k),
// gpu (the export, the CPU still drawing its 1x 3D: Metal at k), skip (the
// export with the skip, and the handback at 1x). --warm (30) frames run
// first and are left out of the timings (not of --check). --rewind turns
// the core's rewind ring on, as the app has it (off here by default: under
// the skip it draws one frame in ten whole). --press is a file holding an
// ndsrun --press spec (KEY@F[+D|-L], TOUCH:x:y@F..., no LID; frames counted
// as the core does).

import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers

var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String, _ dflt: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count {
        let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
    }
    return dflt
}
func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}
let frames = Int(opt("--frames", "600"))!
let k = Int(opt("--k", "1"))!
let mode = opt("--mode", "skip")
let pressPath = opt("--press", "")
let pngPath = opt("--png", "")
// --then ROM2,STATE2 (with --check): a second game into the same renderer
// afterwards, every frame checked (what a renderer kept across games, as
// the app's is, must not carry over: texture images, the frame seen)
let thenParts = opt("--then", "").split(separator: ",").map(String.init)
let warm = Int(opt("--warm", "30"))!
let check = flag("--check")
// --sync: wait for each frame's GPU work, the picture's time then being
// encode + GPU + the wait (index.js ndsGpuBench's "picture")
let sync = flag("--sync")
let rewind = flag("--rewind")
let ablate = Int(opt("--ablate", "0"))!   // NdsGpu3d.ablate: passes left out (timing only)
guard args.count == 2 else {
    FileHandle.standardError.write("usage: ndsmetal ROM STATE [--frames N] [--warm N] [--k K] [--mode cpu|hd|gpu|skip] [--check [--then ROM2,STATE2]] [--press FILE] [--png FILE] [--rewind] [--sync] [--ablate N]\n".data(using: .utf8)!)
    exit(2)
}
let romPath = args[0], statePath = args[1]

// --- presses (ndsrun's --press)
struct Press { var first = 0, last = 0, button = -1, touch = false, x = 0, y = 0 }
let buttonIds: [String: Int32] = ["UP": 0, "DOWN": 1, "LEFT": 2, "RIGHT": 3, "A": 4, "B": 5, "SELECT": 6,
                                  "START": 7, "L": 8, "R": 9, "X": 10, "Y": 11]
var presses: [Press] = []
if !pressPath.isEmpty {
    let spec = try! String(contentsOfFile: pressPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    for raw in spec.split(separator: ",") {
        let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.isEmpty { continue }
        let at = item.split(separator: "@")
        guard at.count == 2 else { FileHandle.standardError.write("--press: \(item)?\n".data(using: .utf8)!); exit(2) }
        var p = Press()
        let f = String(at[1])
        if f.contains("+") {
            let fd = f.split(separator: "+"); p.first = Int(fd[0])!; p.last = p.first + Int(fd[1])!
        } else {
            let fl = f.split(separator: "-"); p.first = Int(fl[0])!; p.last = fl.count > 1 ? Int(fl[1])! : p.first + 2
        }
        let what = at[0].uppercased()
        if what.hasPrefix("TOUCH:") {
            let xy = what.split(separator: ":"); p.touch = true; p.x = Int(xy[1])!; p.y = Int(xy[2])!
        } else if let b = buttonIds[what] { p.button = Int(b) } else {
            FileHandle.standardError.write("--press: no key \(what) here (LID isn't supported)\n".data(using: .utf8)!)
            exit(2)
        }
        presses.append(p)
    }
}

// --- the core
dingbat_init()
dingbat_set_volume(0, 1)                 // silent (and nothing drains the audio ring anyway)
dingbat_set_rewind(rewind ? 1 : 0, 0)
dingbat_set_fast_forward(1)              // no audio-sync pacing
let gpuOn = mode == "gpu" || mode == "skip" || check
dingbat_nds_set_gpu(gpuOn ? 1 : 0)
dingbat_nds_set_gpu_skip(mode == "skip" && !check ? 1 : 0)
dingbat_nds_set_gpu_handback(mode == "skip" && !check && k == 1 ? 1 : 0)
dingbat_nds_set_hd(Int32(mode == "hd" || (check && k > 1) ? k : 1))
guard dingbat_load_rom(romPath, nil) == 0 else { print("load_rom failed"); exit(1) }
let state = try! Data(contentsOf: URL(fileURLWithPath: statePath))
let ok = state.withUnsafeBytes { dingbat_load_state($0.baseAddress, Int32(state.count), 0) }
guard ok == 1 else { print("load_state failed: \(String(cString: dingbat_state_error()))"); exit(1) }

// --- Metal
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let gpu: NdsGpu3d? = gpuOn ? try! NdsGpu3d(device: device) : nil
gpu?.ablate = ablate
// (the cpu and hd modes upload their picture as GameRenderer does)
var upTex: MTLTexture?
let W = 256 * k, H = 384 * k
let readBuf = device.makeBuffer(length: W * H * 2, options: .storageModeShared)!

struct Sample { var core = 0.0, enc = 0.0, gpu = 0.0, coreCpu = 0.0, encCpu = 0.0, drew = false, captured = false }
// The load-proof measures (the Mac may be busy): the process's retired
// instructions (Metal's driver threads included) and this thread's CPU time.
func instructions() -> UInt64 {
    var info = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return r == 0 ? info.ri_instructions : 0
}
func threadMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
var insAt = UInt64(0)
var samples: [Sample] = []
let gpuTimes = NSLock()
var gpuMs = [Int: Double]()
var mismatched = 0, firstBad = -1, worst = 0
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func writePng(_ src: UnsafePointer<UInt16>, _ w: Int, _ h: Int, _ path: String) {
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    for d in 0..<(w * h) {
        let c = Int(src[d])
        let r = c & 31, g = (c >> 5) & 31, b = (c >> 10) & 31
        rgba[d * 4] = UInt8((r << 3) | (r >> 2)); rgba[d * 4 + 1] = UInt8((g << 3) | (g >> 2)); rgba[d * 4 + 2] = UInt8((b << 3) | (b >> 2))
    }
    let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dst)
}

let t0all = now()
for i in 0..<(warm + frames) {
    let f = Int(dingbat_nds_frame_count())
    for p in presses where f == p.first || f == p.last {
        if p.touch { dingbat_nds_touch(Int32(p.x), Int32(p.y), f == p.first ? 1 : 0) }
        else { dingbat_set_input(Int32(p.button), f == p.first ? 1 : 0) }
    }
    if i == warm { queue.makeCommandBuffer().map { $0.commit(); $0.waitUntilCompleted() }; insAt = instructions() }
    var s = Sample()
    let a = now(), ac = threadMs()
    dingbat_run_frame()
    let b = now(), bc = threadMs()
    s.coreCpu = bc - ac
    s.core = b - a
    let cb = queue.makeCommandBuffer()!
    if let gpu {
        _ = try! gpu.encode(cb, k: k)
        s.drew = gpu.last.drew; s.captured = gpu.last.captured
        if check, let t = gpu.screens, let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: W, height: H, depth: 1), to: readBuf, destinationOffset: 0,
                      destinationBytesPerRow: W * 2, destinationBytesPerImage: W * H * 2)
            blit.endEncoding()
        }
    } else {
        // GameRenderer.uploadGame: the picture into an R16Uint texture
        let (ptr, w, h): (UnsafePointer<UInt16>, Int, Int) = {
            if let hd = dingbat_nds_hd_fb() { return (hd, Int(dingbat_nds_hd_fb_width()), Int(dingbat_nds_hd_fb_height())) }
            return (dingbat_game_fb()!, 256, 384)
        }()
        if upTex == nil || upTex!.width != w {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            upTex = device.makeTexture(descriptor: d)
        }
        upTex!.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: ptr, bytesPerRow: w * 2)
    }
    let idx = i
    cb.addCompletedHandler { c in
        let ms = (c.gpuEndTime - c.gpuStartTime) * 1000
        gpuTimes.lock(); gpuMs[idx] = ms; gpuTimes.unlock()
    }
    cb.commit()
    if sync { cb.waitUntilCompleted() }
    s.enc = now() - b
    s.encCpu = threadMs() - bc
    if check, gpu != nil {
        cb.waitUntilCompleted()
        // the reference: the core's 1x screens, or its software HD at k
        let ref: UnsafePointer<UInt16> = k > 1 ? dingbat_nds_hd_fb()! : dingbat_game_fb()!
        let got = readBuf.contents().assumingMemoryBound(to: UInt16.self)
        var bad = 0
        for d in 0..<(W * H) where (got[d] & 0x7FFF) != (ref[d] & 0x7FFF) { bad += 1 }
        if bad > 0 {
            mismatched += 1; worst = max(worst, bad)
            if firstBad < 0 {
                firstBad = f
                var top = 0
                for d in 0..<(W * H / 2) where (got[d] & 0x7FFF) != (ref[d] & 0x7FFF) { top += 1 }
                print("frame \(f): \(bad) dots differ (\(top) on the top screen)")
                if !pngPath.isEmpty {
                    writePng(ref, W, H, pngPath.replacingOccurrences(of: ".png", with: "-ref.png"))
                    writePng(UnsafePointer(got), W, H, pngPath.replacingOccurrences(of: ".png", with: "-bad.png"))
                }
            }
        }
    }
    if i >= warm { samples.append(s) }
}
queue.makeCommandBuffer().map { $0.commit(); $0.waitUntilCompleted() }
let wall = now() - t0all
let insPerFrame = Double(instructions() - insAt) / Double(frames) / 1e6

for (j, _) in samples.enumerated() { samples[j].gpu = gpuMs[warm + j] ?? 0 }
func stat(_ xs: [Double]) -> String {
    if xs.isEmpty { return "(no frames)" }
    let s = xs.sorted()
    let mean = xs.reduce(0, +) / Double(max(1, xs.count))
    return String(format: "mean %6.3f  p50 %6.3f  p95 %6.3f", mean, s[s.count / 2], s[min(s.count - 1, s.count * 95 / 100)])
}
let renderer = device.name
print("\(check ? "check" : mode) k=\(k)  \(frames) frames  (\(renderer))")
print(String(format: "  instructions/frame %.2f M (whole process); thread CPU ms/frame: core %.3f, encode %.3f",
             insPerFrame, samples.map { $0.coreCpu }.reduce(0, +) / Double(frames), samples.map { $0.encCpu }.reduce(0, +) / Double(frames)))
print("  core   ms/frame: " + stat(samples.map { $0.core }))
print("  encode ms/frame: " + stat(samples.map { $0.enc }))
print("  GPU    ms/frame: " + stat(samples.map { $0.gpu }))
// (a game drawing its 3D every other frame reuses the scene in between:
// those frames only composite, so the median of all frames can be theirs)
let drawnGpu = samples.filter { $0.drew }.map { $0.gpu }, keptGpu = samples.filter { !$0.drew }.map { $0.gpu }
if !drawnGpu.isEmpty { print("  GPU, frames drawing a scene: " + stat(drawnGpu)) }
if !keptGpu.isEmpty { print("  GPU, frames reusing it:      " + stat(keptGpu)) }
let cpu = samples.map { $0.core + $0.enc }.reduce(0, +) / Double(samples.count)
// (wall time of the core's frame and the encode: without --sync the encode
// includes waiting for a free frame slot, the GPU's back-pressure)
print(String(format: "  core + encode, wall, a frame %.3f ms = %.1f fps uncapped; frames drawn on the GPU %d, captured %d; wall %.0f ms",
             cpu, 1000 / cpu, samples.filter { $0.drew }.count, samples.filter { $0.captured }.count, wall))
if check { print(mismatched == 0 ? "  exact: \(warm + frames) of \(warm + frames) frames" : "  MISMATCH: \(mismatched) frames, worst \(worst) dots, first at \(firstBad)") }

if check, let gpu, thenParts.count == 2 {
    guard dingbat_load_rom(thenParts[0], nil) == 0 else { print("then: load_rom failed"); exit(1) }
    let st2 = try! Data(contentsOf: URL(fileURLWithPath: thenParts[1]))
    guard st2.withUnsafeBytes({ dingbat_load_state($0.baseAddress, Int32(st2.count), 0) }) == 1 else {
        print("then: load_state failed"); exit(1)
    }
    var bad2 = 0, first2 = -1
    for _ in 0..<frames {
        dingbat_run_frame()
        let cb = queue.makeCommandBuffer()!
        _ = try! gpu.encode(cb, k: k)
        if let t = gpu.screens, let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: W, height: H, depth: 1), to: readBuf, destinationOffset: 0,
                      destinationBytesPerRow: W * 2, destinationBytesPerImage: W * H * 2)
            blit.endEncoding()
        }
        cb.commit(); cb.waitUntilCompleted()
        let ref: UnsafePointer<UInt16> = k > 1 ? dingbat_nds_hd_fb()! : dingbat_game_fb()!
        let got = readBuf.contents().assumingMemoryBound(to: UInt16.self)
        var bad = 0
        for d in 0..<(W * H) where (got[d] & 0x7FFF) != (ref[d] & 0x7FFF) { bad += 1 }
        if bad > 0 { bad2 += 1; if first2 < 0 { first2 = Int(dingbat_nds_frame_count()) } }
    }
    print(bad2 == 0 ? "  then: exact: \(frames) of \(frames) frames"
                    : "  then: MISMATCH: \(bad2) of \(frames) frames, first at \(first2)")
}

// --- the last picture, for a look
if !pngPath.isEmpty {
    let cb = queue.makeCommandBuffer()!
    var src: UnsafePointer<UInt16>
    if let gpu, let t = gpu.screens, let blit = cb.makeBlitCommandEncoder() {
        blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: W, height: H, depth: 1), to: readBuf, destinationOffset: 0,
                  destinationBytesPerRow: W * 2, destinationBytesPerImage: W * H * 2)
        blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        src = UnsafePointer(readBuf.contents().assumingMemoryBound(to: UInt16.self))
    } else {
        src = dingbat_nds_hd_fb() ?? dingbat_game_fb()!
    }
    let w = gpu != nil ? W : (dingbat_nds_hd_fb() != nil ? Int(dingbat_nds_hd_fb_width()) : 256)
    let h = gpu != nil ? H : (dingbat_nds_hd_fb() != nil ? Int(dingbat_nds_hd_fb_height()) : 384)
    writePng(src, w, h, pngPath)
}
