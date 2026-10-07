import SwiftUI

/// The build's identity (web version.txt): the commit a build phase stamps
/// into Info.plist (project.yml), else the marketing version.
enum AppBuild {
    static var commit: String { Bundle.main.infoDictionary?["DingbatCommit"] as? String ?? "" }
    static var label: String {
        let c = commit
        if !c.isEmpty && c != "unknown" { return "dingbat " + String(c.prefix(12)) }
        return "dingbat " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
    }
}
import UniformTypeIdentifiers

/// Settings › sections, in the web's order (web #settings-tabs).
enum SettingsSection: String, CaseIterable, Identifiable {
    case controls, gb, gba, video, audio, general

    var id: String { rawValue }

    var name: String {
        switch self {
        case .controls: return "Controls"
        case .gb: return "Game Boy"
        case .gba: return "GBA"
        case .video: return "Video"
        case .audio: return "Audio"
        case .general: return "General"
        }
    }

    /// The row's second line (web .settings-tab-desc, minus what this app
    /// has no row for: key bindings, Google Drive, updates).
    var desc: String {
        switch self {
        case .controls: return "Touch buttons, joystick, controller"
        case .gb: return "Palette, Super Game Boy, boot ROM"
        case .gba: return "BIOS file, BIOS calls, intro"
        case .video: return "Color, filters, LCD grid, glow"
        case .audio: return "Quality, filtering, fast-forward"
        case .general: return "Theme, rewind, run-ahead"
        }
    }

    static let storageKey = "settings-section"
}

