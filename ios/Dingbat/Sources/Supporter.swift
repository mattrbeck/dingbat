import StoreKit
import SwiftUI

/// The Supporter unlock: three one-time, non-consumable tiers that all
/// unlock the same extras (pay what feels right). Everything that plays a
/// game (link cable, saves, sync, BIOS files, fast-forward, rewind) stays
/// free; only looks and extras are behind it. Family Sharing on in App Store
/// Connect for all three.
@MainActor
final class Supporter: ObservableObject {
    static let shared = Supporter()

    /// Cheapest first; the sheet's tiers follow this order.
    static let productIDs = [
        "com.mattrb.dingbat.supporter.thanks",
        "com.mattrb.dingbat.supporter.bigthanks",
        "com.mattrb.dingbat.supporter.hugethanks",
    ]
    /// Shown until the App Store answers (and in the simulator without a
    /// StoreKit configuration).
    static let fallbackPrices = ["$2.99", "$4.99", "$9.99"]
    static let tierNames = ["Thanks", "Big thanks", "Huge thanks"]

    /// The last answer, so the unlock shows at launch before StoreKit
    /// replies. Not in Settings.resetAll: a reset must not take it away.
    nonisolated static let cacheKey = "supporter.unlocked"
    /// For code off the main actor (Settings, the library scans, webhooks).
    nonisolated static var storedUnlocked: Bool { UserDefaults.standard.bool(forKey: cacheKey) }

    /// The sheet's cards, in order; a locked row opens the sheet on its own.
    enum Perk: Int, CaseIterable { case themes, icons, palette, filters, early, advanced, clips, badge }

    @Published private(set) var unlocked: Bool
    @Published private(set) var since: Date?
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    /// The Supporter sheet over Settings (a locked row opens it there, so
    /// closing it returns to the same pane), and the card it opens on.
    @Published var sheetUp = false
    @Published private(set) var sheetCard: Perk = .themes
    /// A thank-you row's pane for Settings to open under the sheet.
    @Published var jumpTo: SettingsPane?

    private var updates: Task<Void, Never>?

    /// At launch: the icon follows the unlock, and on every return to the
    /// app the light/dark theme and the holiday icon are checked again
    /// (switching appearance in Control Center passes through inactive).
    static func installLifecycle() {
        AppIconManager.shared.allowed = shared.unlocked
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                Settings.shared.refreshSystemAppearance()
                AppIconManager.shared.refresh()
            }
        }
    }

    func open(_ perk: Perk = .themes) {
        sheetCard = perk
        sheetUp = true
    }

    private init() {
        unlocked = UserDefaults.standard.bool(forKey: Self.cacheKey)
        #if DEBUG
        // `-supporter on|off`: pretend, for screenshots (no purchase made).
        if let v = UserDefaults.standard.string(forKey: "supporter") {
            unlocked = v == "on"
            UserDefaults.standard.set(unlocked, forKey: Self.cacheKey)
            debugForced = true
            return
        }
        #endif
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task {
            await refresh()
            await loadProducts()
        }
    }

    #if DEBUG
    private var debugForced = false
    #endif

    func price(_ tier: Int) -> String {
        products.first { $0.id == Self.productIDs[tier] }?.displayPrice ?? Self.fallbackPrices[tier]
    }

    func loadProducts() async {
        guard let found = try? await Product.products(for: Self.productIDs) else { return }
        products = found
    }

    /// Re-read what this Apple Account owns. A refunded tier is revoked and
    /// drops out of currentEntitlements.
    func refresh() async {
        var first: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, Self.productIDs.contains(t.productID),
                  t.revocationDate == nil else { continue }
            first = min(first ?? t.purchaseDate, t.purchaseDate)
        }
        since = first
        set(first != nil)
    }

    enum Outcome: Equatable { case purchased, cancelled, pending, failed(String) }

    func buy(tier: Int) async -> Outcome {
        #if DEBUG
        if debugForced {
            set(true)
            since = Date()
            return .purchased
        }
        #endif
        if products.isEmpty { await loadProducts() }
        guard let product = products.first(where: { $0.id == Self.productIDs[tier] }) else {
            return .failed("The App Store isn't answering right now. Try again in a moment.")
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let t) = result else {
                    return .failed("The App Store couldn't confirm that purchase.")
                }
                await t.finish()
                await refresh()
                return .purchased
            case .pending: return .pending
            case .userCancelled: return .cancelled
            @unknown default: return .cancelled
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Restore purchase: asks the App Store to sync (it may ask to sign in).
    func restore() async -> Bool {
        busy = true
        defer { busy = false }
        try? await AppStore.sync()
        await refresh()
        return unlocked
    }

    private func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.cacheKey)
        guard unlocked != on else { return }
        unlocked = on
        Settings.shared.supporterChanged()
        AppIconManager.shared.allowed = on
    }
}

// MARK: - What the unlock covers

// Locked choices stay listed with a lock and fall back to the free one in
// effect (Settings.effectiveTheme and friends), so nothing is hidden and a
// lapsed unlock never strands a setting.

extension ThemeName {
    /// Night is free; the other eleven come with Supporter.
    var supporterOnly: Bool { self != .night }
}

extension Settings.Filter {
    /// The smoothing upscalers; None, LCD grid and RGB subpixels stay free.
    var supporterOnly: Bool { self == .hq4x || self == .xbr }
}

extension Settings.GbPaletteMode {
    /// Custom shades; Default and App theme stay free.
    var supporterOnly: Bool { self == .custom }
    var label: String { self == .default ? "Default" : self == .theme ? "App theme" : "Custom" }
}
