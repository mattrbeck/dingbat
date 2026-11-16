import SwiftUI
import UIKit

/// dingbat.gg/status.json (docs/dev/announcements.md; web index.js checkStatus):
/// announcements, each shown once, and a required update for builds older
/// than `required.ios.minBuild`. Fetched at launch and on a return to the app
/// at most hourly; any failure means nothing to say.
///
/// Unlike the web build this one can't see whether a newer build is out, so
/// status.json names minBuild only once the build that meets it is on the
/// App Store (or TestFlight), and its `url` is where to get it.
final class AppStatus: ObservableObject {
    static let shared = AppStatus()

    struct Announcement: Identifiable, Equatable {
        let id: String
        let text: String
        let url: URL?
        let label: String?
    }

    struct Required: Equatable {
        let message: String
        let url: URL?
    }

    @Published private(set) var announcement: Announcement?
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
    private static let seenMax = 64

    private var checkedAt = Date.distantPast
    private var queue: [Announcement] = []

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

    func apply(_ json: [String: Any], now: Date = Date()) {
        let built = Self.buildTime
        var seen = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
        for a in (json["announcements"] as? [[String: Any]]) ?? [] {
            guard let id = a["id"] as? String, let text = a["text"] as? String, !seen.contains(id) else { continue }
            if let p = a["platforms"] as? [String], !p.contains("ios") { continue }
            if let from = Self.parse(a["from"] as? String), from > now { continue }
            if let until = Self.parse(a["until"] as? String), until <= now { continue }
            if a["builtBefore"] != nil {
                guard let before = Self.parse(a["builtBefore"] as? String), let built, built < before else { continue }
            }
            let url = (a["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            queue.append(Announcement(id: id, text: text, url: url, label: a["label"] as? String))
            seen.append(id)
        }
        UserDefaults.standard.set(Array(seen.suffix(Self.seenMax)), forKey: Self.seenKey)
        if announcement == nil, !queue.isEmpty { announcement = queue.removeFirst() }

        let req = (json["required"] as? [String: Any])?["ios"] as? [String: Any]
        if required == nil, let req, let min = Self.parse(req["minBuild"] as? String),
           let built, built < min {
            // A link session is a friend's game too: it waits for the next check.
            if NetLink.shared.holdsCore { checkedAt = .distantPast; return }
            let session = GameSession.shared
            if session.game != nil {
                session.setPaused(true)
                session.persistSession()
                session.flushSave()
            }
            let message = (req["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "This version of dingbat has a problem that the update fixes."
            required = Required(message: message, url: (req["url"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// The announcement alert closed, by its button or not: the next one.
    func announcementDone(open: Bool) {
        if open, let url = announcement?.url { UIApplication.shared.open(url) }
        announcement = nil
        if !queue.isEmpty {
            // After the alert's own dismissal, or SwiftUI drops the next one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.announcement == nil, !self.queue.isEmpty else { return }
                self.announcement = self.queue.removeFirst()
            }
        }
    }
}

/// A required update: the whole screen, with nothing behind it to reach.
struct RequiredUpdateView: View {
    let required: AppStatus.Required
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Update dingbat to keep playing")
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
                if let url = required.url {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Text("Update")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(palette.bg)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(palette.accent))
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 480)
        }
        .accessibilityAddTraits(.isModal)
    }
}