/// Settings (web #settings-modal). One tree, two layouts as on the web: a
/// rail of sections beside the open one when the sheet is wide, and on a
/// phone a list screen that pushes each section (with the up/down stepper).
/// `initialSection` opens straight to one; the last one is remembered.
struct SettingsView: View {
    var initialSection: String?
    @Environment(\.palette) private var palette
    @State private var current: SettingsSection = .controls
    @State private var pushed = false
    @State private var ready = false
    @State private var wideLayout = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.width >= 600 { rail } else { phone }
            }
            .onAppear { wideLayout = geo.size.width >= 600 }
            .onChange(of: geo.size.width) { wideLayout = $0 >= 600 }
        }
        .foregroundColor(palette.text)
        .background(palette.surface1.ignoresSafeArea())
        .sheetToasts()
        .onAppear {
            guard !ready else { return }
            ready = true
            let stored = UserDefaults.standard.string(forKey: SettingsSection.storageKey)
            if let s = initialSection.flatMap(SettingsSection.init(rawValue:)) {
                current = s
                pushed = true
            } else {
                current = stored.flatMap(SettingsSection.init(rawValue:)) ?? .controls
            }
        }
        .onChange(of: current) { s in UserDefaults.standard.set(s.rawValue, forKey: SettingsSection.storageKey) }
        .onAppear {
            // B in a pushed section goes back to the list first.
            PadNav.shared.back[AppModel.Sheet.settings(section: nil).id] = {
                guard pushed && !wideLayout else { return false }
                withAnimation(.easeOut(duration: 0.22)) { pushed = false }
                return true
            }
        }
    }

    // MARK: wide: rail + content

    private var rail: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Settings", onClose: nil)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(SettingsSection.allCases) { s in
                            sectionRow(s, selected: s == current, chevron: false) { current = s }
                        }
                        versionText.padding(.vertical, 16)
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(width: 260)
            .background(palette.bg.opacity(0.35).ignoresSafeArea())
            Rectangle().fill(palette.border).frame(width: 1).ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: current.name, onClose: SheetNav.close)
                ScrollViewReader { proxy in
                    ScrollView { pane(current) }
                        .padScrollFollow(proxy)
                }
                .id(current)
            }
        }
    }

    // MARK: narrow: list, pushed detail

    private var phone: some View {
        ZStack {
            if !pushed {
                VStack(spacing: 0) {
                    SheetHeader(title: "Settings", onClose: SheetNav.close)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(SettingsSection.allCases) { s in
                                sectionRow(s, selected: false) {
                                    current = s
                                    withAnimation(.easeOut(duration: 0.22)) { pushed = true }
                                }
                                if s != .general { Rectangle().fill(palette.border).frame(height: 1).padding(.leading, 16) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 11).fill(palette.surface2))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.border, lineWidth: 1))
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    }
                    versionText.padding(.vertical, 12)
                }
                .transition(.move(edge: .leading))
            } else {
                VStack(spacing: 0) {
                    SheetHeader(title: current.name, onClose: SheetNav.close) {
                        Button {
                            withAnimation(.easeOut(duration: 0.22)) { pushed = false }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(palette.text)
                                .frame(width: 32, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, -12)
                        .accessibilityLabel("Back to all settings")
                    } trailing: {
                        stepper
                    }
                    ScrollViewReader { proxy in
                        ScrollView { pane(current) }
                            .padScrollFollow(proxy)
                    }
                    .id(current)
                }
                .transition(.move(edge: .trailing))
                .gesture(DragGesture(minimumDistance: 24).onEnded { v in
                    // An edge swipe goes back, as a pushed screen does.
                    if v.startLocation.x < 40 && v.translation.width > 80 {
                        withAnimation(.easeOut(duration: 0.22)) { pushed = false }
                    }
                })
            }
        }
    }

    /// Previous / next section (web .settings-stepper).
    private var stepper: some View {
        let all = SettingsSection.allCases
        let i = all.firstIndex(of: current) ?? 0
        return HStack(spacing: 0) {
            stepButton("chevron.up", "Previous section", enabled: i > 0) { current = all[i - 1] }
            stepButton("chevron.down", "Next section", enabled: i < all.count - 1) { current = all[i + 1] }
        }
    }

    private func stepButton(_ icon: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(enabled ? palette.textDim : palette.textFaint.opacity(0.4))
                .frame(width: 32, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func sectionRow(_ s: SettingsSection, selected: Bool, chevron: Bool = true,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundColor(selected ? palette.accent : palette.text)
                    Text(s.desc)
                        .font(.system(size: 12))
                        .foregroundColor(palette.textFaint)
                        .lineLimit(chevron ? 1 : 2)
                }
                Spacer(minLength: 4)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(palette.textFaint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? palette.accent.opacity(0.10) : .clear))
            .padFocus("section:" + s.rawValue, press: action)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// web #settings-version: the build's commit; a tap copies it.
    private var versionText: some View {
        let text = AppBuild.label
        return Button {
            UIPasteboard.general.string = text
            AppModel.shared.toast("Copied " + text)
        } label: {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(palette.textFaint)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Copies the build")
    }

    @ViewBuilder
    private func pane(_ s: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch s {
            case .controls: ControlsPane()
            case .gb: GameBoyPane()
            case .gba: GbaPane()
            case .video: VideoPane()
            case .audio: AudioPane()
            case .general: GeneralPane()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 28)
    }
}

// MARK: - Controls

private struct ControlsPane: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var kb = Keyboard.shared

    var body: some View {
        SheetToggleRow(label: "Large on-screen controls",
                       sub: "A bigger d-pad for touch — best for large fingers", isOn: $s.largeControls)
        if UIDevice.current.userInterfaceIdiom == .phone {
            SheetFlowRow(label: "Buttons in landscape", sub: "Bold shows up on any picture") {
                SheetChipPicker(selection: $s.landscapeButtons,
                                options: [(.outline, "Outline"), (.bold, "Bold"), (.solid, "Solid")])
            }
        }
        SheetToggleRow(label: "Rumble", sub: "Buzz and shake when a game uses its rumble motor", isOn: $s.rumble)
        SheetToggleRow(label: "Haptic feedback",
                       sub: "A light tap under your thumb for each on-screen button press", isOn: $s.haptics)
        SheetFlowRow(label: "Touch direction input", sub: "D-pad buttons or an analog-style joystick") {
            SheetChipPicker(selection: $s.controlStyle, options: [(.dpad, "D-pad"), (.joystick, "Joystick")])
        }
        if s.controlStyle == .joystick {
            SheetFlowRow(label: "Joystick behavior", sub: "Fixed stays put; floating follows your thumb") {
                SheetChipPicker(selection: $s.joystickMode, options: [(.fixed, "Fixed"), (.floating, "Floating")])
            }
        }
        SheetToggleRow(label: "Hide touch controls with a controller",
                       sub: "Hide the on-screen buttons while a game controller is connected",
                       isOn: $s.hideTouchOnGamepad)
        SheetToggleRow(label: "Show inputs on screen",
                       sub: "Light up a small controller over the game as you press buttons — for streams, or for watching your own inputs.",
                       isOn: $s.inputDisplay)
        SheetFlowRow(label: "Opening a game from the library",
                     sub: "Resume goes back to the moment you left. From save starts from the game’s own save, and offers the moment after.") {
            SheetChipPicker(selection: $s.libraryOpen, options: [(.resume, "Resume"), (.save, "From save")])
        }
        // web #kb-section, which touch devices hide: here, while a
        // keyboard is connected.
        if kb.connected { KeyboardBlock() }
        SheetSubhead(text: "Controller")
        ShortcutList(rows: [
            ("A", "A or Y"),
            ("B", "B or X"),
            ("Select / Start", "Options / Menu"),
            ("L / R", "LB / RB"),
            ("D-pad", "D-pad or left stick"),
            ("Fast forward (hold)", "RT"),
            ("Rewind (hold)", "LT"),
            ("Menu, paused", "R3 / hold Select+Start"),
            ("Move / press", "D-pad / A"),
            ("Back / close", "B"),
            ("Library: game options", "Y"),
            ("Library: resume the game", "Start"),
            ("Library: filter / sort", "LB RB / LT RT"),
        ])
    }
}

