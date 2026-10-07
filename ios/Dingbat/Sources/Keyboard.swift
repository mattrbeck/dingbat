import GameController
import SwiftUI

/// A hardware keyboard (web gameKeyHandler + shortcutKeyHandler): the ten
/// bound keys play the game, the web's shortcuts run the rest, and outside
/// the game the arrows, Return/Space and Escape drive the UI as the pad does
/// (PadNav). Bindings are the web's SDL keycodes, so the presets are the
/// same numbers; keys arrive as HID usages (GCKeyCode) and map across.
final class Keyboard: ObservableObject {
    static let shared = Keyboard()

    static let inputNames = ["Up", "Down", "Left", "Right", "A", "B", "Select", "Start", "L", "R"]
    static let presetDefault = [0x40000052, 0x40000051, 0x40000050, 0x4000004F,  // arrows
                                122, 120, 8, 13, 97, 115]                        // Z X Backspace Return A S
    static let presetHomeRow = [101, 100, 115, 102,                              // E D S F
                                107, 106, 108, 59, 119, 114]                     // K J L ; W R

    @Published private(set) var bindings: [Int]
    /// The binding waiting for its key (Settings), or nil.
    @Published var capturing: Int?
    @Published private(set) var connected = false

    private var held: [Int: Int] = [:]   // SDL key held -> input id sent
    private var ffHeld = false
    private var rewindHeld = false

    private init() {
        let stored = UserDefaults.standard.array(forKey: "keybindings") as? [Int]
        // Escape is never a binding: it would stop closing every sheet.
        bindings = stored?.count == 10 ? stored!.map { $0 == 27 ? -1 : $0 } : Self.presetDefault
    }

