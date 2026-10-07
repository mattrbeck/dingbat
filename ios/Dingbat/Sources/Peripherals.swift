import AVFoundation
import Combine
import CoreHaptics
import CoreMotion
import SwiftUI
import UIKit

/// Sensors, haptics, controllers, camera: installed once at launch.
///
/// - Haptics: a light tick on each touch press and direction change (a
///   native extra; the web's vibrate does nothing on iOS), gated by
///   Settings › Controls › Haptics.
/// - Rumble (web updateRumble): the cart's motor runs a continuous Core
///   Haptics effect on the phone and on every controller with haptics; the
///   stage shakes the picture itself.
/// - Tilt carts (web "Tilt cart input"): the device's attitude against a
///   captured neutral pose, ±25° = full deflection; gyro carts read the
///   rotation rate. The d-pad and the controller's left stick tilt too.
/// - GB Camera (web "GB Camera webcam source"): a real camera, cover-cropped
///   to the 128x120 sensor in grey at ~15 fps; until then the viewfinder
///   carries a text notice saying how to turn it on.
final class Peripherals: ObservableObject {
    static let shared = Peripherals()

    /// A real camera feeds the cart (the bar's camera button switches it).
    @Published private(set) var cameraOn = false {
        // The top bar observes the session, not this.
        didSet { GameSession.shared.objectWillChange.send() }
    }

    private var session: GameSession { .shared }
    private var model: AppModel { .shared }
    private var bag = Set<AnyCancellable>()