/// web #kb-section: the preset, the ten bindings (tap one, then press its
/// key), and the shortcuts.
private struct KeyboardBlock: View {
    @ObservedObject private var kb = Keyboard.shared
    @Environment(\.palette) private var palette

    var body: some View {
        SheetSubhead(text: "Keyboard")
        SheetRow(label: "Preset") {
            SheetSelect(selection: Binding(get: { kb.preset }, set: { kb.setPreset($0) }),
                        options: [(.default, "Default"), (.homerow, "Home-row"), (.custom, "Custom")],
                        accessibilityLabel: "Keyboard preset")
        }
        SheetHint("Tap a key, then press its replacement. Saved automatically.")
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], alignment: .leading, spacing: 8) {
            ForEach(0..<10, id: \.self) { i in
                HStack(spacing: 10) {
                    let on = kb.capturing == i
                    Button { kb.capturing = on ? nil : i } label: {
                        Text(on ? "Press a key" : Keyboard.name(kb.bindings[i]))
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(on ? palette.accentInk : palette.text)
                            .frame(minWidth: 84)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? palette.accent : palette.surface2))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padFocus("key\(i)") { kb.capturing = on ? nil : i }
                    .accessibilityLabel(Keyboard.inputNames[i] + ": " + Keyboard.name(kb.bindings[i]))
                    Text(Keyboard.inputNames[i])
                        .font(.system(size: 13.5))
                        .foregroundColor(palette.textDim)
                }
            }
        }
        .padding(.bottom, 16)
        .onDisappear { kb.capturing = nil }
        SheetSubhead(text: "Shortcuts")
        ShortcutList(rows: [
            ("Pause / Resume", "Space"),
            ("Fast forward (hold)", "Tab"),
            ("2× speed", "Shift+Tab"),
            ("Slow motion", "Shift+`"),
            ("Rewind (hold)", "`"),
            ("Pause & step one frame", "."),
            ("Mute", "M"),
            ("Show inputs on screen", "I"),
            ("Save state", "F5"),
            ("Load state", "F8"),
            ("Screenshot", "F9"),
            ("Menu, paused", "Escape"),
        ])
        SheetHint("If a game key and a shortcut share a key, the game wins.")
    }
}

