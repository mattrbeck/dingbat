import SwiftUI
import UIKit

/// A DS game's own state beside the session (web index.js "Nintendo DS"):
/// the display choices (Settings › Nintendo DS and the Screens panel), the
/// lid, Blow, the switched-off console, the arrangement on the stage now,
/// and the BIOS / firmware files the core boots on. GameSession calls in at
/// a load, after frames and after a state load; everything else is the
/// views'.
final class NdsState: ObservableObject {
    static let shared = NdsState()

    private let d = UserDefaults.standard

    // MARK: display choices (web nds-layout, nds-display { swap, gap, rot, barHide })

    @Published var arrangement: NdsUtil.Arrangement {
        didSet { d.set(arrangement.rawValue, forKey: "nds-layout"); displayChanged() }
    }
    @Published var swap: Bool { didSet { saveDisplay() } }
    @Published var gap: NdsUtil.Gap { didSet { saveDisplay() } }
    /// 0 upright, 3 Book left, 1 Book right.
    @Published var rot: Int { didSet { saveDisplay() } }
    /// "Hide the top bar" on a phone held upright (default on).
    @Published var barHide: Bool { didSet { saveDisplay() } }

    // MARK: the console

    /// The hinge (web ndsLidClosed): every boot starts open.
    @Published private(set) var lidClosed = false
    /// The game switched the DS off (web ndsOff).
    @Published private(set) var poweredOff = false
    /// What holds Blow down: "key", or the panel's button.
    @Published private(set) var blowers: Set<String> = []
    var blowing: Bool { !blowers.isEmpty }
    /// The Screens panel under the bar's screens button.
    @Published var panelOpen = false

    /// The arrangement on the stage now and the picture's frame (window
    /// coordinates): GameStage lays it out, the stylus and the bar's tap
    /// read it.
    var layout = NdsUtil.Layout()
    var pictureFrame: CGRect = .null

    private init() {
        arrangement = NdsUtil.Arrangement(rawValue: d.string(forKey: "nds-layout") ?? "") ?? .auto
        // A damaged record falls back field by field (web applyNdsDisplay).
        var o: [String: Any] = [:]
        if let s = d.string(forKey: "nds-display"), let data = s.data(using: .utf8),
           let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { o = v }
        swap = o["swap"] as? Bool ?? false
        gap = (o["gap"] as? String).flatMap(NdsUtil.Gap.init(rawValue:)) ?? .hinge
        let r = (o["rot"] as? NSNumber)?.intValue ?? 0
        rot = NdsUtil.rotations.contains(r) ? r : 0
        barHide = o["barHide"] as? Bool ?? true
    }

