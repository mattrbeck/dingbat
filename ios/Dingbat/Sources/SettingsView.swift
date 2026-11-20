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

/// Settings (docs/dev/settings-design.md): a navigation stack of panes on a
/// phone, a sidebar beside the open pane from 700 pt wide. `initialSection`
/// opens straight to a pane.
struct SettingsView: View {
    var initialSection: String?
    @Environment(\.palette) private var palette
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var supporter = Supporter.shared
    @ObservedObject private var nav = SettingsNav.shared
    @State private var ready = false
    @State private var sheetFrom: String?

    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.width >= 700 { wide } else { phone }
            }
            .onAppear { nav.wide = geo.size.width >= 700 }
            .onChange(of: geo.size.width) { nav.wide = $0 >= 700 }
        }
        .background(palette.bg.ignoresSafeArea())
        .tint(palette.accent)
        .sheetToasts()
        .sheet(isPresented: $supporter.sheetUp) {
            SupporterView(onClose: { supporter.sheetUp = false })
                .environment(\.palette, settings.palette)
                .environment(\.padScope, AppModel.Sheet.settings(section: nil).id)
                .environment(\.padPane, "supporter")
                .iPadSheet(width: 560, height: 780)
        }
        .onChange(of: supporter.sheetUp) { up in
            if up {
                sheetFrom = PadNav.shared.focused
                PadNav.shared.scopeChanged()
            } else {
                PadNav.shared.refocus(sheetFrom)
            }
        }
        .onChange(of: supporter.jumpTo) { p in
            guard let p else { return }
            supporter.jumpTo = nil
            nav.open(p)
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            nav.path = []
            if let p = initialSection.flatMap(SettingsPane.init(link:)) { nav.open(p) }
            let scope = AppModel.Sheet.settings(section: nil).id
            PadNav.shared.back[scope] = {
                if Supporter.shared.sheetUp { Supporter.shared.sheetUp = false; return true }
                return SettingsNav.shared.pop()
            }
            PadNav.shared.shownPane[scope] = { SettingsNav.shared.shownPane }
        }
    }

    private var phone: some View {
        NavigationStack(path: $nav.path) {
            RootPane()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.large)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { CloseButton() } }
                .environment(\.padPane, "root")
                .navigationDestination(for: SettingsPane.self) { PaneScreen(pane: $0) }
        }
    }

    private var wide: some View {
        NavigationSplitView {
            RootPane(sidebar: true)
                .navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .topBarLeading) { CloseButton() } }
        } detail: {
            NavigationStack(path: $nav.path) {
                PaneScreen(pane: nav.selection ?? .appearance, closes: false)
                    .navigationDestination(for: SettingsPane.self) { PaneScreen(pane: $0, closes: false) }
            }
            .id(nav.selection)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct CloseButton: View {
    var body: some View {
        Button(action: SheetNav.close) {
            Image(systemName: "xmark")
        }
        .accessibilityLabel("Close")
        .padFocus("close", press: SheetNav.close)
    }
}

extension SettingsNav {
    /// The panes Settings' root lists (on a wide screen, the sidebar's).
    static let top: [SettingsPane] = [.appearance, .controls, .audio, .play, .gb, .gba, .ds, .drive, .general]
}

/// One pane under its title.
private struct PaneScreen: View {
    let pane: SettingsPane
    var closes = true

    var body: some View {
        PaneContent(pane: pane)
            .navigationTitle(pane.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if closes { ToolbarItem(placement: .topBarTrailing) { CloseButton() } }
            }
            .environment(\.padPane, "\(pane)")
    }
}

// MARK: - Root

private struct RootPane: View {
    var sidebar = false
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var supporter = Supporter.shared
    @ObservedObject private var drive = DriveSync.shared
    @ObservedObject private var nav = SettingsNav.shared
    @Environment(\.palette) private var palette

    var body: some View {
        let sections = [
            SSection(id: "banner", [.custom("banner", SupporterBanner(small: sidebar))]),
            SSection(id: "look", [
                row(.appearance, tile: Tile(color: 0x7A4FC4, glyph: .symbol("paintbrush.pointed.fill")), value: s.effectiveTheme.label),
                row(.controls, tile: Tile(color: 0x636079, glyph: .symbol("gamecontroller.fill"))),
                row(.audio, tile: Tile(color: 0xE0466B, glyph: .symbol("speaker.wave.2.fill"))),
            ]),
            SSection(id: "systems", [
                row(.play, tile: Tile(color: 0x2FA85A, glyph: .symbol("play.fill"))),
                row(.gb, tile: Tile(color: 0x2B8F8A, glyph: .gameBoy), value: s.effectivePaletteMode.label),
                row(.gba, tile: Tile(color: 0x4D5BD6, glyph: .gba),
                    value: FileManager.default.fileExists(atPath: RomLibrary.gbaBiosURL.path) ? nil : "No BIOS"),
            ] + (s.dsOn ? [row(.ds, tile: Tile(color: 0xD9822B, glyph: .ds), badge: .experimental)] : [])),
            SSection(id: "account", footer: AppBuild.label, [
                row(.drive, tile: Tile(color: 0x2F7FE0, glyph: .symbol("cloud.fill")), value: drive.linked ? "On" : "Off"),
                row(.general, tile: Tile(color: 0x636079, glyph: .symbol("gearshape.fill"))),
            ]),
        ]
        if sidebar {
            // Not List(selection:): its solid accent fill hides the controller's
            // ring and greys the label; the detail follows nav.selection anyway.
            List {
                ForEach(sections) { sec in
                    Section {
                        ForEach(sec.rows) { r in
                            if case .nav(let label, _, let tile, _, let badge, _, let to) = r.kind {
                                Button { nav.open(to) } label: {
                                    RowLine(label: label, tile: tile, badge: badge) { EmptyView() }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(nav.selection == to ? .isSelected : [])
                                .padFocus(r.id) { nav.open(to) }
                                .listRowBackground(nav.selection == to ? palette.accent.opacity(0.24) : palette.surface2)
                            } else if case .custom(let v) = r.kind {
                                v.listRowBackground(palette.surface2)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(palette.bg.ignoresSafeArea())
        } else {
            PaneList(sections: sections)
        }
    }

    private func row(_ p: SettingsPane, tile: Tile, value: String? = nil, badge: Badge? = nil) -> SRow {
        .nav(p.title, value: value, tile: tile, badge: badge, to: p)
    }
}

/// The top row: "Support dingbat", or "dingbat" with the Supporter pill.
private struct SupporterBanner: View {
    /// In the sidebar: room for one line each.
    var small = false
    @ObservedObject private var store = Supporter.shared
    @Environment(\.palette) private var palette

    var body: some View {
        Button { store.open() } label: {
            HStack(spacing: small ? 10 : 14) {
                Circle().fill(palette.bg).frame(width: small ? 44 : 56, height: small ? 44 : 56)
                    .overlay(Image("LogoCrown").interpolation(.none).resizable().scaledToFit().frame(width: small ? 36 : 46))
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.unlocked ? "dingbat" : "Support dingbat")
                        .font(.system(size: small ? 17 : 20, weight: .semibold)).foregroundColor(palette.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(store.unlocked ? sinceText : "Themes, icons, palettes and more")
                        .font(.system(size: small ? 13 : 14)).foregroundColor(palette.textDim)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(palette.textFaint)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padFocus("supporter:banner") { store.open() }
    }

    private var sinceText: String {
        guard let d = store.since else { return "Supporter" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return "Supporter since \(f.string(from: d))"
    }
}

// MARK: - Panes

/// Every pane's sections, read from the live settings.
private struct PaneContent: View {
    let pane: SettingsPane
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var supporter = Supporter.shared
    @ObservedObject private var session = GameSession.shared
    @ObservedObject private var nds = NdsState.shared
    @ObservedObject private var kb = Keyboard.shared
    @ObservedObject private var drive = DriveSync.shared
    @ObservedObject private var icons = AppIconManager.shared
    @Environment(\.palette) private var palette
    @State private var fileGen = 0

    private var unlocked: Bool { supporter.unlocked }

    var body: some View {
        switch pane {
        case .webhook: WebhookPane()
        case .acknowledgements: AcknowledgementsPane()
        default: PaneList(sections: sections)
        }
    }

    private var sections: [SSection] {
        switch pane {
        case .appearance: return appearance
        case .controls: return controls
        case .controller: return controller
        case .keyboard: return keyboard
        case .audio: return audio
        case .channels: return channels
        case .play: return play
        case .gb: return gameBoy
        case .gba: return gba
        case .ds: return ds
        case .drive: return driveSections
        case .general: return general
        case .appIcon: return appIcon
        case .webhook, .acknowledgements: return []
        }
    }

    /// A setting read at load: changed mid-game, it says when it applies.
    private func atNextLoad<T>(_ b: Binding<T>) -> Binding<T> {
        Binding(get: { b.wrappedValue }, set: { v in
            b.wrappedValue = v
            if session.game != nil { AppModel.shared.toast("Applies the next time a game is loaded") }
        })
    }

    private func index<T: Equatable>(_ all: [T], _ b: Binding<T>) -> Binding<Int> {
        Binding(get: { all.firstIndex(of: b.wrappedValue) ?? 0 }, set: { b.wrappedValue = all[$0] })
    }

    // MARK: Display & Appearance

    private var appearance: [SSection] {
        var theme: [SRow] = [.custom("gallery", ThemeGallery())]
        if unlocked {
            theme.append(.toggle("Separate light-mode theme", $s.lightThemeOn))
            if s.lightThemeOn {
                theme.append(.menu("Light-mode theme", ThemeName.allCases.map { .init($0.label) }, index(ThemeName.allCases, $s.lightTheme)))
            }
        }
        theme.append(.nav("App Icon", value: (unlocked ? icons.chosen : AppIconChoice.classic[0]).name,
                          image: (unlocked ? icons.chosen : AppIconChoice.classic[0]).preview,
                          locked: unlocked ? nil : .icons, to: .appIcon))
        let filters = Settings.Filter.allCases
        var screen: [SRow] = [
            .toggle("Color correction", $s.colorCorrect),
            .menu("Filter", filters.map { .init($0.label, locked: $0.supporterOnly && !unlocked ? .filters : nil) },
                  index(filters, Binding(get: { s.effectiveFilter }, set: { s.filter = $0 }))),
            .toggle("Integer scaling", $s.integerScale),
            .toggle("Reproduce motion blur", $s.lcdResponse),
            .toggle("Ambient glow", $s.ambientGlow),
        ]
        if PhoneCutout.hasSideColumn {
            let all = Settings.UprightPicture.allCases
            screen.append(.menu("Picture held upright", all.map { .init($0.label) }, index(all, $s.uprightPicture)))
        }
        return [SSection("Theme", theme), SSection("Game screen", screen)]
    }

    // MARK: Controls

    private var controls: [SSection] {
        var touch: [SRow] = [
            .toggle("Large controls", $s.largeControls),
            .segmented("Direction", ["D-pad", "Joystick"], index([.dpad, .joystick], $s.controlStyle)),
        ]
        if s.controlStyle == .joystick {
            touch.append(.segmented("Joystick", ["Fixed", "Floating"], index([.fixed, .floating], $s.joystickMode)))
        }
        if UIDevice.current.userInterfaceIdiom == .phone {
            touch.append(.segmented("Buttons in landscape", ["Outline", "Bold", "Solid"], index([.outline, .bold, .solid], $s.landscapeButtons)))
        }
        touch.append(.toggle("Hide with a controller", $s.hideTouchOnGamepad))
        var more: [SRow] = [.nav("Controller buttons", to: .controller)]
        if kb.connected { more.append(.nav("Keyboard", value: presetName(kb.preset), to: .keyboard)) }
        return [
            SSection("Touch", touch),
            SSection("Feedback", [
                .toggle("Rumble", $s.rumble),
                .toggle("Haptic feedback", $s.haptics),
                .toggle("Show inputs on screen", $s.inputDisplay),
            ]),
            SSection("Controller and keyboard", more),
        ]
    }

    private func presetName(_ p: Keyboard.Preset) -> String {
        p == .default ? "Default" : p == .homerow ? "Home-row" : "Custom"
    }

    private var controller: [SSection] {
        func keys(_ rows: [(String, String)]) -> [SRow] { rows.map { .info($0.0, $0.1, keycap: true) } }
        return [
            SSection("Game buttons", keys([("A", "A or Y"), ("B", "B or X"), ("Select / Start", "Options / Menu")]
                + (s.dsOn ? [("X / Y (DS games)", "X / Y")] : []) + [("L / R", "LB / RB"), ("D-pad", "D-pad or left stick")])),
            SSection("While playing", keys([("Fast-forward (hold)", "RT"), ("Rewind (hold)", "LT"), ("Menu", "R3 or Select+Start")])),
            SSection("In menus", keys([("Move / press", "D-pad / A"), ("Back", "B"), ("Game options", "Y"),
                                       ("Resume the game", "Start"), ("Filter / sort", "LB RB / LT RT")])),
        ]
    }

    private var keyboard: [SSection] {
        let presets: [Keyboard.Preset] = [.default, .homerow, .custom]
        let preset = Binding(get: { kb.preset }, set: { kb.setPreset($0) })
        let n = s.dsOn ? Keyboard.inputNames.count : 10
        let bindings: [SRow] = (0..<n).map { i in
            .custom("key:\(i)", KeyBindingRow(index: i))
        }
        let shortcuts: [(String, String)] = [
            ("Pause / Resume", "Space"), ("Fast-forward (hold)", "Tab"), ("2× speed", "Shift+Tab"), ("Slow motion", "Shift+`"),
            ("Rewind (hold)", "`"), ("Step one frame", "."), ("Mute", "M"), ("Show inputs on screen", "I"),
            ("Save state", "F5"), ("Load state", "F8"), ("Screenshot", "F9"), ("Menu", "Escape"),
        ] + (s.dsOn ? [("DS: next screen layout", "V"), ("DS: swap the screens", "B"), ("DS: turn the screens", "O"),
                       ("DS: close / open the lid", "N"), ("DS: blow (hold)", "H")] : [])
        return [
            SSection(id: "preset", [.segmented("Preset", ["Default", "Home-row", "Custom"], index(presets, preset))]),
            SSection("Game keys", bindings),
            SSection("Shortcuts", shortcuts.map { .info($0.0, $0.1, keycap: true) }),
        ]
    }

    // MARK: Audio

    private var audio: [SSection] {
        let silent = Binding(get: { s.playInSilent }, set: { s.playInSilent = $0; AudioOutput.shared.refreshSession() })
        let analog = Binding(get: { s.analogFilter }, set: { on in
            s.analogFilter = on
            AudioOutput.shared.setAnalogFilter(on && GameSession.shared.game?.isGBA == true)
        })
        let muted = s.channelMutes.nonzeroBitCount
        return [
            SSection("Playback", [.toggle("Pitch-correct fast-forward", $s.pitchCorrectFF), .toggle("Play in Silent Mode", silent)]),
            SSection("Game Boy Advance sound", [
                .toggle("Interpolation", $s.fifoInterp),
                .toggle("Analog filter", analog),
                .toggle("Enhanced music synthesis", $s.mp2kHle),
            ]),
            SSection(id: "channels", [.nav("Channels", value: muted == 0 ? "All on" : "\(muted) muted", to: .channels)]),
        ]
    }

    private var channels: [SSection] {
        func voice(_ name: String, _ bit: Int) -> SRow {
            .toggle(name, Binding(get: { (s.channelMutes >> bit) & 1 == 0 }, set: { on in
                s.channelMutes = on ? s.channelMutes & ~(1 << bit) : s.channelMutes | (1 << bit)
            }))
        }
        return [
            SSection("Tone", [voice("Square 1", 0), voice("Square 2", 1), voice("Wave", 2), voice("Noise", 3)]),
            SSection("GBA samples", [voice("Sample A", 4), voice("Sample B", 5)]),
            SSection(id: "all", [.button("Turn All Channels On", disabled: s.channelMutes == 0) { s.channelMutes = 0 }]),
        ]
    }

    // MARK: Play

    private var play: [SSection] {
        [
            SSection("Opening a game", [
                .check("Where you left off", selected: s.libraryOpen == .resume) { s.libraryOpen = .resume },
                .check("From the game’s save", selected: s.libraryOpen == .save) { s.libraryOpen = .save },
            ]),
            SSection(id: "rewind", [
                .toggle("Rewind", $s.rewind),
                .segmented("Run-ahead", ["Off", "1", "2", "3"], $s.runahead),
            ]),
        ]
    }

    // MARK: Game Boy

    private var gameBoy: [SSection] {
        let sgbActive = session.game != nil && dingbat_sgb_active() != 0
        var palette: [SRow] = [
            .check("Default", selected: s.effectivePaletteMode == .default, swatch: Settings.defaultShades, disabled: sgbActive) {
                s.gbPaletteMode = .default
            },
            .check("App theme", selected: s.effectivePaletteMode == .theme, swatch: s.effectiveTheme.gbPalette, disabled: sgbActive) {
                s.gbPaletteMode = .theme
            },
            .check("Custom", selected: s.effectivePaletteMode == .custom, swatch: s.gbPaletteCustom, disabled: sgbActive,
                   locked: unlocked ? nil : .palette) { s.gbPaletteMode = .custom },
        ]
        if s.effectivePaletteMode == .custom { palette.append(.custom("wells", ShadeWells())) }
        return [
            SSection("Palette", palette),
            SSection("Super Game Boy", [
                .toggle("Super Game Boy mode", atNextLoad($s.sgbEnable)),
                .toggle("Show border", $s.sgbBorder, disabled: !s.sgbEnable),
            ]),
            SSection("Boot ROM", [.file("GBC boot ROM", FileSlot(url: RomLibrary.gbcBootromURL))]),
        ]
    }

    // MARK: Game Boy Advance

    private var gba: [SSection] {
        _ = fileGen
        let hasBios = FileManager.default.fileExists(atPath: RomLibrary.gbaBiosURL.path)
        let mode = hasBios ? s.gbaBiosMode : 0
        func call(_ label: String, _ v: Int) -> SRow {
            .check(label, selected: mode == v, disabled: !hasBios) {
                s.gbaBiosMode = v
                if session.game != nil { AppModel.shared.toast("Applies the next time a game is loaded") }
            }
        }
        return [
            SSection("BIOS", [
                .file("GBA BIOS", FileSlot(url: RomLibrary.gbaBiosURL, changed: { fileGen += 1 })),
                .toggle("Play BIOS intro", hasBios ? atNextLoad($s.gbaRunBios) : .constant(false), disabled: !hasBios),
            ]),
            SSection("BIOS calls", [call("Built-in", 0), call("Your BIOS", 1), call("Your BIOS for startup only", 2)]),
        ]
    }

    // MARK: Nintendo DS

    private var ds: [SSection] {
        let layouts = NdsUtil.Arrangement.allCases
        let gaps = NdsUtil.Gap.allCases
        let turns = NdsUtil.rotations
        let gpus = NdsState.GpuChoice.allCases
        var screens: [SRow] = [
            .menu("Layout", layouts.map { .init($0.label) }, index(layouts, $nds.arrangement)),
            .toggle("Bottom screen first", $nds.swap),
            .menu("Gap", gaps.map { .init($0.label) }, index(gaps, $nds.gap)),
            .menu("Turn", turns.map { .init(NdsUtil.rotLabel($0)) }, index(turns, $nds.rot)),
        ]
        if UIDevice.current.userInterfaceIdiom == .phone { screens.append(.toggle("Hide the top bar while playing", $nds.barHide)) }
        func dump(_ k: NdsUtil.BiosKind) -> SRow {
            .file(k == .bios9 ? "ARM9 BIOS" : k == .bios7 ? "ARM7 BIOS" : "Firmware",
                  FileSlot(url: NdsState.biosURL(k), validate: { data in
                      guard !k.sizes.contains(data.count) else { return nil }
                      let want = k.sizes.map { "\($0 / 1024) KB" }.joined(separator: ", ")
                      return "That doesn't look like a DS \(k == .firmware ? "firmware" : "BIOS") dump — it should be \(want)."
                  }))
        }
        return [
            SSection("Screens", screens),
            SSection("3D graphics", [
                .segmented("Resolution", NdsState.hdScales.map { $0 == 1 ? "Native" : "\($0)×" }, index(NdsState.hdScales, $nds.hd)),
                .menu("Drawn by", gpus.map { .init($0.label) }, index(gpus, $nds.gpu)),
            ]),
            SSection("BIOS and firmware", NdsUtil.BiosKind.allCases.map(dump)),
        ]
    }

    // MARK: Google Drive

    private var driveSections: [SSection] {
        guard drive.linked else {
            return [SSection(id: "signin", [.custom("signin", DriveSignIn())])]
        }
        let n = drive.pendingCount
        let status = !drive.active ? "Reconnects when you next sync" : n == 0 ? "All changes synced" : "\(n) \(n == 1 ? "change" : "changes") waiting to go up"
        return [
            SSection(id: "account", [
                .custom("account", DriveAccount(email: drive.email ?? "Google Drive", status: status)),
                .button("Sync Now") { Task { @MainActor in await drive.runFullSync() } },
            ]),
            SSection(id: "signout", [
                .button("Sign Out") { drive.signOut() },
                .button("Sign Out Everywhere", destructive: true, confirm: "Sign out everywhere?",
                        message: "Your other devices sign out of Google Drive too.") {
                    Task { @MainActor in await drive.signOutEverywhere() }
                },
            ]),
        ]
    }

    // MARK: General

    private var general: [SSection] {
        let advanced: [SRow] = unlocked
            ? [.nav("Save webhook", value: s.saveWebhook.isEmpty ? "Off" : "On", to: .webhook),
               .toggle("DS support", $s.dsBeta, badge: .highlyExperimental)]
            : [.nav("Save webhook", locked: .advanced, to: .webhook),
               .toggle("DS support", .constant(false), badge: .highlyExperimental, locked: .advanced)]
        return [
            SSection("Advanced", advanced),
            SSection("About", [.custom("version", VersionRow()), .nav("Acknowledgements", to: .acknowledgements)]),
            SSection(id: "reset", [
                .button("Reset All Settings", destructive: true, confirm: "Reset all settings?",
                        message: "Every setting goes back to its default. Your games and saves are kept.") {
                    s.resetAll()
                    AudioOutput.shared.setAnalogFilter(s.analogFilter && GameSession.shared.game?.isGBA == true)
                },
            ]),
        ]
    }

    // MARK: App Icon

    private var appIcon: [SSection] {
        [
            SSection(id: "holidays", [.toggle("Holiday icons", $icons.holidaysOn)]),
            SSection("Classic", [.custom("classic", IconGrid(icons: AppIconChoice.classic))]),
            SSection("Holidays", [.custom("holidays", IconGrid(icons: AppIconChoice.holidays))]),
        ]
    }
}

// MARK: - Pane pieces

/// Twelve small previews of the app in each theme; a locked one opens the sheet.
private struct ThemeGallery: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var supporter = Supporter.shared
    @Environment(\.palette) private var palette
    @Environment(\.padScope) private var scope

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ThemeName.allCases) { t in
                        let locked = t.supporterOnly && !supporter.unlocked
                        let on = s.effectiveTheme == t || (!supporter.unlocked && t == .night)
                        Button { pick(t, locked) } label: {
                            VStack(spacing: 7) {
                                ThemeMini(theme: t, selected: on, locked: locked)
                                Text(t.label).font(.system(size: 12)).foregroundColor(on ? palette.text : palette.textDim).lineLimit(1).fixedSize()
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t.label + (locked ? ", Supporter theme" : ""))
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .padFocus("theme:" + t.rawValue) { pick(t, locked) }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 6)  // room for the focus ring
            }
            .onAppear { proxy.scrollTo(PadNav.key(scope, "theme:" + s.effectiveTheme.rawValue), anchor: .center) }
            .padScrollFollow(proxy)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
    }

    private func pick(_ t: ThemeName, _ locked: Bool) {
        if locked { Supporter.shared.open(.themes) } else { s.theme = t }
    }
}

/// The app in miniature, in one theme.
struct ThemeMini: View {
    let theme: ThemeName
    var selected = false
    var locked = false
    var width: CGFloat = 56
    @Environment(\.palette) private var palette

    var body: some View {
        let (bg, accent) = theme.swatch
        let shades = theme.gbPalette
        let light = theme.palette.isLight
        let h = width * 100 / 56
        VStack(spacing: width * 0.09) {
            RoundedRectangle(cornerRadius: 3).fill((light ? Color.black : Color.white).opacity(0.22))
                .frame(width: width * 0.55, height: width * 0.09).frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 0) { ForEach(0..<4, id: \.self) { Rectangle().fill(Color(hex: shades[$0])) } }
                .frame(height: h * 0.36).clipShape(RoundedRectangle(cornerRadius: 4))
            Spacer(minLength: 0)
            // The play screen's controls: a d-pad, and B low and A high.
            let u = width / 56
            HStack(alignment: .center) {
                ZStack {
                    RoundedRectangle(cornerRadius: 1.5 * u).frame(width: 5 * u, height: 15 * u)
                    RoundedRectangle(cornerRadius: 1.5 * u).frame(width: 15 * u, height: 5 * u)
                }
                .foregroundColor((light ? Color.black : Color.white).opacity(light ? 0.45 : 0.55))
                Spacer(minLength: 0)
                ZStack(alignment: .topLeading) {
                    Circle().fill(Color(hex: accent)).frame(width: 8 * u, height: 8 * u).offset(y: 5 * u)
                    Circle().fill(Color(hex: accent)).frame(width: 8 * u, height: 8 * u).offset(x: 9 * u)
                }
                .frame(width: 17 * u, height: 13 * u, alignment: .topLeading)
            }
            .padding(.horizontal, u)
        }
        .padding(width * 0.11)
        .frame(width: width, height: h)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: bg)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(selected ? palette.accent : Color.white.opacity(0.16), lineWidth: selected ? 2 : 1))
        .overlay(alignment: .bottomTrailing) {
            if locked || selected {
                ZStack {
                    Circle().fill(locked ? palette.surface3 : palette.accent)
                    Image(systemName: locked ? "lock.fill" : "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(locked ? palette.accent2 : palette.accentInk)
                }
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(palette.surface2, lineWidth: 2))
                .offset(x: 5, y: 5)
            }
        }
    }
}

/// Custom shades: four wells and Reset.
private struct ShadeWells: View {
    @ObservedObject private var s = Settings.shared
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<4, id: \.self) { i in
                ColorPicker("", selection: shade(i), supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel(i == 0 ? "Shade 1 (lightest)" : i == 3 ? "Shade 4 (darkest)" : "Shade \(i + 1)")
            }
            Spacer()
            Button("Reset") { s.gbPaletteCustom = Settings.defaultShades }
                .foregroundColor(palette.accent)
                .buttonStyle(.plain)
                .disabled(s.gbPaletteCustom == Settings.defaultShades)
                .padFocus("wells:reset") { s.gbPaletteCustom = Settings.defaultShades }
        }
        .padding(.vertical, 6)
    }

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

/// One game key: tap, then press its replacement.
private struct KeyBindingRow: View {
    let index: Int
    @ObservedObject private var kb = Keyboard.shared
    @Environment(\.palette) private var palette

    var body: some View {
        let on = kb.capturing == index
        Button { kb.capturing = on ? nil : index } label: {
            RowLine(label: Keyboard.inputNames[index]) {
                Text(on ? "Press a key" : Keyboard.name(kb.bindings[index]))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(on ? palette.accentInk : palette.text)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? palette.accent : palette.surface3))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Keyboard.inputNames[index] + ": " + Keyboard.name(kb.bindings[index]))
        .padFocus("key\(index)") { kb.capturing = on ? nil : index }
        .onDisappear { if kb.capturing == index { kb.capturing = nil } }
    }
}

private struct DriveSignIn: View {
    @Environment(\.palette) private var palette
    var body: some View {
        GoogleSignInButton()
            .padding(.vertical, 8)
    }
}

private struct DriveAccount: View {
    let email: String
    let status: String
    @Environment(\.palette) private var palette
    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(Color(hex: 0x2F7FE0)).frame(width: 44, height: 44)
                .overlay(Image(systemName: "cloud.fill").font(.system(size: 19, weight: .semibold)).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(email).font(.headline).foregroundColor(palette.text).lineLimit(1).truncationMode(.middle)
                Text(status).font(.subheadline).foregroundColor(palette.textDim)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Version; a tap copies the build.
private struct VersionRow: View {
    var body: some View {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        Button {
            UIPasteboard.general.string = AppBuild.label
            AppModel.shared.toast("Copied " + AppBuild.label)
        } label: {
            RowLine(label: "Version") { ValueText("\(v) (\(b))") }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Copies the build")
        .padFocus("version") {
            UIPasteboard.general.string = AppBuild.label
            AppModel.shared.toast("Copied " + AppBuild.label)
        }
    }
}

/// App Icon's grid of icons; the chosen one has a ring.
private struct IconGrid: View {
    let icons: [AppIconChoice]
    @ObservedObject private var manager = AppIconManager.shared
    @Environment(\.palette) private var palette

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 14) {
            ForEach(icons) { c in
                let on = manager.chosen == c
                Button { manager.choose(c) } label: {
                    VStack(spacing: 6) {
                        Image(c.preview).interpolation(.none).resizable()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(palette.accent, lineWidth: on ? 3 : 0).padding(-4))
                        Text(c.name).font(.system(size: 12)).foregroundColor(on ? palette.text : palette.textDim)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.name)
                .accessibilityAddTraits(on ? .isSelected : [])
                .padFocus("icon:" + c.id, radius: 15) { manager.choose(c) }
            }
        }
        .padding(.vertical, 12)
    }
}

/// General › Save webhook: the address saves are posted to.
private struct WebhookPane: View {
    @ObservedObject private var s = Settings.shared
    @State private var hook = Settings.shared.saveWebhook
    @State private var problem = ""
    @ObservedObject private var sent = SaveWebhook.Status.shared
    @Environment(\.palette) private var palette

    var body: some View {
        List {
            Section {
                TextField("", text: $hook, prompt: Text("https://example.com/saves").foregroundColor(palette.textFaint))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(commit)
                    .foregroundColor(palette.text)
                    .listRowBackground(palette.surface2)
            } footer: {
                let note = !problem.isEmpty ? problem : (!s.saveWebhook.isEmpty ? sent.text : "")
                if !note.isEmpty { Text(note).foregroundColor(palette.textFaint) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(palette.bg.ignoresSafeArea())
        .onDisappear(perform: commit)
    }

    /// "" or an absolute http(s) address.
    private func commit() {
        let t = hook.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            s.saveWebhook = ""
            problem = ""
            return
        }
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host != nil else {
            problem = "Not a web address: it must start with http:// or https://"
            return
        }
        problem = ""
        if s.saveWebhook != t { s.saveWebhook = t }
    }
}

/// THIRD_PARTY_NOTICES.md as native sections: each `##` a section, each
/// table row a component with its licence, each bullet an entry, the rest
/// paragraphs. Sections for builds this app is not (desktop only) are left out.
private struct AcknowledgementsPane: View {
    @Environment(\.palette) private var palette

    struct Item: Identifiable {
        let id = UUID()
        var title: String?
        var value: String?
        var body: String?
        var mono = false
    }
    struct Part: Identifiable {
        let id = UUID()
        var header: String?
        var items: [Item] = []
    }

    var body: some View {
        List {
            ForEach(Self.parts) { part in
                Section {
                    ForEach(part.items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            if item.title != nil || item.value != nil {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    if let t = item.title { Text(inline(t)).foregroundColor(palette.text) }
                                    Spacer(minLength: 8)
                                    if let v = item.value { Text(v).foregroundColor(palette.textFaint).multilineTextAlignment(.trailing) }
                                }
                            }
                            if let b = item.body {
                                Text(inline(b))
                                    .font(item.mono ? .system(size: 12, design: .monospaced) : .subheadline)
                                    .foregroundColor(item.title == nil ? palette.text : palette.textDim)
                            }
                        }
                        .padding(.vertical, 3)
                        .listRowBackground(palette.surface2)
                        .listRowSeparatorTint(palette.border)
                    }
                } header: {
                    if let h = part.header {
                        Text(h).font(.system(size: 13)).foregroundColor(palette.textFaint).textCase(.uppercase)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(palette.bg.ignoresSafeArea())
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static let parts: [Part] = {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let md = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var parts: [Part] = [Part()]
        var para: [String] = []
        var bullet: [String]?
        func flush() {
            if !para.isEmpty {
                let licence = parts[parts.count - 1].header?.lowercased().contains("licence text") == true
                parts[parts.count - 1].items.append(Item(body: para.joined(separator: " "), mono: licence))
                para = []
            }
            if let b = bullet {
                let text = b.joined(separator: " ")
                // "**Title** (`where`): body" → the title, then the rest.
                if text.hasPrefix("**"), let end = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex) {
                    let title = String(text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound])
                    var rest = String(text[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix(":") { rest.removeFirst() }
                    parts[parts.count - 1].items.append(Item(title: title, body: rest.trimmingCharacters(in: .whitespaces)))
                } else {
                    parts[parts.count - 1].items.append(Item(body: text))
                }
                bullet = nil
            }
        }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") { continue }
            if line.hasPrefix("## ") {
                flush()
                parts.append(Part(header: String(line.dropFirst(3))))
            } else if line.hasPrefix("|") {
                flush()
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard cells.count == 3, cells[0] != "Component", !cells[0].hasPrefix("---") else { continue }
                parts[parts.count - 1].items.append(Item(title: cells[0], value: cells[1], body: cells[2]))
            } else if line.hasPrefix("- ") {
                flush()
                bullet = [String(line.dropFirst(2))]
            } else if line.isEmpty {
                flush()
            } else if bullet != nil {
                bullet?.append(line)
            } else {
                para.append(line)
            }
        }
        flush()
        return parts.filter { !$0.items.isEmpty && $0.header?.contains("desktop build only") != true }
    }()
}