/// web .kb-shortcut rows: an action and its button.
private struct ShortcutList: View {
    let rows: [(String, String)]
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0)
                        .font(.system(size: 13.5))
                        .foregroundColor(palette.textDim)
                    Spacer(minLength: 8)
                    Text(r.1)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(palette.text)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(palette.surface2))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.border2, lineWidth: 1))
                }
            }
        }
        .padding(.bottom, 12)
    }
}

// MARK: - Game Boy

private struct GameBoyPane: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var session = GameSession.shared
    @Environment(\.palette) private var palette

    /// SGB colour in the running game: the shader has no shades to replace.
    private var sgbActive: Bool { session.game != nil && dingbat_sgb_active() != 0 }

    var body: some View {
        SheetSubhead(text: "Game Boy screen", rule: false)
        Group {
            SheetFlowRow(label: "Palette",
                         sub: "The four colors black-and-white games are drawn in. Color games are never affected.") {
                SheetSelect(selection: $s.gbPaletteMode,
                            options: [(.default, "Game Boy default"), (.theme, "Match app theme"), (.custom, "Custom…")],
                            accessibilityLabel: "Game Boy palette")
            }
            if sgbActive {
                SheetHint("Super Game Boy games bring their own colors, so there are no shades to replace. Turn it off below to use a palette.")
            }
            HStack(spacing: 10) {
                Text("In use").font(.system(size: 12.5)).foregroundColor(palette.textDim).frame(width: 46, alignment: .leading)
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { i in
                        Rectangle().fill(Color(hex: (s.dmgPalette ?? Settings.hardwareShades)[i]))
                    }
                }
                .frame(height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border2, lineWidth: 1))
                .accessibilityHidden(true)
                PadButton("Reset") {
                    s.gbPaletteMode = .default
                    s.gbPaletteCustom = Settings.hardwareShades
                }
                .buttonStyle(SheetButtonStyle())
                .accessibilityLabel("Reset the Game Boy palette")
            }
            .padding(.bottom, 14)
            if s.gbPaletteMode == .custom {
                HStack(spacing: 10) {
                    Text("Pick").font(.system(size: 12.5)).foregroundColor(palette.textDim).frame(width: 46, alignment: .leading)
                    ForEach(0..<4, id: \.self) { i in
                        ColorPicker("", selection: shade(i), supportsOpacity: false)
                            .labelsHidden()
                            .accessibilityLabel(i == 0 ? "Shade 1 (lightest)" : i == 3 ? "Shade 4 (darkest)" : "Shade \(i + 1)")
                    }
                    Spacer()
                }
                .padding(.bottom, 14)
            }
        }
        .disabled(sgbActive)
        SheetSubhead(text: "Super Game Boy")
        SheetToggleRow(label: "Super Game Boy mode",
                       sub: "Adds color, and a border, to black-and-white games that were made for the Super Game Boy adapter. Other games are unaffected.",
                       isOn: Binding(get: { s.sgbEnable }, set: { on in
                           s.sgbEnable = on
                           if session.game != nil {
                               AppModel.shared.toast("Super Game Boy mode applies the next time a game is loaded")
                           }
                       }))
        SheetToggleRow(label: "Show border",
                       sub: "A border makes the picture wider, so the screen changes shape when one appears.",
                       isOn: $s.sgbBorder)
            .disabled(!s.sgbEnable)
        SheetSubhead(text: "Boot ROM")
        BiosFileRow(label: "GBC Bootrom", url: RomLibrary.gbcBootromURL)
        SheetHint("With a boot ROM set, Game Boy games play the startup animation first.")
    }

    /// A ColorPicker binding onto one of the four custom shades (0xRRGGBB).
    private func shade(_ i: Int) -> Binding<Color> {
        Binding(
            get: { Color(hex: s.gbPaletteCustom[i]) },
            set: { c in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                guard UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
                func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
                var p = s.gbPaletteCustom
                p[i] = byte(r) << 16 | byte(g) << 8 | byte(b)
                if p != s.gbPaletteCustom { s.gbPaletteCustom = p }
            })
    }
}