    func start() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] n in
            (n.object as? GCKeyboard).map { self?.attach($0) }
        }
        nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.connected = GCKeyboard.coalesced != nil
            self?.releaseAll()
        }
        if let k = GCKeyboard.coalesced { attach(k) }
    }

    private func attach(_ k: GCKeyboard) {
        connected = true
        k.keyboardInput?.keyChangedHandler = { [weak self] input, _, code, pressed in
            self?.key(code, pressed, shift: input.button(forKeyCode: .leftShift)?.isPressed == true
                        || input.button(forKeyCode: .rightShift)?.isPressed == true,
                      chord: [GCKeyCode.leftControl, .rightControl, .leftAlt, .rightAlt, .leftGUI, .rightGUI]
                        .contains { input.button(forKeyCode: $0)?.isPressed == true })
        }
    }

    // MARK: bindings

    enum Preset: String { case `default`, homerow, custom }

    var preset: Preset {
        bindings == Self.presetDefault ? .default : bindings == Self.presetHomeRow ? .homerow : .custom
    }

    func setPreset(_ p: Preset) {
        switch p {
        case .default: commit(Self.presetDefault)
        case .homerow: commit(Self.presetHomeRow)
        case .custom: break
        }
    }

    private func commit(_ b: [Int]) {
        bindings = b
        UserDefaults.standard.set(b, forKey: "keybindings")
    }

    /// A key to the binding being captured: it leaves any other input that
    /// had it. No auto-advance, so a stray key cannot rebind the next.
    private func bind(_ sdl: Int, to i: Int) {
        var b = bindings
        for j in b.indices where b[j] == sdl { b[j] = -1 }
        b[i] = sdl
        capturing = nil
        commit(b)
    }

    /// HID usage -> SDL keycode (letters, digits and printables as
    /// characters; everything else the scancode with bit 30, as SDL does).
    static func sdl(_ c: GCKeyCode) -> Int? {
        let u = Int(c.rawValue)
        switch u {
        case 0x04...0x1D: return 97 + u - 0x04
        case 0x1E...0x26: return 49 + u - 0x1E
        case 0x27: return 48
        case 0x28: return 13
        case 0x29: return 27
        case 0x2A: return 8
        case 0x2B: return 9
        case 0x2C: return 32
        case 0x2D: return 45
        case 0x2E: return 61
        case 0x2F: return 91
        case 0x30: return 93
        case 0x31: return 92
        case 0x33: return 59
        case 0x35: return 96
        case 0x36: return 44
        case 0x37: return 46
        case 0x38: return 47
        case 0x4C: return 127
        case 0x39, 0x3A...0x45, 0x4F...0x52, 0xE0...0xE7: return 0x4000_0000 | u
        default: return nil
        }
    }

    /// web sdlName.
    static func name(_ sdl: Int) -> String {
        switch sdl {
        case -1: return "—"
        case 0x40000052: return "↑"
        case 0x40000051: return "↓"
        case 0x40000050: return "←"
        case 0x4000004F: return "→"
        case 8: return "Backspace"
        case 9: return "Tab"
        case 13: return "Return"
        case 27: return "Escape"
        case 32: return "Space"
        case 127: return "Delete"
        case 48...57: return String(sdl - 48)
        case 97...122: return String(UnicodeScalar(UInt8(sdl - 32)))
        case 0x4000003A...0x40000045: return "F\(sdl - 0x40000039)"
        case 0x40000039: return "Caps Lock"
        case 0x400000E0, 0x400000E4: return "Ctrl"
        case 0x400000E1, 0x400000E5: return "Shift"
        case 0x400000E2, 0x400000E6: return "Option"
        case 0x400000E3, 0x400000E7: return "Cmd"
        default:
            if sdl > 32 && sdl < 127 { return String(UnicodeScalar(UInt8(sdl))) }
            return "?"
        }
    }

    // MARK: keys

    private var model: AppModel { .shared }
    private var session: GameSession { .shared }

    private var inGame: Bool {
        model.screen == .play && session.game != nil && !model.menuOpen && model.sheet == nil
    }

    private func key(_ code: GCKeyCode, _ down: Bool, shift: Bool, chord: Bool) {
        guard let sdl = Self.sdl(code) else { return }
        // Releases always go through, so nothing held can stick.
        if !down {
            if let id = held.removeValue(forKey: sdl) { session.setInput(id, false, source: "key") }
            if sdl == 9 && ffHeld { ffHeld = false; session.holdFastForward(false) }
            if sdl == 96 && rewindHeld { rewindHeld = false; session.setRewinding(false) }
            return
        }
        if let i = capturing {
            if sdl == 27 { capturing = nil } else { bind(sdl, to: i) }
            return
        }
        // Typing in a field is the field's.
        if UIResponder.textInputActive { return }
        if inGame {
            if let id = bindings.firstIndex(of: sdl) {  // game keys always win
                held[sdl] = id
                session.setInput(id, true, source: "key")
                return
            }
            if !chord { shortcut(sdl, shift: shift) }
            return
        }
        // Outside the game: as the pad.
        let nav = PadNav.shared
        switch sdl {
        case 0x40000052: nav.move(.up)
        case 0x40000051: nav.move(.down)
        case 0x40000050: nav.move(.left)
        case 0x4000004F: nav.move(.right)
        case 13, 32: nav.press()
        case 27: nav.goBack()
        default: break
        }
    }

    /// web shortcutKeyHandler, on a key going down in the game.
    private func shortcut(_ sdl: Int, shift: Bool) {
        let linked = NetLink.shared.linked
        let s = Settings.shared
        switch sdl {
        case 27:
            model.openMenu(paused: true)
        case 32:
            session.togglePause()
        case 9:
            if shift {
                session.toggleDouble()
            } else if !linked && !ffHeld {
                ffHeld = true
                session.holdFastForward(true)
            }
        case 96:
            guard !linked else { return }
            if shift {
                session.toggleSlowMotion()
            } else if s.rewind && !rewindHeld {
                rewindHeld = true
                session.setRewinding(true)
            }
        case 46:
            // First press pauses, then each steps one frame.
            guard !shift, !linked else { return }
            if session.paused { session.stepFrame() } else { session.togglePause() }
        case 109:
            if !shift { s.muted.toggle() }
        case 105:
            if !shift { s.inputDisplay.toggle() }
        case 0x4000003E:  // F5
            guard !shift, !linked else { return }
            if session.saveState(slot: 0) { model.toast("State saved") }
        case 0x40000041:  // F8
            guard !shift, !linked else { return }
            session.loadState(slot: 0)
        case 0x40000042:  // F9
            guard !shift, !linked else { return }
            Share.screenshot()
        default:
            break
        }
    }

    #if DEBUG
    /// `-keys "f5 escape"`: a tap of each, through the same path (tests).
    func debugTap(_ name: String) {
        let usage: Int
        switch name {
        case "return": usage = 0x28
        case "escape": usage = 0x29
        case "space": usage = 0x2C
        case "tab": usage = 0x2B
        case "f5": usage = 0x3E
        case "f8": usage = 0x41
        case "up": usage = 0x52
        case "down": usage = 0x51
        default:
            guard let c = name.unicodeScalars.first, name.count == 1, ("a"..."z").contains(c) else { return }
            usage = 0x04 + Int(c.value) - 97
        }
        let code = GCKeyCode(rawValue: CFIndex(usage))
        key(code, true, shift: false, chord: false)
        key(code, false, shift: false, chord: false)
    }
    #endif

    /// The game lost the keyboard (a sheet, the background): let go.
    func releaseAll() {
        for id in held.values { session.setInput(id, false, source: "key") }
        held = [:]
        if ffHeld { ffHeld = false; session.holdFastForward(false) }
        if rewindHeld { rewindHeld = false; session.setRewinding(false) }
    }
}

extension UIResponder {
    private static weak var found: UIResponder?

    /// A text field or view is taking keys.
    static var textInputActive: Bool {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.dingbatNoteFirstResponder), to: nil, from: nil, for: nil)
        return found is UITextInput
    }

    @objc private func dingbatNoteFirstResponder() { UIResponder.found = self }
}