    func install() {
        session.onRumble = { [weak self] on in self?.rumble(on) }
        session.onTick = { [weak self] in self?.tick() }
        Controllers.shared.start()
        // tiltKind and hasCamera are set after `game` in GameSession.open:
        // look once the open has finished.
        session.$game
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.gameChanged() }
            .store(in: &bag)
        // The motor stops with the game: paused, the loop no longer reports.
        session.$paused
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRumble() }
            .store(in: &bag)
    }

    private var tiltGame: RomEntry?
    private var cameraGame: RomEntry?

    private func gameChanged() {
        let game = session.game
        if game == nil || !session.hasCamera {
            stopCamera()
            cameraGame = nil
        }
        if game == nil || session.tiltKind == 0 {
            stopTilt()
            tiltGame = nil
        }
        refreshRumble()
        guard let game else { return }
        if session.tiltKind > 0 && tiltGame != game {
            tiltGame = game
            startTilt()
        }
        if session.hasCamera && cameraGame != game {
            cameraGame = game
            detectCamera()
        }
    }

    /// Each display tick that ran frames.
    private func tick() {
        noteOrientation()
        tiltTick()
    }

    // MARK: - haptics

    private let tapper = UIImpactFeedbackGenerator(style: .light)

    /// A touch press or direction change.
    func tap() {
        guard Settings.shared.haptics else { return }
        tapper.impactOccurred()
        tapper.prepare()
    }

    // MARK: - rumble

    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var rumbleOn = false

    private func rumble(_ on: Bool) {
        rumbleOn = on
        refreshRumble()
    }

    private func refreshRumble() {
        let on = rumbleOn && session.game != nil && !session.paused && Settings.shared.rumble
        Controllers.shared.setRumble(on)
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        if on {
            if engine == nil {
                engine = try? CHHapticEngine()
                engine?.isAutoShutdownEnabled = true
                engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
            }
            if player == nil, let engine { player = Self.startRumble(on: engine) }
        } else {
            try? player?.stop(atTime: CHHapticTimeImmediate)
            player = nil
        }
    }

    /// A looping continuous buzz: strong and low, like the cart's motor.
    static func startRumble(on engine: CHHapticEngine) -> CHHapticAdvancedPatternPlayer? {
        do {
            try engine.start()
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
            ], relativeTime: 0, duration: 2)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            try player.start(atTime: CHHapticTimeImmediate)
            return player
        } catch {
            return nil
        }
    }

    // MARK: - orientation

    private var orientation: UIInterfaceOrientation = .unknown

    private static var interfaceOrientation: UIInterfaceOrientation {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .portrait
    }

    private func noteOrientation() {
        let now = Self.interfaceOrientation
        guard now != orientation else { return }
        let first = orientation == .unknown
        orientation = now
        if !first {
            rebaselineTilt()
            camera?.setOrientation(now)
        }
    }

    // MARK: - tilt

    private static let padRange = 0.65      // the d-pad's full deflection: playable, not violent
    private static let smoothing = 0.18     // per tick toward the d-pad / stick target
    private static let orientRange = 25.0   // degrees of physical tilt = full deflection
    private static let glideSeconds = 0.38  // a re-baseline eases in over this
    private static let glideRate = 0.16
    private static let rebaseSeconds = 0.45 // after a turn, when the stale neutral goes
    private static let settleSeconds = 0.65 // after a turn, when motion counts again

    private let motion = CMMotionManager()
    private var motionOn = false
    private var neutral: CMAttitude?
    private var tiltX = 0.0, tiltY = 0.0
    private var targetX = 0.0, targetY = 0.0
    private var glideUntil = Date.distantPast
    private var settleUntil = Date.distantPast
    private var rebaseWork: DispatchWorkItem?

    private func startTilt() {
        tiltX = 0; tiltY = 0; targetX = 0; targetY = 0
        neutral = nil
        glideUntil = Date().addingTimeInterval(Self.glideSeconds)
        if motion.isDeviceMotionAvailable {
            if !motionOn {
                motion.deviceMotionUpdateInterval = 1.0 / 60
                motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
                motionOn = true
            }
            model.toast("Tilt cart detected — hold your comfortable angle now", duration: 4, game: true)
        } else {
            model.toast("Tilt cart detected — D-pad or stick tilts the game", duration: 4, game: true)
        }
    }

    private func stopTilt() {
        if motionOn { motion.stopDeviceMotionUpdates() }
        motionOn = false
        neutral = nil
        rebaseWork?.cancel()
    }

    /// The top bar's Recenter: the angle the device is held at now becomes
    /// level.
    func recenterTilt() {
        guard session.tiltKind > 0 else { return }
        guard motionOn else {
            model.toast("No motion sensor here — D-pad and stick tilt the game")
            return
        }
        neutral = nil
        glideUntil = Date().addingTimeInterval(Self.glideSeconds)
        model.toast("Tilt recentered")
    }

    /// A turn changes the axes and the pose: freeze motion through it, then
    /// take the settled pose as level.
    private func rebaselineTilt() {
        guard motionOn else { return }
        settleUntil = Date().addingTimeInterval(Self.settleSeconds)
        rebaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.motionOn else { return }
            self.neutral = nil
            self.glideUntil = Date().addingTimeInterval(Self.glideSeconds)
            self.model.toast("Tilt recentered for the new orientation")
        }
        rebaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rebaseSeconds, execute: work)
    }

    private func tiltTick() {
        let kind = session.tiltKind
        guard kind > 0, session.game != nil else { return }
        let now = Date()
        var fromSensor = false
        let held = session.held
        if let s = Controllers.shared.stick {
            targetX = Double(s.x); targetY = Double(s.y)
        } else if !held.isDisjoint(with: [0, 1, 2, 3]) {
            targetY = (held.contains(0) ? -Self.padRange : 0) + (held.contains(1) ? Self.padRange : 0)
            targetX = (held.contains(2) ? -Self.padRange : 0) + (held.contains(3) ? Self.padRange : 0)
        } else if motionOn, let dm = motion.deviceMotion {
            fromSensor = true
            if now < settleUntil {
                // Mid-turn: hold the last value (a snap to level is a flick).
            } else if kind == 2 {
                // Gyro cart: the rotation rate about the screen's normal;
                // 180°/s is extreme.
                targetX = max(-1, min(1, dm.rotationRate.z * 180 / .pi / 180))
                targetY = 0
            } else {
                if neutral == nil { neutral = dm.attitude.copy() as? CMAttitude }
                if let neutral, let rel = dm.attitude.copy() as? CMAttitude {
                    rel.multiply(byInverseOf: neutral)
                    // Device frame (roll: right edge down; pitch: top edge
                    // up) into the screen's, as the interface is turned.
                    let (sx, sy) = Self.toScreen(rel.roll * 180 / .pi, rel.pitch * 180 / .pi)
                    targetX = max(-1, min(1, sx / Self.orientRange))
                    targetY = max(-1, min(1, sy / Self.orientRange))
                }
            }
        } else {
            targetX = 0; targetY = 0
        }
        if fromSensor && now >= glideUntil {
            // The real sensor goes raw: the cart reads acceleration from
            // the value's steps.
            tiltX = targetX; tiltY = targetY
        } else {
            let k = fromSensor ? Self.glideRate : Self.smoothing
            tiltX += (targetX - tiltX) * k
            tiltY += (targetY - tiltY) * k
        }
        // Negated at the send: the ball rolls into the tilt.
        let clamp3 = { (v: Double) in max(-3, min(3, v)) }
        dingbat_set_tilt(clamp3(-tiltX), clamp3(-tiltY))
    }

    private static func toScreen(_ x: Double, _ y: Double) -> (Double, Double) {
        let angle: Double
        switch interfaceOrientation {
        case .landscapeRight: angle = 90
        case .portraitUpsideDown: angle = 180
        case .landscapeLeft: angle = 270
        default: angle = 0
        }
        let r = angle * .pi / 180
        let c = cos(r), s = sin(r)
        return (x * c + y * s, -x * s + y * c)
    }

    // MARK: - GB Camera

    private var camera: CameraFeed?
    private var cameraPosition: AVCaptureDevice.Position = .back

    /// What the viewfinder says while no camera feeds it (web CAM_NOTICES;
    /// "/" breaks the line).
    private enum Notice: String {
        case prompt = "Tap the / camera button / in the top bar"
        case blocked = "Camera / access is / off in / Settings"
        case missing = "No camera / found on / this device"
    }

    private func detectCamera() {
        if cameraOn {
            // A fresh core: point it at the live feed again.
            _ = dingbat_camera_attach()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: showNotice(.blocked)
        default: showNotice(.prompt)
        }
        model.toast("Game Boy Camera cart — use your real camera?",
                    action: ("Enable camera", { [weak self] in self?.cameraButton() }), duration: 10, game: true)
    }

    /// The top bar's camera button: the first press asks and starts the
    /// camera; later presses switch between the back and front cameras.
    func cameraButton() {
        guard session.hasCamera else { return }
        if cameraOn {
            switchCamera()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session.hasCamera else { return }
                    if granted { self.startCamera() } else { self.cameraDenied() }
                }
            }
        default:
            cameraDenied()
        }
    }

    private func cameraDenied() {
        showNotice(.blocked)
        model.toast("Camera access is off for dingbat — the viewfinder says so",
                    action: ("Settings", {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }), duration: 8, game: true)
    }

    private func startCamera() {
        guard !cameraOn else { return }
        let feed = CameraFeed()
        guard feed.configure(position: cameraPosition, orientation: Self.interfaceOrientation)
                || feed.configure(position: cameraPosition == .back ? .front : .back,
                                  orientation: Self.interfaceOrientation) else {
            showNotice(.missing)
            model.toast("No camera available — the viewfinder says so", game: true)
            return
        }
        cameraPosition = feed.position
        guard dingbat_camera_attach() > 0 else { return }
        feed.onFrame = { [weak self] grey in
            guard let self, self.cameraOn, self.session.hasCamera,
                  let dst = dingbat_camera_frame() else { return }
            grey.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: min($0.count, CameraFeed.width * CameraFeed.height)) }
        }
        feed.start()
        camera = feed
        cameraOn = true
        model.toast("Camera live — the cart sees what you see", game: true)
    }

    private func switchCamera() {
        guard let feed = camera else { return }
        let next: AVCaptureDevice.Position = feed.position == .back ? .front : .back
        if feed.switchTo(next, orientation: Self.interfaceOrientation) {
            cameraPosition = next
            model.toast(next == .front ? "Camera: Front" : "Camera: Back")
        } else {
            model.toast("Couldn't switch camera")
        }
    }

    private func stopCamera() {
        camera?.stop()
        camera = nil
        if cameraOn { cameraOn = false }
    }

    /// Lay the notice's lines over the 112 sensor rows the cart keeps,
    /// white on black, each fitted to the width, and put it in the sensor.
    private func showNotice(_ n: Notice) {
        guard dingbat_camera_attach() > 0, let dst = dingbat_camera_frame() else { return }
        let w = CameraFeed.width, h = CameraFeed.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        let lines = n.rawValue.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        let slot = 112 / CGFloat(lines.count)
        for (i, text) in lines.enumerated() {
            var px = min(slot * 0.8, 44)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: px, weight: .black), .foregroundColor: UIColor.white,
            ]
            var size = (text as NSString).size(withAttributes: attrs)
            if size.width > CGFloat(w - 4) {
                px = px * CGFloat(w - 4) / size.width
                attrs[.font] = UIFont.systemFont(ofSize: px, weight: .black)
                size = (text as NSString).size(withAttributes: attrs)
            }
            let y = 4 + slot * (CGFloat(i) + 0.5) - size.height / 2
            (text as NSString).draw(at: CGPoint(x: (CGFloat(w) - size.width) / 2, y: y), withAttributes: attrs)
        }
        UIGraphicsPopContext()
        guard let src = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return }
        dst.update(from: src, count: w * h)
    }
}