/// A BIOS / boot ROM file: its status, Choose (copied into the app) and
/// Remove (web .modal-row with #pick-*, #remove-*).
private struct BiosFileRow: View {
    let label: String
    let url: URL
    var onChange: () -> Void = {}
    @Environment(\.palette) private var palette
    @State private var picking = false
    @State private var gen = 0
    @State private var failed: String?

    private var size: Int? {
        _ = gen
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 14.5, weight: .medium)).fixedSize()
            Text(size.map { RomEntry.formatBytes($0) } ?? "Not set")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(palette.textFaint)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            PadButton("Choose") { picking = true }.buttonStyle(SheetButtonStyle())
            PadButton("Remove") {
                try? FileManager.default.removeItem(at: url)
                gen += 1
                onChange()
            }
            .buttonStyle(SheetButtonStyle(kind: .ghost))
            .disabled(size == nil)
        }
        .padding(.bottom, 14)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
            guard case .success(let src) = result else { return }
            guard let data = SheetFiles.read(src), !data.isEmpty else {
                failed = "Couldn't read that file."
                return
            }
            do {
                try RomLibrary.ensureDir(url.deletingLastPathComponent())
                try data.write(to: url, options: .atomic)
            } catch {
                failed = "Couldn't keep that file: \(error.localizedDescription)"
            }
            gen += 1
            onChange()
        }
        .alert(failed ?? "", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

// MARK: - GBA

private struct GbaPane: View {
    @ObservedObject private var s = Settings.shared
    @State private var gen = 0

    private var hasBios: Bool {
        _ = gen
        return FileManager.default.fileExists(atPath: RomLibrary.gbaBiosURL.path)
    }

    var body: some View {
        SheetSubhead(text: "BIOS", rule: false)
        BiosFileRow(label: "GBA BIOS", url: RomLibrary.gbaBiosURL) { gen += 1 }
        SheetToggleRow(label: "Play BIOS intro",
                       sub: "Play the GBA startup animation first. Needs a BIOS file",
                       isOn: $s.gbaRunBios)
            .disabled(!hasBios)
        SheetSubhead(text: "BIOS calls (SWI)")
        VStack(spacing: 2) {
            radio(0, "HLE", "No BIOS file needed")
            radio(1, "Real BIOS", "The most faithful. Needs a BIOS file")
            radio(2, "Real BIOS boot, HLE calls", "Real startup, software after that")
        }
        .disabled(!hasBios)
        .padding(.bottom, 12)
        SheetHint("Changes apply the next time a game is loaded.")
    }

    private func radio(_ v: Int, _ label: String, _ sub: String) -> some View {
        RadioRow(label: label, sub: sub, selected: s.gbaBiosMode == v) { s.gbaBiosMode = v }
    }
}

private struct RadioRow: View {
    let label: String
    let sub: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().stroke(selected ? palette.accent : palette.border2, lineWidth: 1.5)
                    if selected { Circle().fill(palette.accent).padding(4) }
                }
                .frame(width: 18, height: 18)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 14.5, weight: .medium)).foregroundColor(palette.text)
                    Text(sub).font(.system(size: 12)).foregroundColor(palette.textFaint)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Video

private struct VideoPane: View {
    @ObservedObject private var s = Settings.shared

