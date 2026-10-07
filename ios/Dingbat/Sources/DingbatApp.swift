import SwiftUI

@main
struct DingbatApp: App {
    @StateObject private var model = AppModel.shared
    @StateObject private var settings = Settings.shared
    @StateObject private var session = GameSession.shared
    @StateObject private var library = RomLibrary.shared

    init() {
        dingbat_init()
        Settings.shared.apply()
        RomLibrary.shared.installBundledDemo()
        Peripherals.shared.install()
        Task { @MainActor in await DriveSync.shared.resumeOnBoot() }
    }

    /// Dev hook: `simctl launch booted com.mattrb.dingbat -autoplay [name]`
    /// jumps straight into the named (or first) library ROM, so headless
    /// tooling can exercise the play screen without synthesizing taps.
    ///
    /// More hooks for screenshots, applied in order after it:
    ///   -landscape            rotate to landscape
    ///   -theme <name>         app theme (saved, as a pick in Settings is)
    ///   -home                 Main Menu (the paused hero)
    ///   -menu                 open the in-game menu
    ///   -sheet <id>           open a sheet: settings[:section], states,
    ///                         saves, rewind, cheats, prints, report,
    ///                         tile (first game's menu), rename
    private func autoplay() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count,
                  !args[i + 1].hasPrefix("-") else { return nil }
            return args[i + 1]
        }
        let model = AppModel.shared
        let entries = RomLibrary.shared.entries
        if args.contains("-autoplay") {
            let name = value("-autoplay")
            // A game a first Drive pull is bringing is waited for (10 s).
            // `-resume` opens it as the hero's Resume does.
            func attempt(_ left: Int) {
                let all = RomLibrary.shared.entries
                if let e = all.first(where: { $0.name == name || $0.fileName == name }) ?? (name == nil ? all.first : nil) {
                    model.launch(e, resume: args.contains("-resume"))
                    // `-home-after N`: Main Menu N seconds into the game
                    // (its session is taken), counted from the game opening
                    // (a Drive-only game downloads first).
                    if let h = value("-home-after").flatMap(Double.init) {
                        func whenRunning(_ tries: Int) {
                            if model.screen == .play && model.session.game != nil {
                                DispatchQueue.main.asyncAfter(deadline: .now() + h) { model.showMainMenu() }
                            } else if tries > 0 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { whenRunning(tries - 1) }
                            }
                        }
                        whenRunning(120)
                    }
                    // `-clip-after N`: Clip that! of everything so far, N
                    // seconds into the game (a headless check of the export).
                    // `-record-for N`: Record from the start for N seconds.
                    if let r = value("-record-for").flatMap(Double.init) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            ClipExporter.shared.toggleRecording()
                            DispatchQueue.main.asyncAfter(deadline: .now() + r) { ClipExporter.shared.stopRecording() }
                        }
                    }
                    // `-link CODE`: Link Cable with that code once the game
                    // runs (DEBUG `-signal ws://host:8790` picks the server).
                    // `-link-manual`: the manual code exchange (codes through
                    // files in tmp/, see NetLink.debugManual).
                    #if DEBUG
                    if args.contains("-link-manual") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NetLink.shared.debugManual() }
                    }
                    #endif
                    if let code = value("-link") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            NetLink.shared.openSheet()
                            NetLink.shared.connectTapped(code: code)
                        }
                    }
                    if let c = value("-clip-after").flatMap(Double.init) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + c) {
                            ClipExporter.shared.exportClip(startAgo: 3600, endAgo: 0, slug: "clipcheck", label: "Everything")
                        }
                    }
                } else if left > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { attempt(left - 1) }
                }
            }
            attempt(20)
        }
        if args.contains("-landscape"),
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        if let t = value("-theme"), let theme = ThemeName(rawValue: t) {
            Settings.shared.theme = theme
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if args.contains("-home") { model.showMainMenu() }
            if args.contains("-menu") { model.openMenu(paused: true) }
            if let s = value("-sheet") {
                let parts = s.split(separator: ":").map(String.init)
                switch parts[0] {
                case "settings": model.openSheet(.settings(section: parts.count > 1 ? parts[1] : nil))
                case "states": model.openSheet(.states)
                case "saves": model.openSheet(.saves)
                case "rewind": model.openSheet(.rewind)
                case "cheats": model.openSheet(.cheats)
                case "prints": model.openSheet(.prints)
                case "report": model.openSheet(.report)
                case "clip": model.openSheet(.clip)
                case "link": NetLink.shared.openSheet()
                case "tile": if let e = entries.first { model.openSheet(.tileMenu(e)) }
                case "rename": if let e = entries.first { model.openSheet(.rename(e)) }
                default: break
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(session)
                .environmentObject(library)
                .environment(\.palette, settings.palette)
                .preferredColorScheme(settings.palette.colorScheme)
                .onAppear(perform: autoplay)
                .onOpenURL { url in
                    // "Open in dingbat" from Files or another app.
                    Task { @MainActor in
                        if let e = try? await RomLibrary.shared.importRom(from: url) {
                            AppModel.shared.launch(e, resume: false)
                        }
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var palette

    var body: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            if model.screen == .play && model.session.game != nil {
                PlayView()
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
            ToastStack()
                .sheet(isPresented: Binding(get: { model.tombstonePrompt != nil },
                                            set: { if !$0 && model.tombstonePrompt != nil { model.answerTombstones(restore: false) } })) {
                    TombstoneSheet(games: model.tombstonePrompt ?? [])
                        .environment(\.palette, palette)
                }
        }
        .sheet(item: $model.sheet, onDismiss: sheetDismissed) { sheet in
            SheetHost(sheet: sheet)
                .environment(\.palette, palette)
                .preferredColorScheme(palette.colorScheme)
        }
    }

    private func sheetDismissed() {
        // The game paused for the sheet; it runs again only on the play
        // screen (web: modals pause, closing resumes).
        if model.screen == .play && model.sheet == nil && !model.menuOpen && model.sheetPausedGame {
            model.session.setPaused(false)
        }
        model.sheetPausedGame = false
    }
}

/// Routes each sheet to its view.
struct SheetHost: View {
    let sheet: AppModel.Sheet

    var body: some View {
        switch sheet {
        case .settings(let section): SettingsView(initialSection: section)
        case .states: SaveStatesView()
        case .saves: ManageSavesView()
        case .rewind: RewindScrubberView()
        case .cheats: CheatsView()
        case .prints: PrintsView()
        case .report: ReportBugView()
        case .clip: ClipRangeView()
        case .link: LinkCableView()
        case .tileMenu(let e): TileMenuView(entry: e)
        case .rename(let e): RenameView(entry: e)
        }
    }
}

/// The toast stack (web #toast): bottom-centre, at most three; an action
/// toast is one tap target with a close button.
struct ToastStack: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var palette

    var body: some View {
        // In a game the stack sits under the top bar, clear of the touch
        // controls; on the home screen it is bottom-centre as on the web.
        let top = model.screen == .play
        VStack(spacing: 8) {
            if !top { Spacer() }
            ForEach(model.toasts) { t in
                HStack(spacing: 10) {
                    Text(t.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(palette.text)
                        .multilineTextAlignment(.leading)
                    if let a = t.action {
                        Text(a.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(palette.accent)
                        Button {
                            model.dismissToast(t.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(palette.textDim)
                                .frame(width: 22, height: 22)
                        }
                        .accessibilityLabel("Dismiss")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(palette.surface2))
                .overlay(Capsule().stroke(palette.border2, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .contentShape(Capsule())
                .onTapGesture {
                    if let a = t.action {
                        model.dismissToast(t.id)
                        a.run()
                    }
                }
                .transition(.move(edge: top ? .top : .bottom).combined(with: .opacity))
            }
            if top { Spacer() }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, top ? 0 : 24)
        .padding(.top, top ? 60 : 0)
        .animation(.easeOut(duration: 0.2), value: model.toasts.map(\.id))
        .allowsHitTesting(!model.toasts.isEmpty)
    }
}
