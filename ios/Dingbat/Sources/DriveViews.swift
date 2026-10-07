// Google Drive's surfaces (web "Sync UI surfaces"): the account button in
// the home bar and its menu, Google's own sign-in button, the in-game sync
// indicator, the "Games removed on another device" sheet, the Settings ›
// General block and the empty library's "Already playing on another device?".
import SwiftUI

/// Google's official "Sign in with Google" button art (web
/// google-signin-{dark,light}.svg, from Google's branding kit).
struct GoogleSignInButton: View {
    @Environment(\.palette) var palette
    @ObservedObject private var drive = DriveSync.shared
    @State private var busy = false

    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            Task { @MainActor in
                do { try await drive.connect() } catch {
                    if !(error is DriveSessionEnded) { AppModel.shared.toast(error.localizedDescription) }
                }
                busy = false
            }
        } label: {
            Image(palette.isLight ? "GoogleSignIn-light" : "GoogleSignIn-dark")
                .resizable()
                .frame(width: 180, height: 40)
                .opacity(busy ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Google")
    }
}

/// The account slot at the bar's far right (home screen only): a quiet
/// outline of a person signed out; the account's initial with a sync badge
/// (tick, spinning ring, amber !) signed in. Both open the account menu.
struct AccountButton: View {
    @Environment(\.palette) var palette
    @ObservedObject private var drive = DriveSync.shared
    @State private var open = false

    private var kind: String {
        drive.status == .syncing ? "syncing" : drive.status.stalled ? "attention" : "ok"
    }

    var body: some View {
        Button { open = true } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if drive.linked, let c = drive.email?.trimmingCharacters(in: .whitespaces).first {
                        Text(String(c).uppercased())
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(palette.accentInk)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(palette.accent))
                    } else {
                        Image(systemName: "person")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(palette.chromeInkDim)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(palette.chromeBtnBorder, lineWidth: 1))
                    }
                }
                if drive.linked { badge.offset(x: 3, y: 3) }
            }
            .frame(width: 36, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(drive.linked ? "Google Drive: " + (drive.status == .syncing ? "Syncing" : drive.status.stalled ? drive.status.word : "Signed in") : "Sign in")
        .popover(isPresented: $open) {
            AccountMenu()
                .environment(\.palette, palette)
                .modifier(PopoverOnPhone())
        }
    }

    @ViewBuilder private var badge: some View {
        ZStack {
            Circle().fill(palette.topbarTop).frame(width: 14, height: 14)
            switch kind {
            case "syncing":
                ProgressView().scaleEffect(0.45).tint(palette.accent)
            case "attention":
                Text("!").font(.system(size: 10, weight: .heavy)).foregroundColor(palette.accent)
            default:
                Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundColor(palette.live)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// Keep a popover a popover on a phone (iOS 16.4+; a sheet before).
private struct PopoverOnPhone: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) { content.presentationCompactAdaptation(.popover) } else { content }
    }
}

/// The account menu (web #account-pop).
struct AccountMenu: View {
    @Environment(\.palette) var palette
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var drive = DriveSync.shared
    @State private var everywhereArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !drive.linked {
                Text("Keep your games in Google Drive")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(palette.text)
                Text("Your saves are backed up, and your library follows you to every device you sign in on.")
                    .font(.system(size: 13))
                    .foregroundColor(palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                GoogleSignInButton()
            } else {
                HStack(spacing: 10) {
                    Text(String(drive.email?.first ?? "?").uppercased())
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(palette.accentInk)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(palette.accent))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in with Google").font(.system(size: 14, weight: .semibold)).foregroundColor(palette.text)
                        if let e = drive.email {
                            Text(e).font(.system(size: 12)).foregroundColor(palette.textDim).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                let (title, sub) = statusText
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(drive.status.stalled ? palette.accent : drive.status == .syncing ? palette.textFaint : palette.live)
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(palette.text)
                        Text(sub).font(.system(size: 12)).foregroundColor(palette.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
                Button {
                    Task { @MainActor in await drive.runFullSync() }
                } label: {
                    Text(drive.status == .syncing ? "Syncing…" : "Sync now")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundColor(palette.text)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface3))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(drive.status == .syncing)
                HStack {
                    PadButton("Sign out") {
                        dismiss()
                        drive.signOut()
                    }
                    Spacer()
                    Button(everywhereArmed ? "Tap again to sign out everywhere" : "Sign out everywhere") {
                        if !everywhereArmed {
                            everywhereArmed = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { everywhereArmed = false }
                            return
                        }
                        dismiss()
                        Task { @MainActor in await drive.signOutEverywhere() }
                    }
                    .foregroundColor(everywhereArmed ? palette.danger : palette.textDim)
                }
                .font(.system(size: 13))
                .foregroundColor(palette.textDim)
            }
        }
        .padding(18)
        .frame(width: 300)
        .background(palette.surface1)
    }

