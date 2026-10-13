#if DEBUG
import Metal
import QuartzCore
import UIKit

/// `-ff-trace`: what each display tick did and when its picture reached the
/// screen, for chasing pictures held too long (fast-forward above all).
/// Lines go to Documents/fftrace.txt (Files › On My iPhone › dingbat), all
/// times in ms of CACurrentMediaTime:
///
///   T seq ts target entry workEnd presentEnd ran changedMask presented hash speed outside wait budget aim
///       one display tick: the link's timestamp and targetTimestamp, the
///       callback's entry, the frames' end, the present's end, frames run,
///       which of them changed the picture (bit i = frame i), whether it
///       presented, a hash of the picture after the tick, the speed, the
///       main thread's busy ms since the last tick ended (SwiftUI, Core
///       Animation's commit, touches) and the ms the present waited for a
///       drawable, and fast-forward's frame budget and the vsync it aimed at
///   D seq presentedTime     the drawable's time on glass (device)
///   G seq gpuStart gpuEnd   the present's command buffer on the GPU
///   I t id down source      an input edge
///   M text                  a marker (press driver, settings)
///
/// `-ff-drive N` (with -ff-trace): a fresh Pokemon Emerald boots to Birch's
/// speech, then N taps of A at random moments along a touch's path (the
/// input, the lit pad, the haptic). `-ff-drive-speed ff|1x` picks the speed
/// of the tapping (default ff). `-ff-dump K`: the raw pictures of the ticks
/// around the first K taps into Documents/ffdump/. `-ff-drive-bare`: the
/// input alone; `-ff-drive-poke`: the input and a trivial view change.
///
/// GameSession's A/B switches: `-ff-old-publish` (republish every tick and
/// every input edge, as before), `-ff-no-defer` (screen changes at once in
/// fast-forward), `-ff-reserve MS` (fast-forward's slack before the
/// refresh, 3), `-ff-grid-target` (the simulator: its link calls back after
/// its own target, so fast-forward would run 4 ms a tick).
///
/// Summary: python3 ios/e2e/fftrace.py fftrace.txt --speed ff
final class FFTrace {
    static let on = ProcessInfo.processInfo.arguments.contains("-ff-trace")
    static let shared = FFTrace()

    private let lock = NSLock()
    private var pending: [String] = []
    private let file: URL
    private let ioQueue = DispatchQueue(label: "fftrace", qos: .utility)

    private var seq = 0
    private var cur: (ts: Double, target: Double, entry: Double)?
    private var mask: UInt64 = 0
    private var frameIndex = 0
    private var workEnd = 0.0, presentEnd = 0.0, drawableWait = 0.0
    private var presentedThisTick = false

