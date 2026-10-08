import Combine
import CoreHaptics
import GameController
import SwiftUI

/// Game controllers (web pollGamepads, standard mapping), in the game view:
/// A/Y → A, B/X → B, Options → Select, Menu → Start, LB → L, RB → R, the
/// d-pad and the left stick (deadzone 0.4) → directions. The triggers and
/// the stick click are the app's: RT holds fast-forward, LT holds rewind,
/// and R3 or Select+Start held 500 ms opens the menu, paused. A connected
/// controller hides the touch controls when Settings says so.
///
/// Event-driven (each pad's valueChangedHandler) rather than polled: the
/// frame loop stands still while paused or rewinding, and a trigger let go
/// then must still be heard.
final class Controllers {
    static let shared = Controllers()

    /// The left stick while deflected, screen-down positive (a tilt cart's
    /// accelerometer when one is in).
    private(set) var stick: CGPoint?

    private static let deadzone: Float = 0.4
    private static let chordSeconds = 0.5

    private var sent: Set<Int> = []
    private var fastForwardHeld = false
    private var rewindHeld = false
    private var r3Was = false
    private var chordTimer: Timer?
    private var chordFired = false
    private var engines: [ObjectIdentifier: (CHHapticEngine, CHHapticAdvancedPatternPlayer?)] = [:]
    /// Outside the game: the UI buttons held at the last read, the
    /// direction repeating while held, and whether the game had the pad.
    private var uiHeld: Set<String> = []
    private var repeatTimer: Timer?
    private var wasInGame = true
    /// Console buttons held when the game got the pad back: not presses
    /// until let go (the B that closed the menu).
    private var arrivalHeld: Set<Int> = []
    private var bag = Set<AnyCancellable>()

    private var session: GameSession { .shared }
    private var model: AppModel { .shared }

