import SwiftUI
import UIKit

/// dingbat.gg/status.json (docs/dev/announcements.md; web index.js checkStatus):
/// announcements as toasts (once each) and home-screen banners (until
/// dismissed), and required updates for builds older than a minBuild. Fetched
/// at launch and on a return to the app at most hourly; any failure means
/// nothing to say.
///
/// A required update's scope "link" offers Not now and holds the link cable
/// (NetLink.openSheet, AppModel.launchTwoPlayer) until the update; any other
/// scope, or one this build doesn't know, covers the app. Unlike the web
/// build this one can't see whether a newer build is out, so status.json
/// names an iOS minBuild only once the build that meets it is on the App
/// Store (or TestFlight), and its `url` is where to get it.
final class AppStatus: ObservableObject {
    static let shared = AppStatus()

    struct Announcement: Identifiable, Equatable {
        let id: String
        let text: String
        let url: URL?
        let label: String?
    }

    struct Required: Equatable {
        let link: Bool
        let message: String
        let url: URL?
    }

    @Published private(set) var banners: [Announcement] = []
    /// The card on screen: an app-wide requirement, or a link one the
    /// player can put off.
    @Published private(set) var required: Required?
    /// The link-scope requirement this build is under, holding the link cable.
    private(set) var linkRequired: Required?

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
    private static let idsMax = 64
    /// web TOAST_MAX: the rest wait for the next check.
    private static let toastsPerCheck = 3

    private var checkedAt = Date.distantPast
    private var linkNoticeShown = false

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.checkedAt) >= Self.interval else { return }
            self.check()
        }
    }

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: s)
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
            if a["builtBefore"] != nil {
                guard let before = Self.parse(a["builtBefore"] as? String), let built, built < before else { continue }
            }
            let url = (a["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            let item = Announcement(id: id, text: text, url: url, label: a["label"] as? String)
            // Where it goes; no place this build knows means a toast.
            var show = ((a["show"] as? [String]) ?? []).filter { $0 == "toast" || $0 == "banner" }
            if show.isEmpty { show = ["toast"] }
            if show.contains("toast") { toasts.append(item) }
            if show.contains("banner") { banners.append(item) }
        }

        var seen = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
        for a in toasts.filter({ !seen.contains($0.id) }).prefix(Self.toastsPerCheck) {
            seen.append(a.id)
            let action: (String, () -> Void) = a.url.map { url in
                (a.label ?? "Read More", { UIApplication.shared.open(url) })
            } ?? (a.label ?? "OK", {})
            AppModel.shared.toast(a.text, action: action, duration: 30)
        }
        UserDefaults.standard.set(Array(seen.suffix(Self.idsMax)), forKey: Self.seenKey)

        let dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        self.banners = banners.filter { !dismissed.contains($0.id) }
    }

    func dismissBanner(_ a: Announcement) {
        var dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        dismissed.removeAll { $0 == a.id }
        dismissed.append(a.id)
        UserDefaults.standard.set(Array(dismissed.suffix(Self.idsMax)), forKey: Self.dismissedKey)
        withAnimation(.easeOut(duration: 0.2)) { banners.removeAll { $0.id == a.id } }
    }

    private func applyRequired(_ list: [[String: Any]]) {
        guard let built = Self.buildTime else { return }
        let due = list.filter { r in
            guard Self.forIOS(r), let min = Self.parse(r["minBuild"] as? String) else { return false }
            return built < min
        }
        func make(_ r: [String: Any], link: Bool) -> Required {
            let message = (r["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (link ? "This version can't link with the current one. Update to link with friends again."
                         : "This version of dingbat has a problem that the update fixes.")
            return Required(link: link, message: message, url: (r["url"] as? String).flatMap(URL.init(string:)))
        }
        let app = due.first { ($0["scope"] as? String) != "link" }.map { make($0, link: false) }
        linkRequired = due.first { ($0["scope"] as? String) == "link" }.map { make($0, link: true) }
        if required?.link == false { return }
        // A link session is a friend's game too: neither card cuts into one.
        if NetLink.shared.holdsCore || GameSession.shared.twoPlayer { checkedAt = .distantPast; return }
        if let app {
            let session = GameSession.shared
            if session.game != nil {
                session.setPaused(true)
                session.persistSession()
                session.flushSave()
            }
            required = app
        } else if let link = linkRequired, !linkNoticeShown, required == nil {
            linkNoticeShown = true
            required = link
        }
    }

    /// The link cable's ways in: true when a link-scope requirement holds
    /// it, the card up in its place.
    func blocksLink() -> Bool {
        guard let link = linkRequired else { return false }
        if required == nil { required = link }
        return true
    }

    /// Not now, on a link-scope card.
    func later() {
        if required?.link == true { required = nil }
    }
}

/// A required update. App-wide: the whole screen, nothing behind it to reach,
/// the button at the bottom within the thumb's reach. Link scope: a card over
/// the dimmed app, with Not now under the update (web #required-modal).
struct RequiredUpdateView: View {
    let required: AppStatus.Required
    @Environment(\.palette) private var palette

    private var updateLabel: String {
        (required.url?.host ?? "").hasSuffix("apple.com") ? "Update on the App Store" : "Update"
    }

    var body: some View {
        if required.link { linkCard } else { fullScreen }
    }

    private var fullScreen: some View {
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
                Text(GameSession.shared.game != nil
                     ? "Your game is saved. Your games and saves stay on this device."
                     : "Your games and saves stay on this device.")
                    .font(.system(size: 15))
                    .foregroundColor(palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
            Spacer()
            if let url = required.url {
                updateButton(url)
                    .frame(maxWidth: 480)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg.ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
    }

    private var linkCard: some View {
        ZStack {
            palette.stage.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(palette.accent)
                    .accessibilityHidden(true)
                Text("Link Cable Needs an Update")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(palette.text)
                Text(required.message)
                    .font(.system(size: 16))
                    .foregroundColor(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Everything else keeps working.")
                    .font(.system(size: 14))
                    .foregroundColor(palette.textDim)
                VStack(spacing: 8) {
                    if let url = required.url { updateButton(url) }
                    Button { AppStatus.shared.later() } label: {
                        Text("Not Now")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(palette.text)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(RoundedRectangle(cornerRadius: 14).fill(palette.surface3))
                    }
                }
                .padding(.top, 10)
            }
            .multilineTextAlignment(.center)
            .padding(EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20))
            .background(RoundedRectangle(cornerRadius: 20).fill(palette.surface1))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(palette.border2, lineWidth: 1))
            .frame(maxWidth: 400)
            .padding(24)
        }
        .accessibilityAddTraits(.isModal)
    }

    private func updateButton(_ url: URL) -> some View {
        Button { UIApplication.shared.open(url) } label: {
            Text(updateLabel)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(palette.accentInk)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(palette.accent))
        }
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
            Image(systemName: "info.circle")
                .font(.system(size: 18))
                .foregroundColor(palette.accent)
                .accessibilityHidden(true)
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
        .padding(.leading, 14)
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
