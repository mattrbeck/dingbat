import SwiftUI

/// The friend's app or tab went to the background (web #net-away): their
/// game is paused, so ours waits at the prediction limit. The modal look
/// (SheetChrome's surface, border and type) over the dimmed, frozen screen,
/// with an away clock and a two-tap Disconnect for a friend who never
/// comes back.
struct LinkAwayCard: View {
    let since: Date
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Friend switched away")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(palette.text)
                .padding(.bottom, 10)
            Text("Their game is paused until they come back. The link stays open — nothing is lost.")
                .font(.system(size: 14))
                .foregroundColor(palette.textDim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Text("Away " + NetLink.fmtAway(ctx.date.timeIntervalSince(since)))
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundColor(palette.textDim)
                }
                Spacer(minLength: 0)
                SheetConfirmButton(label: "Disconnect…", confirmLabel: "Are you sure?") {
                    NetLink.shared.disconnect()
                }
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(palette.surface1))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(palette.border2, lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 35, y: 24)
        .padding(16)
    }
}

/// A stall nothing explains (web #net-stall): the friend's build is older,
/// or their app was suspended before it could say it was away.
struct LinkWaitingBadge: View {
    let seconds: Int
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
                .font(.system(size: 10, weight: .semibold))
            Text("waiting for friend · " + NetLink.fmtAway(TimeInterval(seconds)))
                .font(.system(size: 11, design: .monospaced))
                .tracking(0.6)
        }
        .foregroundColor(palette.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(palette.surface1.opacity(0.85)))
        .overlay(Capsule().stroke(palette.accent.opacity(0.35), lineWidth: 1))
        .accessibilityLabel("Waiting for your friend, \(seconds) seconds")
    }
}