/// An AVCaptureSession whose frames come out as the cart's 128x120 grey,
/// cover-cropped (the front camera mirrored), at ~15 fps.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let width = 128, height = 120

    private let capture = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dingbat.camera")
    private var lastFrame: CFTimeInterval = 0
    private(set) var position: AVCaptureDevice.Position = .back
    /// Called on the main thread with each frame.
    var onFrame: (([UInt8]) -> Void)?

    func configure(position: AVCaptureDevice.Position, orientation: UIInterfaceOrientation) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        capture.beginConfiguration()
        defer { capture.commitConfiguration() }
        if capture.canSetSessionPreset(.vga640x480) { capture.sessionPreset = .vga640x480 }
        guard capture.canAddInput(input) else { return false }
        capture.addInput(input)
        if !capture.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard capture.canAddOutput(output) else { return false }
            capture.addOutput(output)
        }
        self.position = position
        applyConnection(orientation)
        return true
    }

    /// Swap the input under the running session.
    func switchTo(_ next: AVCaptureDevice.Position, orientation: UIInterfaceOrientation) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: next),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        capture.beginConfiguration()
        defer { capture.commitConfiguration() }
        let old = capture.inputs
        old.forEach(capture.removeInput)
        guard capture.canAddInput(input) else {
            old.forEach { if capture.canAddInput($0) { capture.addInput($0) } }
            return false
        }
        capture.addInput(input)
        position = next
        applyConnection(orientation)
        return true
    }

    func setOrientation(_ o: UIInterfaceOrientation) {
        capture.beginConfiguration()
        applyConnection(o)
        capture.commitConfiguration()
    }

    /// Frames upright for the way the screen is turned; the front camera
    /// mirrored, as a mirror would show it.
    private func applyConnection(_ o: UIInterfaceOrientation) {
        guard let conn = output.connection(with: .video) else { return }
        if conn.isVideoOrientationSupported {
            switch o {
            case .landscapeLeft: conn.videoOrientation = .landscapeLeft
            case .landscapeRight: conn.videoOrientation = .landscapeRight
            case .portraitUpsideDown: conn.videoOrientation = .portraitUpsideDown
            default: conn.videoOrientation = .portrait
            }
        }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = position == .front
        }
    }

    func start() {
        queue.async { [capture] in capture.startRunning() }
    }

    func stop() {
        onFrame = nil
        queue.async { [capture] in capture.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrame >= 1.0 / 15 - 0.004,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return }
        let vw = CVPixelBufferGetWidthOfPlane(pb, 0), vh = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ow = Self.width, oh = Self.height
        // Cover-crop: the largest centred box of the sensor's shape.
        let scale = max(Double(ow) / Double(vw), Double(oh) / Double(vh))
        let sw = Double(ow) / scale, sh = Double(oh) / scale
        let sx = (Double(vw) - sw) / 2, sy = (Double(vh) - sh) / 2
        let bx = sw / Double(ow), by = sh / Double(oh)
        var grey = [UInt8](repeating: 0, count: ow * oh)
        // The luma plane, each output pixel the mean of a 2x2 sample of its
        // block.
        for y in 0..<oh {
            let y0 = Int(sy + (Double(y) + 0.25) * by), y1 = min(vh - 1, Int(sy + (Double(y) + 0.75) * by))
            for x in 0..<ow {
                let x0 = Int(sx + (Double(x) + 0.25) * bx), x1 = min(vw - 1, Int(sx + (Double(x) + 0.75) * bx))
                let s = Int(base[y0 * stride + x0]) + Int(base[y0 * stride + x1])
                    + Int(base[y1 * stride + x0]) + Int(base[y1 * stride + x1])
                grey[y * ow + x] = UInt8(s >> 2)
            }
        }
        DispatchQueue.main.async { [weak self] in self?.onFrame?(grey) }
    }
}
