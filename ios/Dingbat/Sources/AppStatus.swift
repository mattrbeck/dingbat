import SwiftUI
import UIKit

/// dingbat.gg/status.json (docs/dev/announcements.md; web index.js checkStatus):
/// announcements as toasts (once each) and home-screen banners (until
/// dismissed), and required updates for builds older than a minBuild. Fetched
/// at launch and on a return to the app at most hourly; any failure means
/// nothing to say.
///
/// A required update covers the app until the update (a link-only break is
/// the signaling server's SIGNAL_MIN_CLIENT, as the link dials). Unlike the web
/// build this one can't see whether a newer build is out, so status.json
/// names an iOS minBuild only once the build that meets it is on the App
/// Store (or TestFlight), and its `url` is where to get it.
final class AppStatus: ObservableObject {
    static let shared = AppStatus()

    struct Announcement: Identifiable, Equatable, Codable {
        let id: String
        let text: String
        let url: URL?
        let label: String?
        let until: Date?
    }

    struct Required: Equatable {
        let message: String
        let url: URL?
    }

    @Published private(set) var banners: [Announcement] = []
    /// On screen (RequiredUpdateView).
    @Published private(set) var required: Required?

    static var statusURL: URL {
        #if DEBUG
        // `-status http://host:port/status.json` for tests.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-status"), i + 1 < args.count, let u = URL(string: args[i + 1]) {
            return u
        }
        #endif
        return URL(string: "https://dingbat.gg/status.json")!
    }

    /// The build's commit time (project.yml "Stamp the commit"); nil in a
    /// build made outside git, which is never required to update.
    static let buildTime: Date? = parse(Bundle.main.infoDictionary?["DingbatBuildTime"] as? String)

    private static let interval: TimeInterval = 60 * 60
    private static let seenKey = "seenAnnouncements"
    private static let dismissedKey = "dismissedBanners"
    /// The last check's banners, shown at launch before status.json answers
    /// (web STATUS_BANNERS_KEY): the home screen doesn't shift a moment later.
    private static let bannersKey = "announcementBanners"
    private static let idsMax = 64

    private var checkedAt = Date.distantPast

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.bannersKey),
           let cached = try? JSONDecoder().decode([Announcement].self, from: data) {
            banners = Self.showable(cached)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.checkedAt) >= Self.interval else { return }
            self.check()
        }
    }

    /// tools/status/rules.mjs allows only 2026-11-16T19:51:20Z; milliseconds
    /// (JavaScript's toISOString) are read too, should one get past it.
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    func check() {
        checkedAt = Date()
        let req = URLRequest(url: Self.statusURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: 15)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            DispatchQueue.main.async { self.apply(json) }
        }.resume()
    }

    private static func forIOS(_ e: [String: Any]) -> Bool {
        (e["platforms"] as? [String])?.contains("ios") ?? true
    }

    func apply(_ json: [String: Any], now: Date = Date()) {
        applyAnnouncements((json["announcements"] as? [[String: Any]]) ?? [], now: now)
        applyRequired((json["required"] as? [[String: Any]]) ?? [])
    }

    private func applyAnnouncements(_ list: [[String: Any]], now: Date) {
        let built = Self.buildTime
        var toasts: [Announcement] = []
        var banners: [Announcement] = []
        for a in list {
            guard let id = a["id"] as? String, let text = a["text"] as? String, Self.forIOS(a) else { continue }
            if let from = Self.parse(a["from"] as? String), from > now { continue }
            if let until = Self.parse(a["until"] as? String), until <= now { continue }
            // A build made outside git (no time) is newer than every release.
            if a["builtBefore"] != nil {
                guard let before = Self.parse(a["builtBefore"] as? String), let built, built < before else { continue }
            }
            if a["builtAfter"] != nil {
                guard let after = Self.parse(a["builtAfter"] as? String) else { continue }
                if let built, built < after { continue }
            }
            let url = (a["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            let item = Announcement(id: id, text: text, url: url, label: a["label"] as? String,
                                    until: Self.parse(a["until"] as? String))
            // Where it goes; no place this build knows means a toast.
            var show = ((a["show"] as? [String]) ?? []).filter { $0 == "toast" || $0 == "banner" }
            if show.isEmpty { show = ["toast"] }
            if show.contains("toast") { toasts.append(item) }
            if show.contains("banner") { banners.append(item) }
        }

        // One toast a check (web showAnnouncementToast): more would push the
        // launch's own offers out of the three-toast stack. Plain, or with
        // its link as the action; what must stay up is a banner.
        let seen = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
        if let a = toasts.first(where: { !seen.contains($0.id) }) {
            UserDefaults.standard.set(Array((seen + [a.id]).suffix(Self.idsMax)), forKey: Self.seenKey)
            if let url = a.url {
                AppModel.shared.toast(a.text, action: (a.label ?? "Read More", { UIApplication.shared.open(url) }),
                                      duration: 12)
            } else {
                AppModel.shared.toast(a.text, duration: 8)
            }
        }

        UserDefaults.standard.set(try? JSONEncoder().encode(banners), forKey: Self.bannersKey)
        self.banners = Self.showable(banners)
    }

    private static func showable(_ list: [Announcement]) -> [Announcement] {
        let dismissed = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        let now = Date()
        return list.filter { !dismissed.contains($0.id) && !($0.until.map { $0 <= now } ?? false) }
    }

    func dismissBanner(_ a: Announcement) {
        var dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        dismissed.removeAll { $0 == a.id }
        dismissed.append(a.id)
        UserDefaults.standard.set(Array(dismissed.suffix(Self.idsMax)), forKey: Self.dismissedKey)
        withAnimation(.easeOut(duration: 0.2)) { banners.removeAll { $0.id == a.id } }
    }

    private func applyRequired(_ list: [[String: Any]]) {
        guard required == nil, let built = Self.buildTime,
              let r = list.first(where: { r in
                  guard Self.forIOS(r), let min = Self.parse(r["minBuild"] as? String) else { return false }
                  return built < min
              }) else { return }
        // A link session is a friend's game too: the screen waits for the next check.
        if NetLink.shared.holdsCore || GameSession.shared.twoPlayer { checkedAt = .distantPast; return }
        let session = GameSession.shared
        if session.game != nil {
            session.setPaused(true)
            session.persistSession()
            session.flushSave()
        }
        let message = (r["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "This version of dingbat has a problem that the update fixes."
        required = Required(message: message, url: (r["url"] as? String).flatMap(URL.init(string:)))
    }
}

/// A required update: the whole screen, nothing behind it to reach, the
/// button at the bottom within the thumb's reach.
struct RequiredUpdateView: View {
    let required: AppStatus.Required
    @Environment(\.palette) private var palette

    static func updateLabel(_ url: URL?) -> String {
        (url?.host ?? "").hasSuffix("apple.com") ? "Update on the App Store" : "Update"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image("Logo")
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 84)
                    .padding(.bottom, 10)
                    .accessibilityHidden(true)
                Text("Update Required")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(palette.text)
                Text(required.message)
                    .font(.system(size: 17))
                    .foregroundColor(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(GameSession.shared.game != nil ? "Your game is saved." : "Your games and saves stay on this device.")
                    .font(.system(size: 15))
                    .foregroundColor(palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
            Spacer()
            if let url = required.url {
                Button { UIApplication.shared.open(url) } label: {
                    Text(Self.updateLabel(url))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(palette.accentInk)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 14).fill(palette.accent))
                }
                .frame(maxWidth: 480)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg.ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
    }
}

/// status.json's banners, heading the home screen (web #home-notes): as wide
/// as what is under them. On a compact width a link goes under the text; on a
/// regular width (iPad) beside it.
struct AnnouncementBanners: View {
    let maxWidth: CGFloat
    @ObservedObject private var status = AppStatus.shared
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if !status.banners.isEmpty {
            VStack(spacing: 8) {
                ForEach(status.banners) { banner($0) }
            }
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func banner(_ a: AppStatus.Announcement) -> some View {
        let wide = sizeClass == .regular
        return HStack(alignment: wide ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(a.text)
                    .font(.system(size: 15))
                    .foregroundColor(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !wide, let url = a.url { link(a, url) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if wide, let url = a.url { link(a, url) }
            Button { status.dismissBanner(a) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(palette.textDim)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, wide ? 8 : 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.surface2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.border2, lineWidth: 1))
    }

    private func link(_ a: AppStatus.Announcement, _ url: URL) -> some View {
        Button(a.label ?? "Read More") { UIApplication.shared.open(url) }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(palette.accent)
    }
}
