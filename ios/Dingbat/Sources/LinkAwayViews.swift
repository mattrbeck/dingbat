import SwiftUI

/// The friend's app or tab went to the background (web #net-away): their
/// game is paused, so ours waits at the prediction limit. The modal look
/// (SheetChrome's surface, border and type) over the dimmed, frozen screen,
/// with an away clock and a two-tap Disconnect for a friend who never
/// comes back.
struct LinkAwayCard: View {
    let since: Date
    /// The connection dropped and the session is redialing (web: the same
    /// card, retitled).
    var reconnecting = false
    /// ...after the friend had said it was away: waiting on the friend, not
    /// the network (web RB_AWAY_DROP_TEXT).
    var awayDrop = false
    @Environment(\.palette) private var palette

    private var title: String { reconnecting && !awayDrop ? "Reconnecting…" : "Friend switched away" }
    private var text: String {
        if !reconnecting { return "Their game is paused until they come back. The link stays open — nothing is lost." }
        return awayDrop
            ? "The link dropped while they were away. If they come back within 3 minutes, both games pick up where they left off."
            : "The connection dropped. Both games are paused and pick up where they left off."
    }
    private var clock: String { !reconnecting ? "Away " : awayDrop ? "Waiting for " : "Trying for " }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(palette.text)
                .padding(.bottom, 10)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(palette.textDim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Text(clock + NetLink.fmtAway(ctx.date.timeIntervalSince(since)))
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
