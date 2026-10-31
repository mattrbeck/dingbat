import SwiftUI

/// The core stopped on a bug of its own (dingbat_fault): what happened in a
/// sentence, and the ways on. Going back to the last clean moment leads; a
/// second stop on the same frame puts the report first instead, since going
/// back would only reach it again. The sheet the player opens from here
/// (the scrubber, the report) resumes the game on its way out, and a
/// faulted game that resumes brings this sheet straight back, so closing
/// one of them returns here. The swipe-down is off: there is nothing to go
/// back to underneath but a stopped game.
struct FaultView: View {
    @ObservedObject private var session = GameSession.shared
    @ObservedObject private var settings = Settings.shared
    @Environment(\.palette) private var palette
    @State private var details = false
    @State private var thumb: UIImage?
    @State private var history = 0
    @State private var rewindSamples = 0

    /// How far "Go back" goes: far enough to be before most set-ups of a
    /// bug, near enough that little play is lost.
    static let backSeconds = 10

    private var gameName: String { session.game?.name ?? "The game" }
    private var linked: Bool { NetLink.shared.holdsCore || session.twoPlayer }
    private var again: Bool { dingbat_fault_count() > 1 }
    private var same: Bool { dingbat_fault_same() != 0 }
    private var canGoBack: Bool { !linked && history > 0 }
    private var goBackSeconds: Int { min(Self.backSeconds, history) }

    var body: some View {
        SheetChrome(title: again ? "It stopped again" : "\(gameName) stopped") {
            Text(summary)
                .font(.system(size: 14))
                .foregroundColor(palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
            if again {
                reportLead
                options(goBackRow: canGoBack)
            } else {
                if canGoBack { goBackLead }
                options(goBackRow: false)
            }
            detailsBox
                .padding(.top, 14)
        }
        .interactiveDismissDisabled()
        .onAppear(perform: load)
    }

    private var summary: String {
        if again && same {
            let at = String(format: "%.1f s", Double(dingbat_fault_frame()) / 59.73)
            return "Same error, same moment: \(at) in. This game seems to reach a Dingbat bug here every time, so going back will likely end here again. Your in-game save is safe."
        }
        if again {
            return "Dingbat hit an internal error again and paused the game. Your in-game save is safe."
        }
        return "Dingbat hit an internal error and paused the game. Your in-game save is safe."
    }

    // MARK: the lead option

    private var goBackLead: some View {
        Button(action: goBack) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(palette.stage)
                    if let thumb {
                        Image(uiImage: thumb).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    }
                }
                .frame(width: 80, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Go back \(goBackSeconds) seconds")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(palette.text)
                        Text("Best bet")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(palette.accentInk)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(palette.accent))
                    }
                    Text("Carry on from the last moment that ran cleanly.")
                        .font(.system(size: 13))
                        .foregroundColor(palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.accent, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padFocus("fault:back", press: goBack)
        .padding(.bottom, 12)
    }

    private var reportLead: some View {
        Button(action: report) {
            HStack(spacing: 14) {
                Image(systemName: "ladybug")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send a bug report")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Both stops are in it. That's what gets this fixed.")
                        .font(.system(size: 13))
                        .opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(palette.accentInk)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(palette.accent))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padFocus("fault:report", press: report)
        .padding(.bottom, 12)
    }

    // MARK: the rest

    private func options(goBackRow: Bool) -> some View {
        VStack(spacing: 0) {
            if !linked && settings.rewind && rewindSamples > 1 {
                row("backward.end", "Choose an earlier moment",
                    again ? "Try a different path past this point" : "Scrub back through the rewind history",
                    id: "fault:earlier", action: chooseEarlier)
            }
            if !linked {
                row("arrow.counterclockwise", "Restart the game", "From power-on, keeping the in-game save",
                    id: "fault:restart", action: restart)
            }
            if goBackRow {
                row("arrow.uturn.backward", "Go back \(goBackSeconds) seconds anyway",
                    "Useful if you'll play it differently", id: "fault:back", action: goBack)
            }
            if !again {
                row("ladybug", "Send a bug report", "Everything needed to replay this, ready to share",
                    id: "fault:report", action: report)
            }
            row("square.grid.2x2", linked ? "Leave and go to the library" : "Back to the library",
                "Leave \(gameName) for now", id: "fault:library", action: library, last: true)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.surface2Lo))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ icon: String, _ title: String, _ sub: String, id: String,
                     action: @escaping () -> Void, last: Bool = false) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(palette.accent2)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(palette.text)
                    Text(sub).font(.system(size: 12.5)).foregroundColor(palette.textDim)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padFocus(id, press: action)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(palette.border).frame(height: 1) }
        }
    }

    private var detailsBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { details.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Technical details")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(details ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .font(.system(size: 13.5))
                .foregroundColor(palette.textDim)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(details ? "shown" : "hidden")
            if details {
                Text(Self.detailText())
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(palette.stage))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
            }
        }
    }

    /// The error, where, how often, and the build: also the report's.
    static func detailText() -> String {
        let frame = Int(dingbat_fault_frame())
        let core = dingbat_is_nds() != 0 ? "DS" : dingbat_is_gb() != 0 ? "Game Boy" : "GBA"
        var at = "\(core) core"
        if frame >= 0 { at += String(format: " · frame %d (%.1f s in)", frame, Double(frame) / 59.73) }
        let n = Int(dingbat_fault_count())
        if n > 1 { at += " · stop \(n)" + (dingbat_fault_same() != 0 ? ", same frame" : "") }
        return "\(String(cString: dingbat_fault_message()))\n\(at)\n\(ReportBugView.diagnostics())"
    }

    // MARK: actions

    private func load() {
        history = Int(dingbat_fault_history())
        rewindSamples = settings.rewind ? Int(dingbat_rewind_scrub_generate(2)) : 0
        thumb = nil
        // The anchor going back lands on: the newest at least backSeconds old.
        let n = Int(dingbat_clip_scrub_generate(60))
        guard n > 0, let base = dingbat_clip_scrub_thumbs() else { return }
        let w = Int(dingbat_clip_scrub_thumb_w()), h = Int(dingbat_clip_scrub_thumb_h())
        let want = Self.backSeconds * 60
        var pick = n - 1
        for s in 0..<n where Int(dingbat_clip_scrub_frames_ago(Int32(s))) > want {
            pick = s
            break
        }
        thumb = GameSession.bgr555Image(base + pick * w * h * 2, width: w, height: h,
                                       shades: GameSession.pictureShades())
    }

    private func goBack() {
        let went = Int(dingbat_fault_go_back(Int32(Self.backSeconds)))
        guard went >= 0 else {
            AppModel.shared.toast("Couldn't go back: nothing from before it was kept")
            return
        }
        SheetNav.close()
        session.faultRecovered()
        AppModel.shared.toast("Back \(went) seconds", duration: 3, game: true)
    }

    /// Opens over this sheet's place; leaving it resumes the game, which
    /// shows this sheet again unless the core was put right.
    private func open(_ s: AppModel.Sheet) {
        let model = AppModel.shared
        model.openSheet(s)
        model.sheetPausedGame = true
    }

    private func chooseEarlier() { open(.rewind) }

    private func report() { open(.report) }

    private func restart() {
        SheetNav.close()
        session.reset()
        if dingbat_fault() == 0 { session.faultRecovered() }
    }

    private func library() {
        let model = AppModel.shared
        model.sheet = nil
        model.showMainMenu()
        model.closeGame()
    }
}
