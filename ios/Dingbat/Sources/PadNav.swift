import SwiftUI

/// A controller drives whatever is on screen (web pollGamepads' contexts):
/// on the home screen, in the in-game menu and in every sheet the d-pad and
/// stick move focus spatially, A presses, B goes back (closes the sheet or
/// the menu; at home, back to the top), Y opens a game's options. At home
/// LB/RB step the system filter, LT/RT the sort, and Start resumes the
/// hero's game. iOS has no controller focus engine outside tvOS, so this is
/// its own: each focusable view registers its frame and what it does under
/// the scope it sits in (`.padFocus`), and the ring shows once a pad has
/// moved it.
final class PadNav: ObservableObject {
    static let shared = PadNav()

    /// The focused item's key ("<scope>|<id>").
    @Published private(set) var focused: String?
    /// A pad has driven the UI: the ring shows.
    @Published private(set) var showing = false

    enum Dir { case up, down, left, right }

    struct Item {
        var scope: String
        var frame: CGRect
        var press: () -> Void
        /// Left/right adjust it (a slider) instead of moving on.
        var adjust: ((Int) -> Void)?
        /// Y (a tile's options).
        var alt: (() -> Void)?
    }

    private var items: [String: Item] = [:]
    /// Per scope: B's first say (Settings goes back to its list), the step
    /// past the last instantiated item (the library grid is lazy), the item
    /// a fresh scope starts on.
    var back: [String: () -> Bool] = [:]
    var edge: [String: (String, Dir) -> String?] = [:]
    var preferred: [String: String] = [:]
    /// Home's shoulder and trigger steps: the system filter, the sort.
    var homeFilter: ((Int) -> Void)?
    var homeSort: ((Int) -> Void)?

    static func key(_ scope: String, _ id: String) -> String { scope + "|" + id }

    func register(_ key: String, _ item: Item) { items[key] = item }
    func unregister(_ key: String) { items[key] = nil }

    /// What the pad drives now; nil in the game itself.
    var scope: String? {
        let m = AppModel.shared
        if let s = m.sheet { return s.id }
        if m.screen == .play && m.session.game != nil { return m.menuOpen ? "menu" : nil }
        return "home"
    }

    /// A new scope opened (a sheet, the menu): its first item, once it has
    /// laid out.
    func scopeChanged() {
        focused = nil
        guard showing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if self?.focused == nil { self?.focusDefault() }
        }
    }

    func focus(_ key: String) {
        showing = true
        focused = key
    }

    /// Touch took over: the ring goes until the pad is used again.
    func hide() { if showing { showing = false } }

    private func live() -> [(String, Item)] {
        guard let scope else { return [] }
        return items.filter { $0.value.scope == scope && $0.value.frame.width > 0 }.map { ($0.key, $0.value) }
    }

    private func focusDefault() {
        guard let scope else { return }
        if let p = preferred[scope], items[Self.key(scope, p)] != nil {
            focused = Self.key(scope, p)
            return
        }
        // Not the sheet's close button: B is already that.
        let all = live()
        let pool = all.count > 1 ? all.filter { !$0.0.hasSuffix("|close") } : all
        focused = pool.min { a, b in
            let ay = (a.1.frame.minY / 8).rounded(), by = (b.1.frame.minY / 8).rounded()
            return ay != by ? ay < by : a.1.frame.minX < b.1.frame.minX
        }?.0
    }

    func move(_ d: Dir) {
        #if DEBUG
        defer {
            let dump = live().map { "\($0.0) \(Int($0.1.frame.minX)),\(Int($0.1.frame.minY)) \(Int($0.1.frame.width))x\(Int($0.1.frame.height))" }
                .sorted().joined(separator: "\n")
            try? ("focused \(focused ?? "-")\n" + dump).write(
                to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("padnav.txt"),
                atomically: true, encoding: .utf8)
        }
        #endif
        let wasShowing = showing
        showing = true
        guard let scope else { return }
        guard wasShowing, let cur = focused, let from = items[cur], from.scope == scope else {
            focusDefault()
            return
        }
        if let adjust = from.adjust, d == .left || d == .right {
            adjust(d == .left ? -1 : 1)
            return
        }
        let f = from.frame
        var best: (String, CGFloat)?
        for (k, it) in live() where k != cur {
            let r = it.frame
            let primary: CGFloat, secondary: CGFloat
            switch d {
            case .up:
                guard r.midY < f.midY - 2, r.maxY <= f.minY + f.height * 0.5 else { continue }
                primary = f.minY - r.maxY; secondary = gap(r.minX, r.maxX, f.minX, f.maxX)
            case .down:
                guard r.midY > f.midY + 2, r.minY >= f.maxY - f.height * 0.5 else { continue }
                primary = r.minY - f.maxY; secondary = gap(r.minX, r.maxX, f.minX, f.maxX)
            case .left:
                guard r.midX < f.midX - 2, r.maxX <= f.minX + f.width * 0.5 else { continue }
                primary = f.minX - r.maxX; secondary = gap(r.minY, r.maxY, f.minY, f.maxY)
            case .right:
                guard r.midX > f.midX + 2, r.minX >= f.maxX - f.width * 0.5 else { continue }
                primary = r.minX - f.maxX; secondary = gap(r.minY, r.maxY, f.minY, f.maxY)
            }
            let score = max(0, primary) + secondary * 3
            if best == nil || score < best!.1 { best = (k, score) }
        }
        if let best {
            focused = best.0
        } else if let next = edge[scope]?(String(cur.dropFirst(scope.count + 1)), d) {
            focused = Self.key(scope, next)
        }
    }

    /// How far apart two spans are on the cross axis (0 when they overlap).
    private func gap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        a1 < b0 ? b0 - a1 : b1 < a0 ? a0 - b1 : 0
    }

    func press() {
        let wasShowing = showing
        showing = true
        guard wasShowing, let k = focused, let it = items[k], it.scope == scope else {
            focusDefault()
            return
        }
        it.press()
    }

    func alt() {
        guard let k = focused, let it = items[k], it.scope == scope else { return }
        it.alt?()
    }

    func goBack() {
        guard let scope else { return }
        if let b = back[scope], b() { return }
        let m = AppModel.shared
        if m.sheet != nil {
            SheetNav.close()
        } else if m.menuOpen {
            m.closeMenu()
        } else {
            showing = true
            focused = nil
            focusDefault()
        }
    }
}