    // Main-thread busy time outside the tick (run loop observer).
    private var wakeAt = 0.0
    private var lastTickEnd = 0.0
    private var busy = 0.0

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = docs.appendingPathComponent("fftrace.txt")
        guard Self.on else { return }
        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let obs = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 2_100_000 /* after Core Animation's commit */) { [weak self] _, act in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if act == .afterWaiting { self.wakeAt = now }
            else { self.busy += max(0, now - max(self.wakeAt, self.lastTickEnd)) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.flush() }
        log("M start \(UIDevice.current.model) \(UIDevice.current.systemVersion) maxfps \(UIScreen.main.maximumFramesPerSecond)")
    }

    private static func ms(_ t: Double) -> String { String(format: "%.3f", t * 1000) }

    func log(_ line: String) {
        lock.lock(); pending.append(line); lock.unlock()
    }

    func flush() {
        lock.lock(); let lines = pending; pending = []; lock.unlock()
        guard !lines.isEmpty else { return }
        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        let url = file
        ioQueue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            }
        }
    }

    // MARK: the tick

    func tickBegin(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        seq += 1
        cur = (link.timestamp, link.targetTimestamp, now)
        busy += max(0, now - max(wakeAt, lastTickEnd))
        mask = 0
        frameIndex = 0
        workEnd = 0; presentEnd = 0; drawableWait = 0
        presentedThisTick = false
        tickBudget = 0; tickTarget = 0
        driveTick()
    }

    private var tickBudget = 0.0, tickTarget = 0.0
    func budget(_ b: Double, target: Double) { tickBudget = b; tickTarget = target }

    func frame(changed: Bool) {
        if changed && frameIndex < 64 { mask |= 1 << UInt64(frameIndex) }
        frameIndex += 1
    }

    func beforePresent() {
        if cur != nil && workEnd == 0 { workEnd = CACurrentMediaTime() }
    }

    func afterPresent(wait: Double) {
        guard cur != nil else { return }
        presentEnd = CACurrentMediaTime()
        drawableWait += wait
        presentedThisTick = true
    }

    /// The drawable a present draws into: its time on glass and the GPU's.
    func drawable(_ d: MTLDrawable, _ cmd: MTLCommandBuffer) {
        let s = seq
        #if !targetEnvironment(simulator)
        d.addPresentedHandler { [weak self] dr in
            self?.log("D \(s) \(Self.ms(dr.presentedTime))")
        }
        #endif
        cmd.addCompletedHandler { [weak self] c in
            self?.log("G \(s) \(Self.ms(c.gpuStartTime)) \(Self.ms(c.gpuEndTime))")
        }
    }

    func tickEnd(ran: Int, speed: GameSession.Speed) {
        guard let c = cur else { return }
        let now = CACurrentMediaTime()
        if workEnd == 0 { workEnd = now }
        let h = Self.pictureHash()
        let sp: String
        switch speed { case .fastForward: sp = "ff"; case .double: sp = "2x"; case .slow: sp = "slow"; case .normal: sp = "1x" }
        log("T \(seq) \(Self.ms(c.ts)) \(Self.ms(c.target)) \(Self.ms(c.entry)) \(Self.ms(workEnd)) "
            + "\(presentedThisTick ? Self.ms(presentEnd) : "-") \(ran) \(String(mask, radix: 16)) "
            + "\(presentedThisTick ? 1 : 0) \(String(h, radix: 16)) \(sp) \(Self.ms(busy)) \(Self.ms(drawableWait)) \(Self.ms(tickBudget)) \(Self.ms(tickTarget))")
        busy = 0
        frames += ran
        dumpIfWanted(h)
        cur = nil
        lastTickEnd = CACurrentMediaTime()
    }

    func input(_ id: Int, _ down: Bool, _ source: String) {
        log("I \(Self.ms(CACurrentMediaTime())) \(id) \(down ? 1 : 0) \(source)")
    }

    /// FNV-1a over the picture's 64-bit words (a hash, not a checksum).
    static func pictureHash() -> UInt64 {
        guard let pic = GameRenderer.picture() else { return 0 }
        let n = pic.w * pic.h / 4
        var h: UInt64 = 1469598103934665603
        UnsafeRawPointer(pic.ptr).withMemoryRebound(to: UInt64.self, capacity: n) { p in
            for i in 0 ..< n { h = (h ^ (p[i] & 0x7FFF_7FFF_7FFF_7FFF)) &* 1099511628211 }
        }
        return h
    }

    // MARK: the press driver (-ff-drive N)

    private lazy var args = ProcessInfo.processInfo.arguments
    private func arg(_ f: String) -> String? {
        guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    private lazy var driveLeft: Int = arg("-ff-drive").flatMap(Int.init) ?? 0
    private lazy var dumpLeft: Int = arg("-ff-dump").flatMap(Int.init) ?? 0
    private var frames = 0
    private var introStep = 0
    private var tapping = false
    private var nextTap = 0.0
    private var dumpTicks = 0

    /// `-ff-drive-bare`: the input alone (no lit pad, no haptic).
    private lazy var bare = args.contains("-ff-drive-bare")
    /// `-ff-drive-poke`: the input and a 2-point view's colour, nothing else.
    private lazy var poke = args.contains("-ff-drive-poke")
    private var pokeView: UIView?

    private func press(_ id: Int, _ down: Bool) {
        let t0 = CACurrentMediaTime()
        let s = GameSession.shared
        s.setInput(id, down, source: "touch")
        if poke {
            // A trivial Core Animation change: does any commit near the
            // vsync cost the refresh, or only an expensive one?
            if pokeView == nil, let w = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
                let v = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
                w.addSubview(v)
                pokeView = v
            }
            pokeView?.backgroundColor = down ? .red : .blue
        } else if bare {
        } else if down {
            s.uiSoon { TouchPadState.shared.lit = [id] }
            Peripherals.shared.tap()
        } else {
            s.uiSoon { TouchPadState.shared.lit = [] }
        }
        log("M presscost \(down ? 1 : 0) \(Self.ms(CACurrentMediaTime() - t0))")
    }

    private func driveTick() {
        guard driveLeft > 0 else { return }
        let s = GameSession.shared
        // Boot to Birch's speech at fast-forward: START at the title, START
        // to the menu, A on NEW GAME (a new game's frame counts).
        let intro: [(Int, Int)] = [(900, 7), (1524, 7), (1632, 4)]
        if introStep == 0 { s.setSpeed(.fastForward); introStep = 1 }
        if introStep <= intro.count {
            let (at, id) = intro[introStep - 1]
            if frames >= at {
                press(id, true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.press(id, false) }
                introStep += 1
            }
            return
        }
        if !tapping {
            guard frames >= 2500 else { return }
            tapping = true
            s.setSpeed(arg("-ff-drive-speed") == "1x" ? .normal : .fastForward)
            log("M tapping \(arg("-ff-drive-speed") ?? "ff")")
            nextTap = CACurrentMediaTime() + 1
            return
        }
        let now = CACurrentMediaTime()
        guard now >= nextTap else { return }
        // A random moment inside the coming refresh interval, not at a tick.
        nextTap = .infinity
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.001 ..< 0.016)) {
            self.log("M tap \(self.driveLeft)")
            self.press(4, true)
            if self.dumpLeft > 0 { self.dumpTicks = 6; self.dumpLeft -= 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.05 ..< 0.11)) {
                self.press(4, false)
                self.driveLeft -= 1
                if self.driveLeft == 0 {
                    self.log("M done")
                    self.flush()
                } else {
                    self.nextTap = CACurrentMediaTime() + Double.random(in: 0.1 ..< 0.5)
                }
            }
        }
    }

    private func dumpIfWanted(_ h: UInt64) {
        guard dumpTicks > 0 || (dumpLeft > 0 && tapping && nextTap.isFinite && CACurrentMediaTime() > nextTap - 0.05),
              let pic = GameRenderer.picture() else { return }
        if dumpTicks > 0 { dumpTicks -= 1 }
        let dir = file.deletingLastPathComponent().appendingPathComponent("ffdump")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = Data(bytes: pic.ptr, count: pic.w * pic.h * 2)
        try? data.write(to: dir.appendingPathComponent("\(seq)_\(String(h, radix: 16)).raw"))
    }
}
#endif
