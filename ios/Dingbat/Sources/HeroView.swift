// The hero (web #hero): the game played this visit, heading the home
// screen. Paused while it is the game in memory (drawn from the live
// framebuffer, Resume · Close · ⋯), closed once it is not (its stored
// picture, Resume · Play · ⋯ while a session still counts, else Play · ⋯).
// Closing changes the mode in place; nothing in the grid moves.
import SwiftUI

struct HeroView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: GameSession
    @EnvironmentObject var library: RomLibrary
    @ObservedObject private var drive = DriveSync.shared
    @Environment(\.palette) var palette

    let entry: RomEntry
    /// Frame left, body beside it (web ≥760px).
    let wide: Bool
    /// The viewport width, for the web's vw clamps.
    let viewport: CGFloat
    /// The hero is the whole library (web body.home-solo): a size up.
    let solo: Bool

    @State private var live: UIImage?

    private var paused: Bool { session.game == entry }

    var body: some View {
        let hasSession = !paused && HomePictures.shared.hasSession(entry)
        Group {
            if wide {
                HStack(alignment: .center, spacing: solo ? 48 : 40) {
                    frame.frame(width: frameWidth)
                    details(hasSession: hasSession).frame(maxWidth: solo ? 380 : 460, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    frame.padding(.bottom, 2)
                    details(hasSession: hasSession)
                }
            }
        }
        .onAppear(perform: grab)
        .onChange(of: session.game) { _ in grab() }
        // A state loaded from the ⋯ menu's sheets changes the paused picture.
        .onChange(of: model.sheet == nil) { closed in if closed { grab() } }
    }

    private var frameWidth: CGFloat {
        solo ? min(480, max(320, viewport * 0.36)) : min(384, max(280, viewport * 0.30))
    }

    /// The live framebuffer, once per arrival (the game is paused here).
    private func grab() {
        live = paused ? session.currentImage() : nil
    }

    // MARK: picture

    private var closedPicture: UIImage? { HomePictures.shared.picture(entry, preferSession: true) }
    private var art: UIImage? { closedPicture == nil ? HomePictures.shared.art(entry) : nil }

    /// The picture's own shape: a GB frame is 10:9, everything else 3:2.
    private var aspect: CGFloat {
        let img = paused ? live : closedPicture
        if let img, img.size.height > 0 { return img.size.width / img.size.height }
        return 3 / 2
    }

    private var frame: some View {
        let img: UIImage? = paused ? live : (closedPicture ?? art)
        return ZStack {
            // The same frame again, blurred behind the sharp one: a glow the
            // colour of the game, not a picture of it.
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .saturation(palette.isLight ? 2.6 : 1.5)
                    .blur(radius: 36)
                    .scaleEffect(x: 1.16, y: 1.2)
                    .opacity(glowOpacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            Button(action: resume) {
                Group {
                    if paused {
                        ZStack {
                            Color.black
                            if let live {
                                Image(uiImage: live).resizable().interpolation(.none)
                                    .aspectRatio(contentMode: .fit)
                            }
                        }
                    } else {
                        GamePicture(entry: entry, preferSession: true, dimmed: true)
                            .id(library.pictureGen)
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.border2, lineWidth: 1))
                .shadow(color: .black.opacity(palette.isLight ? 0.22 : 0.55), radius: 22, y: 20)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Resume game")
        }
    }

    private var glowOpacity: Double {
        if palette.isLight { return paused ? 0.7 : 0.42 }
        return paused ? 0.45 : 0.14
    }

    // MARK: body

    private func details(hasSession: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            kicker
            Text(entry.name)
                .font(.system(size: nameSize, weight: .heavy))
                .tracking(-nameSize * 0.02)
                .foregroundColor(palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 10) {
                if paused {
                    primary("Resume", icon: "play.fill") { model.resumeFromHero() }
                    plain("Close") { model.closeGame() }
                        .accessibilityHint("Close the game — your save is kept")
                } else if hasSession {
                    primary("Resume", icon: "play.fill") { model.launch(entry, resume: true) }
                    plain("Play") { model.launch(entry, resume: false) }
                        .accessibilityHint("Start the game from its in-game save")
                } else {
                    primary("Play", icon: "play.fill") { model.launch(entry, resume: false) }
                }
                more
            }
            .padding(.top, 2)
        }
    }

    private var nameSize: CGFloat {
        if solo && wide { return min(42, max(30, viewport * 0.032)) }
        if wide { return min(36, max(28, viewport * 0.028)) }
        return min(30, max(24, viewport * 0.065))
    }

    private var kicker: some View {
        HStack(spacing: 10) {
            HeroLED(lit: paused)
            Text(kickerText.uppercased())
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.9)
                .foregroundColor(paused ? palette.accent : palette.textDim)
                .lineLimit(1)
                .truncationMode(.tail)
            SysChip(system: entry.system, height: 18)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kickerText), \(entry.system)")
    }

    /// web heroStateText: "Paused · Synced", "Last played", or where the
    /// session was left ("On your iPhone · 5m ago").
    private var kickerText: String {
        _ = drive.stateTick
        if paused {
            guard drive.linked else { return "Paused" }
            let g = entry.fileName
            let pending = ["save:" + g, "stateauto:" + g, "frame:" + g].contains(where: drive.state.queueUp.contains)
            if !pending { return "Paused · Synced" }
            return drive.status == .offline ? "Paused · Not synced yet" : "Paused · Syncing…"
        }
        if let m = RomLibrary.shared.sessionMeta(entry), HomePictures.shared.hasSession(entry),
           let by = m.by, by != DriveSync.deviceID {
            let ago = Date().timeIntervalSince1970 * 1000 - m.ts < 60000 ? "just now" : AppModel.fmtAgo(m.ts)
            return "On " + DriveSync.deviceWords(m.dev) + " · " + ago
        }
        return "Last played"
    }

    private func resume() {
        if paused { model.resumeFromHero() } else if HomePictures.shared.hasSession(entry) {
            model.launch(entry, resume: true)
        } else {
            model.launch(entry, resume: false)
        }
    }

    // MARK: buttons

    private func primary(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13))
                Text(label).font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(palette.accentInk)
            .padding(.horizontal, 22)
            .frame(minHeight: 48)
            .frame(maxWidth: wide ? nil : .infinity)
            .background(Capsule().fill(LinearGradient(colors: [palette.accent2, palette.accent],
                                                      startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().stroke(palette.accent.opacity(0.6), lineWidth: 1))
            .shadow(color: palette.accentGlow, radius: 6, y: 2)
        }
        .buttonStyle(PressStyle())
    }

    private func plain(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15))
                .foregroundColor(palette.text)
                .padding(.horizontal, 22)
                .frame(minHeight: 48)
                .background(Capsule().fill(LinearGradient(colors: [palette.surface3, palette.surface2],
                                                          startPoint: .top, endPoint: .bottom)))
                .overlay(Capsule().stroke(palette.border2, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
    }

    /// ⋯: the session menu while paused (web sessionMenuEntries), the
    /// game's file menu once closed.
    @ViewBuilder private var more: some View {
        let label = Image(systemName: "ellipsis")
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(palette.textDim)
            .frame(width: 48, height: 48)
            .background(Capsule().fill(LinearGradient(colors: [palette.surface3, palette.surface2],
                                                      startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().stroke(palette.border2, lineWidth: 1))
        if paused {
            Menu {
                SessionMenuItems()
            } label: { label }
                .accessibilityLabel("More for this game")
        } else {
            Button { model.openSheet(.tileMenu(entry)) } label: { label }
                .buttonStyle(PressStyle())
                .accessibilityLabel("More for this game")
        }
    }
}

/// The lamp: lit and breathing while the game is held in memory, out once
/// it is closed (web #hero-led).
struct HeroLED: View {
    @Environment(\.palette) var palette
    let lit: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(lit ? palette.accent : palette.textFaint)
            .frame(width: 8, height: 8)
            .shadow(color: lit ? palette.accent.opacity(0.8) : .clear, radius: 5)
            .opacity(lit ? (dim ? 0.35 : 1) : 0.55)
            .onAppear { pulse() }
            .onChange(of: lit) { _ in pulse() }
            .accessibilityHidden(true)
    }

    private func pulse() {
        dim = false
        guard lit else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
    }
}