    var body: some View {
        SheetToggleRow(label: "Color correction", sub: "Match the colors the original screen produced",
                       isOn: $s.colorCorrect)
        SheetFlowRow(label: "Filter",
                     sub: "Smooth the pixel art, or draw the screen's own grid and subpixel structure") {
            SheetSelect(selection: $s.filter, options: Settings.Filter.allCases.map { ($0, $0.label) },
                        accessibilityLabel: "Filter")
        }
        SheetToggleRow(label: "Integer scaling", sub: "Keep every pixel exactly the same size", isOn: $s.integerScale)
        SheetToggleRow(label: "LCD response",
                       sub: "Colors settle slowly, the way the real screen did, so flickering sprites look see-through instead of blinking",
                       isOn: $s.lcdResponse)
        SheetToggleRow(label: "Ambient glow", sub: "Fill the background with a soft glow of the screen's colors",
                       isOn: $s.ambientGlow)
    }
}

// MARK: - Audio

private struct AudioPane: View {
    @ObservedObject private var s = Settings.shared
    @Environment(\.palette) private var palette
    @State private var channelsOpen = Settings.shared.channelMutes != 0

    var body: some View {
        SheetToggleRow(label: "Audio interpolation",
                       sub: "Smooths GBA music between hardware samples for cleaner treble. Turn off for the exact sound of a real GBA's headphone jack, grit included.",
                       isOn: $s.fifoInterp)
        SheetToggleRow(label: "Enhanced music synthesis",
                       sub: "Experimental. Re-creates supported games' music engines at higher quality than the hardware could mix. Changes the sound's character; engages itself only where it works.",
                       isOn: $s.mp2kHle)
        SheetToggleRow(label: "Pitch-correct fast-forward",
                       sub: "Keep the pitch normal at 2× speed instead of everything sounding like chipmunks. Uses a little extra CPU, only while fast-forwarding.",
                       isOn: $s.pitchCorrectFF)
        SheetToggleRow(label: "Analog filter",
                       sub: "Soften the treble the way the GBA's own output filter and speaker did. Pair with interpolation off for the closest real-hardware sound. GBA games only.",
                       isOn: Binding(get: { s.analogFilter }, set: { on in
                           s.analogFilter = on
                           AudioOutput.shared.setAnalogFilter(on && GameSession.shared.game?.isGBA == true)
                       }))
        SheetToggleRow(label: "Play in Silent Mode",
                       sub: "Pauses audio from other apps while a game is playing.",
                       isOn: Binding(get: { s.playInSilent }, set: { on in
                           s.playInSilent = on
                           AudioOutput.shared.refreshSession()
                       }))
        SheetDisclosure(title: "Channels", open: $channelsOpen)
        if channelsOpen { channels }
    }

