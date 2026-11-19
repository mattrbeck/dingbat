import SwiftUI
import UIKit

struct AppIconChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let holiday: Bool

    var preview: String { "IconPreview-" + id }
    var alternateName: String? { id == "night-flyer" ? nil : "AppIcon-" + id }

    static let classic: [AppIconChoice] = [
        ("night-flyer", "Night Flyer"), ("moonlit", "Moonlit"), ("dusk", "Dusk"), ("midnight", "Midnight"),
        ("sunrise", "Sunrise"), ("ember", "Ember"), ("paper", "Paper"), ("ink", "Ink"),
        ("glacier", "Glacier"), ("pea-soup", "Pea Soup"),
    ].map { AppIconChoice(id: $0.0, name: $0.1, holiday: false) }

    static let holidays: [AppIconChoice] = [
        ("h-witch", "Halloween"), ("h-vampire", "Vampire"), ("h-santa", "Santa"), ("h-snowy", "Snow Day"),
        ("h-lunar", "Lunar New Year"), ("h-valentine", "Valentine"), ("h-pride", "Pride"), ("h-party", "New Year"),
    ].map { AppIconChoice(id: $0.0, name: $0.1, holiday: true) }

    static let all: [AppIconChoice] = classic + holidays

    static let primary = classic[0]

    static func named(_ id: String) -> AppIconChoice? { all.first { $0.id == id } }
}

@MainActor final class AppIconManager: ObservableObject {
    static let shared = AppIconManager()

    private static let chosenKey = "appicon.chosen"
    private static let holidaysKey = "appicon.holidays"

    @Published private(set) var chosen: AppIconChoice
    @Published var holidaysOn: Bool {
        didSet {
            UserDefaults.standard.set(holidaysOn, forKey: Self.holidaysKey)
            refresh()
        }
    }
    @Published var allowed = false {
        didSet { if allowed != oldValue { refresh() } }
    }

    private init() {
        let d = UserDefaults.standard
        chosen = d.string(forKey: Self.chosenKey).flatMap(AppIconChoice.named) ?? .primary
        holidaysOn = d.bool(forKey: Self.holidaysKey)
    }

    var showing: AppIconChoice {
        guard allowed else { return .primary }
        if holidaysOn, let h = holiday(on: Date()) { return h }
        return chosen
    }

    func choose(_ c: AppIconChoice) {
        chosen = c
        UserDefaults.standard.set(c.id, forKey: Self.chosenKey)
        refresh()
    }

    func refresh() {
        // `showing` depends on the date, so views must re-read it on each activation.
        objectWillChange.send()
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.applicationState == .active else { return }
        let want = showing.alternateName
        guard want != app.alternateIconName else { return }
        app.setAlternateIconName(want) { error in
            if let error { print("AppIcon: setAlternateIconName(\(want ?? "nil")) failed: \(error)") }
        }
    }

    func holiday(on date: Date) -> AppIconChoice? {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        // Ahead of Valentine: the two overlap in some years (2029, 2032, 2040).
        if let start = Self.lunarNewYear[y].flatMap({ cal.date(from: DateComponents(year: y, month: $0.month, day: $0.day)) }),
           let days = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: date)).day,
           (0..<7).contains(days) {
            return AppIconChoice.named("h-lunar")
        }
        let id: String?
        switch (m, d) {
        case (10, 24...31): id = "h-witch"
        case (12, 18...26): id = "h-santa"
        case (12, 30...31), (1, 1): id = "h-party"
        case (1, 2...15): id = "h-snowy"
        case (2, 10...14): id = "h-valentine"
        case (6, _): id = "h-pride"
        default: id = nil
        }
        return id.flatMap(AppIconChoice.named)
    }

    // First day of the first lunar month (China Standard Time), checked against ICU's Chinese calendar.
    private static let lunarNewYear: [Int: (month: Int, day: Int)] = [
        2026: (2, 17), 2027: (2, 6), 2028: (1, 26), 2029: (2, 13), 2030: (2, 3),
        2031: (1, 23), 2032: (2, 11), 2033: (1, 31), 2034: (2, 19), 2035: (2, 8),
        2036: (1, 28), 2037: (2, 15), 2038: (2, 4), 2039: (1, 24), 2040: (2, 12),
    ]
}