private struct PadScopeKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    /// The scope focusable views below register under (home, menu, a sheet).
    var padScope: String {
        get { self[PadScopeKey.self] }
        set { self[PadScopeKey.self] = newValue }
    }
}

/// Registers a view with PadNav and draws the ring on it while focused.
struct PadFocusable: ViewModifier {
    let id: String
    var radius: CGFloat = 8
    let press: () -> Void
    var adjust: ((Int) -> Void)?
    var alt: (() -> Void)?
    @Environment(\.padScope) private var scope
    @Environment(\.isEnabled) private var enabled
    @Environment(\.palette) private var palette
    @ObservedObject private var nav = PadNav.shared

    private var key: String { PadNav.key(scope, id) }

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius + 3)
                    .stroke(palette.accent, lineWidth: 2.5)
                    .padding(-3)
                    .opacity(nav.showing && nav.focused == key ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { put(g.frame(in: .global)) }
                    .onChange(of: g.frame(in: .global)) { put($0) }
                    .onChange(of: enabled) { _ in put(g.frame(in: .global)) }
            })
            .onDisappear { nav.unregister(key) }
            .id(key)
    }

    private func put(_ frame: CGRect) {
        guard !scope.isEmpty else { return }
        guard enabled else { nav.unregister(key); return }
        nav.register(key, .init(scope: scope, frame: frame, press: press, adjust: adjust, alt: alt))
    }
}

extension View {
    /// Focusable by a controller: `press` is A, `alt` Y, `adjust` left/right.
    func padFocus(_ id: String, radius: CGFloat = 8, alt: (() -> Void)? = nil,
                  adjust: ((Int) -> Void)? = nil, press: @escaping () -> Void) -> some View {
        modifier(PadFocusable(id: id, radius: radius, press: press, adjust: adjust, alt: alt))
    }

    /// Inside a ScrollViewReader: keep the focused item in view.
    func padScrollFollow(_ proxy: ScrollViewProxy) -> some View {
        onReceive(PadNav.shared.$focused) { k in
            guard let k, PadNav.shared.showing else { return }
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(k) }
        }
    }
}

/// A titled button a controller can press: Button(title, action:) plus
/// `.padFocus` with the same action (keyed by its title within the sheet).
struct PadButton: View {
    let title: String
    var id: String?
    let action: () -> Void

    init(_ title: String, id: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.id = id
        self.action = action
    }

    var body: some View {
        Button(title, action: action).padFocus(id ?? "button:" + title, press: action)
    }
}