    /// web accountStatusText.
    private var statusText: (String, String) {
        let n = drive.pendingCount
        let waiting = "\(n) " + (n == 1 ? "change" : "changes")
        switch drive.status {
        case .syncing:
            return ("Syncing with Google Drive…", n > 0 ? waiting + " going up." : "Checking for changes.")
        case .paused:
            return ("Google Drive needs you again",
                    (n > 0 ? waiting + " waiting. They" : "Your changes") + " are safe on this device. Tap Sync now to reconnect.")
        case .offline:
            return ("Can't reach Google Drive",
                    (n > 0 ? waiting + " waiting. They" : "Your changes") + " are safe on this device and upload when Drive is back.")
        default:
            if !drive.active { return ("Games and saves are in your Drive", "Reconnects when you next sync.") }
            return ("Games and saves are in your Drive", n > 0 ? waiting + " waiting to go up." : "Everything is synced.")
        }
    }
}

/// In-game sync status beside the fps (web #sync-indicator).
struct SyncIndicator: View {
    @Environment(\.palette) var palette
    @Environment(\.horizontalSizeClass) var hSize
    @ObservedObject private var drive = DriveSync.shared

    var body: some View {
        if drive.linked, drive.status != .idle {
            HStack(spacing: 4) {
                switch drive.status {
                case .syncing: ProgressView().scaleEffect(0.55).tint(palette.statusInk)
                case .offline, .paused: Image(systemName: "icloud.slash").font(.system(size: 11, weight: .semibold))
                default: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                }
                if hSize == .regular {
                    Text(drive.status.word)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .foregroundColor(drive.status.stalled ? palette.accent : palette.statusInk)
            .frame(minWidth: 24, minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture { AppModel.shared.toast(drive.status.desc) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(drive.status.desc)
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// "Games removed on another device" (web confirmTombstones).
struct TombstoneSheet: View {
    @Environment(\.palette) var palette
    let games: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Games removed on another device")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(palette.text)
            Text("These games were deleted from your synced Drive and will be removed from this device. Restore keeps them and puts them back on Drive.")
                .font(.system(size: 13))
                .foregroundColor(palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(games, id: \.self) { g in
                        HStack(spacing: 10) {
                            SysChip(system: RomEntry(fileName: g).system)
                            Text(g).font(.system(size: 14)).foregroundColor(palette.text).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            HStack {
                PadButton("Restore") { AppModel.shared.answerTombstones(restore: true) }
                    .foregroundColor(palette.textDim)
                Spacer()
                Button {
                    AppModel.shared.answerTombstones(restore: false)
                } label: {
                    Text("Continue")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(palette.accentInk)
                        .padding(.horizontal, 20)
                        .frame(height: 36)
                        .background(Capsule().fill(palette.accent))
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surface1.ignoresSafeArea())
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}

/// The empty library's second way in: a library on another device (web
/// #home-drive-row).
struct HomeDriveRow: View {
    @Environment(\.palette) var palette
    @ObservedObject private var drive = DriveSync.shared

    var body: some View {
        VStack(spacing: 10) {
            Text("Already playing on another device?")
                .font(.system(size: 13))
                .foregroundColor(palette.textDim)
            if drive.linked {
                PadButton("Sync") { Task { @MainActor in await drive.runFullSync() } }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.text)
            } else {
                GoogleSignInButton()
            }
        }
        .padding(.top, 18)
    }
}

/// Settings › General › Google Drive (web #gdrive-body).
struct DriveSettingsBlock: View {
    @Environment(\.palette) var palette
    @ObservedObject private var drive = DriveSync.shared
    @State private var everywhereArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !drive.linked {
                Text("Sign in with Google")
                    .font(.system(size: 15, weight: .medium)).foregroundColor(palette.text)
                Text("Mirrors your games and saves to your Google Drive, so they're backed up and follow you to every device you sign in on.")
                    .font(.system(size: 12.5)).foregroundColor(palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                GoogleSignInButton()
            } else {
                Text(drive.email ?? "Connected to Google Drive")
                    .font(.system(size: 15, weight: .medium)).foregroundColor(palette.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(statusLine)
                    .font(.system(size: 12.5)).foregroundColor(palette.textDim)
                HStack(spacing: 10) {
                    PadButton("Sync") { Task { @MainActor in await drive.runFullSync() } }
                    PadButton("Sign out") { drive.signOut() }
                    Spacer()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(palette.text)
                Button(everywhereArmed ? "Tap again to sign out everywhere" : "Sign out everywhere") {
                    if !everywhereArmed {
                        everywhereArmed = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { everywhereArmed = false }
                        return
                    }
                    Task { @MainActor in await drive.signOutEverywhere() }
                }
                .font(.system(size: 13))
                .foregroundColor(everywhereArmed ? palette.danger : palette.textDim)
            }
        }
    }

    private var statusLine: String {
        let n = drive.pendingCount
        if !drive.active { return "Reconnects when you next sync." }
        if n == 0 { return "All changes synced." }
        return "\(n) \(n == 1 ? "change" : "changes") waiting to go up."
    }
}