    func start() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
            self?.refreshHidesTouch()
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.engines[ObjectIdentifier(c)] = nil }
            self?.refreshHidesTouch()
            self?.update()
        }
        GCController.controllers().forEach(attach)
        refreshHidesTouch()
        Settings.shared.$hideTouchOnGamepad
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshHidesTouch() }
            .store(in: &bag)
        // Leaving the game (menu, a sheet, home) lets go of everything the
        // pad held there.
        Publishers.Merge3(model.$menuOpen.map { _ in () }, model.$sheet.map { _ in () },
                          model.$screen.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                PadNav.shared.scopeChanged()
                Keyboard.shared.releaseAll()
                self?.update()
            }
            .store(in: &bag)
    }

    var connected: Bool { GCController.controllers().contains { $0.extendedGamepad != nil } }

    private func refreshHidesTouch() {
        let hide = Settings.shared.hideTouchOnGamepad && connected
        if model.gamepadHidesTouch != hide { model.gamepadHidesTouch = hide }
    }

    private func attach(_ c: GCController) {
        c.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in self?.update() }
    }

    private var inGame: Bool {
        model.screen == .play && session.game != nil && !model.menuOpen && model.sheet == nil
    }

    /// Read every pad and act on what changed.
    private func update() {
        var want: Set<Int> = []
        var rt = false, lt = false, r3 = false, select = false, startBtn = false
        var stickNow: CGPoint?
        var ui: Set<String> = []
        for c in GCController.controllers() {
            guard let p = c.extendedGamepad else { continue }
            if p.buttonA.isPressed { ui.insert("a") }
            if p.buttonB.isPressed { ui.insert("b") }
            if p.buttonY.isPressed { ui.insert("y") }
            if p.leftShoulder.isPressed { ui.insert("lb") }
            if p.rightShoulder.isPressed { ui.insert("rb") }
            if p.leftTrigger.isPressed { ui.insert("lt") }
            if p.rightTrigger.isPressed { ui.insert("rt") }
            if p.buttonMenu.isPressed { ui.insert("start") }
            if p.buttonA.isPressed || p.buttonY.isPressed { want.insert(4) }
            if p.buttonB.isPressed || p.buttonX.isPressed { want.insert(5) }
            if p.buttonOptions?.isPressed == true { want.insert(6); select = true }
            if p.buttonMenu.isPressed { want.insert(7); startBtn = true }
            if p.leftShoulder.isPressed { want.insert(8) }
            if p.rightShoulder.isPressed { want.insert(9) }
            if p.dpad.up.isPressed { want.insert(0) }
            if p.dpad.down.isPressed { want.insert(1) }
            if p.dpad.left.isPressed { want.insert(2) }
            if p.dpad.right.isPressed { want.insert(3) }
            let ax = p.leftThumbstick.xAxis.value, ay = -p.leftThumbstick.yAxis.value
            if ay < -Self.deadzone { want.insert(0) }
            if ay > Self.deadzone { want.insert(1) }
            if ax < -Self.deadzone { want.insert(2) }
            if ax > Self.deadzone { want.insert(3) }
            if abs(ax) > 0.1 || abs(ay) > 0.1 { stickNow = CGPoint(x: CGFloat(ax), y: CGFloat(ay)) }
            rt = rt || p.rightTrigger.isPressed
            lt = lt || p.leftTrigger.isPressed
            r3 = r3 || p.rightThumbstickButton?.isPressed == true
        }
        stick = stickNow
        for (dir, id) in [("up", 0), ("down", 1), ("left", 2), ("right", 3)] where want.contains(id) { ui.insert(dir) }
        let nowInGame = inGame
        if nowInGame != wasInGame {
            // Held across the switch: not a press on arrival.
            if nowInGame { arrivalHeld = want } else { uiHeld = ui }
            wasInGame = nowInGame
        }
        guard nowInGame else {
            letGo()
            r3Was = r3
            drive(ui)
            return
        }
        uiHeld = []
        repeatTimer?.invalidate()
        arrivalHeld.formIntersection(want)
        want.subtract(arrivalHeld)
        // The triggers' holds.
        if rt != fastForwardHeld {
            fastForwardHeld = rt
            session.holdFastForward(rt)
        }
        if lt != rewindHeld {
            rewindHeld = lt
            session.setRewinding(lt)
        }
        // R3, or Select+Start held: the menu, paused.
        let r3Hit = r3 && !r3Was
        r3Was = r3
        if select && startBtn {
            if chordTimer == nil && !chordFired {
                chordTimer = Timer.scheduledTimer(withTimeInterval: Self.chordSeconds, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.chordTimer = nil
                    self.chordFired = true
                    if self.inGame { self.openMenu() }
                }
            }
        } else {
            chordTimer?.invalidate()
            chordTimer = nil
            chordFired = false
        }
        if r3Hit {
            openMenu()
            return
        }
        send(want)
    }

    /// The UI's turn (PadNav): presses on the way down, directions
    /// repeating while held.
    private func drive(_ now: Set<String>) {
        let pressed = now.subtracting(uiHeld)
        uiHeld = now
        let nav = PadNav.shared
        let dirs: [String: PadNav.Dir] = ["up": .up, "down": .down, "left": .left, "right": .right]
        for (name, dir) in dirs where pressed.contains(name) {
            nav.move(dir)
            repeatTimer?.invalidate()
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] t in
                    guard let self, self.uiHeld.contains(name) else { t.invalidate(); return }
                    nav.move(dir)
                }
            }
        }
        if pressed.contains("a") { nav.press() }
        if pressed.contains("b") { nav.goBack() }
        if pressed.contains("y") { nav.alt() }
        guard nav.scope == "home" else { return }
        if pressed.contains("lb") { nav.homeFilter?(-1) }
        if pressed.contains("rb") { nav.homeFilter?(1) }
        if pressed.contains("lt") { nav.homeSort?(-1) }
        if pressed.contains("rt") { nav.homeSort?(1) }
        if pressed.contains("start"), model.heroGame != nil { model.resumeFromHero() }
    }

    #if DEBUG
    /// `-pad "down right a"`: presses as the UI would get them (tests).
    func debugPress(_ name: String) {
        guard !inGame else { return }
        drive(uiHeld.union([name]))
        drive(uiHeld.subtracting([name]))
    }
    #endif

    private func openMenu() {
        letGo()
        model.openMenu(paused: true)
    }

    private func send(_ want: Set<Int>) {
        for id in want.subtracting(sent) { session.setInput(id, true, source: "pad") }
        for id in sent.subtracting(want) { session.setInput(id, false, source: "pad") }
        sent = want
    }

    /// Release the console inputs and the speed holds.
    private func letGo() {
        send([])
        if fastForwardHeld { fastForwardHeld = false; session.holdFastForward(false) }
        if rewindHeld { rewindHeld = false; session.setRewinding(false) }
        chordTimer?.invalidate()
        chordTimer = nil
    }

    // MARK: rumble

    /// The cart's motor on every controller that has haptics.
    func setRumble(_ on: Bool) {
        for c in GCController.controllers() {
            let key = ObjectIdentifier(c)
            if on {
                if engines[key] == nil, let engine = c.haptics?.createEngine(withLocality: .default) {
                    engines[key] = (engine, nil)
                }
                guard var entry = engines[key] else { continue }
                entry.1 = Peripherals.startRumble(on: entry.0)
                engines[key] = entry
            } else if let entry = engines[key] {
                try? entry.1?.stop(atTime: CHHapticTimeImmediate)
                engines[key] = (entry.0, nil)
            }
        }
    }
}