    private func saveDisplay() {
        let o: [String: Any] = ["swap": swap, "gap": gap.rawValue, "rot": rot, "barHide": barHide]
        if let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) {
            d.set(String(decoding: data, as: UTF8.self), forKey: "nds-display")
        }
        displayChanged()
    }

    /// A stylus held through a change would land elsewhere (web ndsTouchEnd).
    private func displayChanged() {
        NdsStylusView.current?.lift()
    }

    /// Settings › General › Reset all settings clears both records.
    func resetDisplay() {
        d.removeObject(forKey: "nds-layout")
        d.removeObject(forKey: "nds-display")
        arrangement = .auto
        swap = false
        gap = .hinge
        rot = 0
        barHide = true
    }

    func swapScreens() { swap.toggle() }

    /// V on a keyboard: the next arrangement, with a toast.
    func nextArrangement() {
        let all = NdsUtil.Arrangement.allCases
        arrangement = all[((all.firstIndex(of: arrangement) ?? 0) + 1) % all.count]
        AppModel.shared.toast("Screens: " + arrangement.label)
    }

    /// O on a keyboard: the next turn.
    func nextTurn() {
        let r = NdsUtil.rotations
        rot = r[((r.firstIndex(of: rot) ?? 0) + 1) % r.count]
    }

    // MARK: lid, Blow, power

    func setLid(_ closed: Bool) {
        lidClosed = closed
        if closed { NdsStylusView.current?.lift() }
        if dingbat_is_nds() != 0 { dingbat_nds_set_lid(closed ? 1 : 0) }
    }

    func blow(_ who: String, _ on: Bool) {
        if on { blowers.insert(who) } else { blowers.remove(who) }
    }

    /// Blow: one emulated frame of noise before each frame, at 16 kHz (web
    /// ndsBlowFrame; the microphone's own rate while it is on).
    static let blowRate = 16000
    func blowFrame() {
        guard blowing else { return }
        let n = Int((Double(Self.blowRate) / NdsUtil.fps).rounded(.up))
        let noise = NdsUtil.blowNoise(n)
        noise.withUnsafeBufferPointer { dingbat_nds_push_mic($0.baseAddress, Int32(n), Int32(Self.blowRate)) }
    }

    /// A boot (load or reset): the lid open, nothing held.
    func booted() {
        lidClosed = false
        blowers = []
        NdsStylusView.current?.lift()
    }

    /// The game is gone (closed, or another game took the core).
    func left() {
        lidClosed = false
        blowers = []
        panelOpen = false
        NdsMic.shared.stop()
        if poweredOff { poweredOff = false }
        NdsStylusView.current?.lift()
    }

    /// The core's power, read after anything that can change it: frames,
    /// a load, a reset, a state load. Returns true on the change to off.
    @discardableResult
    func syncPower() -> Bool {
        let off = dingbat_is_nds() != 0 && dingbat_nds_powered_off() != 0
        guard off != poweredOff else { return false }
        poweredOff = off
        if off {
            blowers = []
            NdsMic.shared.stop()
            NdsStylusView.current?.lift()
        }
        return off
    }

    // MARK: BIOS, firmware, the console's flash

    /// Optional dumps (Settings › Nintendo DS), in Application Support's
    /// bios folder beside the GBA BIOS: the HLE BIOS and a synthesized
    /// firmware when absent.
    static func biosURL(_ k: NdsUtil.BiosKind) -> URL { RomLibrary.biosDir.appendingPathComponent(k.fileName) }

    /// This device's DS firmware flash (web bios:ndsflash): what a game or
    /// the DS menu writes (name, birthday, language, Wi-Fi connections),
    /// one per device, shared by every DS game, never synced.
    static let flashURL = RomLibrary.biosDir.appendingPathComponent("nds_flash.bin")

    /// Before each DS load: the dumps there are and the flash file.
    static func prepareLoad() {
        try? RomLibrary.ensureDir(RomLibrary.biosDir)
        func path(_ k: NdsUtil.BiosKind) -> String? {
            let u = biosURL(k)
            return FileManager.default.fileExists(atPath: u.path) ? u.path : nil
        }
        dingbat_set_nds_flash_path(flashURL.path)
        dingbat_set_nds_bios(path(.bios9), path(.bios7), path(.firmware))
    }

    /// Whether a point (window coordinates) is the DS screens' own: the
    /// touch screen (the stylus), or the top screen where a tap swaps them
    /// (Focus, One screen). The bar's tap leaves those alone (web ndsTapTaken).
    func tapTaken(_ p: CGPoint) -> Bool {
        guard GameSession.shared.isNDS, !pictureFrame.isNull, pictureFrame.width > 0 else { return false }
        if NdsUtil.touchPoint(p, pictureFrame, layout).inside { return true }
        return layout.oneLarge && NdsUtil.screenAt(p, pictureFrame, layout) == .top
    }
}

// MARK: - The stylus

/// Over the picture of a DS game: a touch that starts on the bottom screen
/// is the stylus (dingbat_nds_touch, mapped through the arrangement and
/// turn by NdsUtil.touchPoint, clamped while it drags, lifted with the
/// finger), one finger at a time; in Focus and One screen a short tap on
/// the top screen swaps them (lifted within 500 ms and 12 pt). Anything
/// else passes through to the stage (the bar's tap).
struct NdsStylus: UIViewRepresentable {
    func makeUIView(context: Context) -> NdsStylusView {
        let v = NdsStylusView()
        NdsStylusView.current = v
        return v
    }

    func updateUIView(_ v: NdsStylusView, context: Context) {
        NdsStylusView.current = v
        v.setNeedsLayout()
    }