    /// Per-channel mutes (bit i mutes channel i), held across game loads,
    /// never saved.
    private var channels: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mute parts of the sound to hear the rest on its own. Stays until you turn it back on or restart the app.")
                .font(.system(size: 12.5))
                .foregroundColor(palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            group("Tone channels",
                  "The square, wave and noise voices every Game Boy and GBA game uses (PSG)",
                  bits: 0b001111, chips: [(0, "Square 1"), (1, "Square 2"), (2, "Wave"), (3, "Noise")])
            group("Sample channels",
                  "Recorded sound and most music in GBA games (Direct Sound); Game Boy games have none",
                  bits: 0b110000, chips: [(4, "Sample A"), (5, "Sample B")])
            if s.channelMutes != 0 {
                let n = s.channelMutes.nonzeroBitCount
                HStack {
                    Text(n == 1 ? "1 channel muted" : "\(n) channels muted")
                        .font(.system(size: 12.5))
                        .foregroundColor(palette.textDim)
                    Spacer()
                    PadButton("All channels on") { s.channelMutes = 0 }.buttonStyle(SheetButtonStyle())
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func group(_ title: String, _ sub: String, bits: Int, chips: [(Int, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                SheetLabel(label: title, sub: sub)
                Button((s.channelMutes & bits) == bits ? "Turn on" : "Mute all") {
                    s.channelMutes = (s.channelMutes & bits) == bits ? s.channelMutes & ~bits : s.channelMutes | bits
                }
                .buttonStyle(SheetButtonStyle(kind: .ghost))
                .fixedSize()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ForEach(chips, id: \.0) { c in
                    let playing = (s.channelMutes >> c.0) & 1 == 0
                    Button {
                        s.channelMutes ^= 1 << c.0
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: playing ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 12))
                            Text(c.1).font(.system(size: 12.5, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(playing ? palette.text : palette.textFaint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(playing ? palette.accent.opacity(0.07) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(playing ? palette.accent.opacity(0.45) : palette.border, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.1)
                    .accessibilityValue(playing ? "Playing" : "Muted")
                }
            }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var s = Settings.shared
    @Environment(\.palette) private var palette
    @State private var advancedOpen = false
    @State private var hook = Settings.shared.saveWebhook
    @State private var hookStatus = ""

    var body: some View {
        SheetSubhead(text: "App theme", rule: false)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
            ForEach(ThemeName.allCases) { t in
                SheetChip(label: t.label, selected: s.theme == t, fill: true, action: { s.theme = t }) {
                    ZStack(alignment: .bottomTrailing) {
                        Circle().fill(Color(hex: t.swatch.0))
                            .overlay(Circle().stroke(palette.border2, lineWidth: 1))
                        Circle().fill(Color(hex: t.swatch.1)).frame(width: 8, height: 8).padding(3)
                    }
                    .frame(width: 22, height: 22)
                }
            }
        }
        .padding(.bottom, 18)
        SheetSubhead(text: "Google Drive")
        DriveSettingsBlock()
            .padding(.bottom, 18)
        SheetSubhead(text: "Emulation")
        SheetToggleRow(label: "Rewind",
                       sub: "Hold the rewind button to jump back, or double-tap it for a timeline you can scrub. Costs a few percent of speed; turning it off hides the rewind button.",
                       isOn: $s.rewind)
        SheetFlowRow(label: "Run-ahead",
                     sub: "Cuts the delay between pressing a button and seeing it happen, by guessing the next frame. Costs extra CPU; ignored at 2× speed") {
            SheetSelect(selection: $s.runahead,
                        options: [(0, "Off"), (1, "1 frame"), (2, "2 frames"), (3, "3 frames")],
                        accessibilityLabel: "Run-ahead frames")
        }
        SheetDisclosure(title: "Advanced", open: $advancedOpen)
        if advancedOpen {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save webhook").font(.system(size: 14.5, weight: .medium))
                Text("Every time a game writes its save, also send the save file to this address as an HTTP POST (form field “save”). Leave empty to turn off.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("", text: $hook, prompt: Text("https://example.com/saves").foregroundColor(palette.textFaint))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(commitHook)
                    .font(.system(size: 14))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border2, lineWidth: 1))
                if !hookStatus.isEmpty {
                    Text(hookStatus).font(.system(size: 12)).foregroundColor(palette.textDim)
                }
            }
            .padding(.bottom, 18)
            .onDisappear(perform: commitHook)
        }
        Rectangle().fill(palette.border).frame(height: 1).padding(.bottom, 14)
        SheetFlowRow(label: "Reset all settings",
                     sub: "Put every setting back to its default. Your games and saves are kept.") {
            SheetConfirmButton(label: "Reset all settings", confirmLabel: "Confirm reset?") {
                s.resetAll()
                hook = s.saveWebhook
                hookStatus = ""
                AudioOutput.shared.setAnalogFilter(s.analogFilter && GameSession.shared.game?.isGBA == true)
            }
        }
    }

    /// web: "" or an absolute http(s) address.
    private func commitHook() {
        let t = hook.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            s.saveWebhook = ""
            hookStatus = ""
            return
        }
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host != nil else {
            hookStatus = "Not a web address — it must start with http:// or https://"
            return
        }
        if s.saveWebhook != t { s.saveWebhook = t }
        hookStatus = "Saves will be sent here"
    }
}
