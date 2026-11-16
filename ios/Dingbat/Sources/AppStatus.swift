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
                ?? (link ? "This version's link cable can't link with the current one. Everything else works as it is."
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

/// A required update: the whole screen. An app-wide one has nothing behind
/// it to reach; a link one has Not now.
struct RequiredUpdateView: View {
    let required: AppStatus.Required
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            palette.bg.opacity(required.link ? 0.94 : 1).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(required.link ? "Update dingbat to use the link cable" : "Update dingbat to keep playing")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(palette.text)
                    .multilineTextAlignment(.center)
                Text(required.message)
                    .font(.system(size: 15))
                    .foregroundColor(palette.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your games and saves stay on this device.")
                    .font(.system(size: 15))
                    .foregroundColor(palette.textDim)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    if required.link {
                        Button("Not Now") { AppStatus.shared.later() }
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(palette.text)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(palette.surface2))
                    }
                    if let url = required.url {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Text("Update")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(palette.accentInk)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 12)
                                .background(Capsule().fill(palette.accent))
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 480)
        }
        .accessibilityAddTraits(.isModal)
    }
}

/// status.json's banners, heading the home screen (web #home-notes).
struct AnnouncementBanners: View {
    @ObservedObject private var status = AppStatus.shared
    @Environment(\.palette) private var palette

    var body: some View {
        if !status.banners.isEmpty {
            VStack(spacing: 8) {
                ForEach(status.banners) { a in
                    HStack(spacing: 10) {
                        Text(a.text)
                            .font(.system(size: 14))
                            .foregroundColor(palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = a.url {
                            Button(a.label ?? "Read More") { UIApplication.shared.open(url) }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(palette.accent)
                        }
                        Button {
                            status.dismissBanner(a)
                        } label: {
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
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(palette.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.border2, lineWidth: 1))
                }
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }
}