    static func dismantleUIView(_ v: NdsStylusView, coordinator: ()) {
        v.lift()
        if NdsStylusView.current === v { NdsStylusView.current = nil }
    }
}

final class NdsStylusView: UIView {
    static weak var current: NdsStylusView?

    private var touch: UITouch?
    private var swapTap: (touch: UITouch, at: CGPoint, t: CFTimeInterval)?
    private var nds: NdsState { .shared }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        notePicture()
    }

    /// The picture's frame in window coordinates (the bar's tap tests it).
    func notePicture() {
        nds.pictureFrame = window == nil ? .null : convert(bounds, to: nil)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        notePicture()
    }

    private func takes(_ p: CGPoint) -> Bool {
        guard GameSession.shared.isNDS, !nds.lidClosed, !nds.poweredOff, bounds.width > 0 else { return false }
        let lay = nds.layout
        if NdsUtil.touchPoint(p, bounds, lay).inside { return true }
        return lay.oneLarge && NdsUtil.screenAt(p, bounds, lay) == .top
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard AppModel.shared.screen == .play, !AppModel.shared.menuOpen else { return nil }
        return takes(point) ? self : nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            let hit = NdsUtil.touchPoint(p, bounds, nds.layout)
            if hit.inside {
                guard touch == nil, !nds.lidClosed else { continue }
                touch = t
                down(at: p)
            } else if nds.layout.oneLarge, NdsUtil.screenAt(p, bounds, nds.layout) == .top, swapTap == nil {
                swapTap = (t, p, CACurrentMediaTime())
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touch, touches.contains(t) { down(at: t.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let tap = swapTap, touches.contains(tap.touch) {
            swapTap = nil
            let p = tap.touch.location(in: self)
            if CACurrentMediaTime() - tap.t < 0.5 && hypot(p.x - tap.at.x, p.y - tap.at.y) < 12 {
                nds.swapScreens()
            }
        }
        if let t = touch, touches.contains(t) { up(at: t.location(in: self)) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let tap = swapTap, touches.contains(tap.touch) { swapTap = nil }
        if let t = touch, touches.contains(t) { lift() }
    }

    /// The stylus down (or moving) at a point of this view: the bottom
    /// screen's pixel under it, clamped to the screen's edge.
    func down(at p: CGPoint) {
        let hit = NdsUtil.touchPoint(p, bounds, nds.layout)
        guard dingbat_is_nds() != 0 else { return }
        dingbat_nds_touch(Int32(hit.x), Int32(hit.y), 1)
    }

    private func up(at p: CGPoint) {
        touch = nil
        let hit = NdsUtil.touchPoint(p, bounds, nds.layout)
        if dingbat_is_nds() != 0 { dingbat_nds_touch(Int32(hit.x), Int32(hit.y), 0) }
    }

    /// Let go wherever it is (a layout change, the lid, a pause).
    func lift() {
        swapTap = nil
        guard touch != nil else { return }
        touch = nil
        if dingbat_is_nds() != 0 { dingbat_nds_touch(0, 0, 0) }
    }

    #if DEBUG
    /// `-nds-touch X,Y[,frames]`: the stylus on the bottom screen's pixel
    /// (X, Y), aimed by NdsUtil.clientPoint and sent through the same
    /// mapping a finger takes, held for some frames, then lifted. Logs
    /// what it sent to tmp/ndstouch.txt.
    func selfTest(_ px: Int, _ py: Int, hold: Double) {
        guard let p = NdsUtil.clientPoint(.bottom, px, py, bounds, nds.layout) else { return }
        let hit = NdsUtil.touchPoint(p, bounds, nds.layout)
        let line = "aim \(px),\(py) -> point \(p.x),\(p.y) in \(bounds.size) -> pixel \(hit.x),\(hit.y) inside=\(hit.inside)\n"
        try? line.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ndstouch.txt"),
                        atomically: true, encoding: .utf8)
        down(at: p)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            if dingbat_is_nds() != 0 { dingbat_nds_touch(Int32(hit.x), Int32(hit.y), 0) }
            self?.touch = nil
        }
    }
    #endif
}
