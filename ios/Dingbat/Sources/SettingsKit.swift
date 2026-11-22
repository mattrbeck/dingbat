import SwiftUI
import UniformTypeIdentifiers

// The Settings row kit (docs/dev/settings-design.md): every pane is sections
// of these typed rows, drawn by one renderer (PaneList). The web renders the
// same schema with its own skin.

enum SettingsPane: String, Hashable, Identifiable, CaseIterable {
    case appearance, controls, controller, keyboard, audio, channels, play, gb, gba, ds, drive, general
    case webhook, appIcon, acknowledgements

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Display & Appearance"
        case .controls: return "Controls"
        case .controller: return "Controller"
        case .keyboard: return "Keyboard"
        case .audio: return "Audio"
        case .channels: return "Channels"
        case .play: return "Play"
        case .gb: return "Game Boy"
        case .gba: return "Game Boy Advance"
        case .ds: return "Nintendo DS"
        case .drive: return "Google Drive"
        case .general: return "General"
        case .webhook: return "Save Webhook"
        case .appIcon: return "App Icon"
        case .acknowledgements: return "Acknowledgements"
        }
    }

    /// Old section names (deep links, `-sheet settings:<name>`) to panes.
    init?(link: String) {
        switch link {
        case "video": self = .appearance
        default: self.init(rawValue: link)
        }
    }
}

struct SSection: Identifiable {
    var id: String
    var header: String?
    var footer: String?
    var rows: [SRow]

    init(_ header: String? = nil, id: String? = nil, footer: String? = nil, _ rows: [SRow]) {
        self.id = id ?? header ?? rows.first?.id ?? UUID().uuidString
        self.header = header
        self.footer = footer
        self.rows = rows
    }
}

struct Badge {
    var text: String
    var warn = false
    static let highlyExperimental = Badge(text: "Highly experimental", warn: true)
    static let experimental = Badge(text: "Experimental", warn: true)
}

/// A colored icon tile (Settings' root rows).
struct Tile {
    var color: UInt32
    var glyph: Glyph
    enum Glyph { case symbol(String), gameBoy, gba, ds }
}

struct SRow: Identifiable {
    let id: String
    let kind: Kind

    enum Kind {
        case nav(label: String, value: String?, tile: Tile?, image: String?, badge: Badge?, locked: Supporter.Perk?, to: SettingsPane)
        case toggle(label: String, isOn: Binding<Bool>, badge: Badge?, disabled: Bool, locked: Supporter.Perk?)
        /// `spoken`: what VoiceOver says for each option, when its label is terse ("1" → "1 frame").
        case segmented(label: String, options: [String], spoken: [String]?, selection: Binding<Int>)
        case menu(label: String, options: [MenuOption], selection: Binding<Int>)
        case check(label: String, selected: Bool, swatch: [UInt32]?, disabled: Bool, locked: Supporter.Perk?, action: () -> Void)
        case file(label: String, slot: FileSlot)
        case button(label: String, destructive: Bool, confirm: String?, message: String?, disabled: Bool, action: () -> Void)
        case info(label: String, value: String, keycap: Bool)
        case custom(AnyView)
    }

    struct MenuOption {
        var label: String
        var locked: Supporter.Perk?
        init(_ label: String, locked: Supporter.Perk? = nil) {
            self.label = label
            self.locked = locked
        }
    }

    static func nav(_ label: String, value: String? = nil, tile: Tile? = nil, image: String? = nil, badge: Badge? = nil,
                    locked: Supporter.Perk? = nil, to: SettingsPane) -> SRow {
        SRow(id: "nav:" + label, kind: .nav(label: label, value: value, tile: tile, image: image, badge: badge, locked: locked, to: to))
    }
    static func toggle(_ label: String, _ isOn: Binding<Bool>, badge: Badge? = nil, disabled: Bool = false,
                       locked: Supporter.Perk? = nil) -> SRow {
        SRow(id: "toggle:" + label, kind: .toggle(label: label, isOn: isOn, badge: badge, disabled: disabled, locked: locked))
    }
    static func segmented(_ label: String, _ options: [String], _ selection: Binding<Int>, spoken: [String]? = nil) -> SRow {
        SRow(id: "seg:" + label, kind: .segmented(label: label, options: options, spoken: spoken, selection: selection))
    }
    static func menu(_ label: String, _ options: [MenuOption], _ selection: Binding<Int>) -> SRow {
        SRow(id: "menu:" + label, kind: .menu(label: label, options: options, selection: selection))
    }
    static func check(_ label: String, selected: Bool, swatch: [UInt32]? = nil, disabled: Bool = false,
                      locked: Supporter.Perk? = nil, action: @escaping () -> Void) -> SRow {
        SRow(id: "check:" + label, kind: .check(label: label, selected: selected, swatch: swatch, disabled: disabled, locked: locked, action: action))
    }
    static func file(_ label: String, _ slot: FileSlot) -> SRow {
        SRow(id: "file:" + label, kind: .file(label: label, slot: slot))
    }
    static func button(_ label: String, destructive: Bool = false, confirm: String? = nil, message: String? = nil,
                       disabled: Bool = false, action: @escaping () -> Void) -> SRow {
        SRow(id: "button:" + label, kind: .button(label: label, destructive: destructive, confirm: confirm, message: message,
                                                  disabled: disabled, action: action))
    }
    static func info(_ label: String, _ value: String, keycap: Bool = false) -> SRow {
        SRow(id: "info:" + label, kind: .info(label: label, value: value, keycap: keycap))
    }
    static func custom<V: View>(_ id: String, _ view: V) -> SRow {
        SRow(id: id, kind: .custom(AnyView(view)))
    }
}

/// A file the user supplies (BIOS, boot ROM): "None" until chosen; the row's
/// menu chooses or removes it. `validate` returns why a file is refused.
struct FileSlot {
    var url: URL
    var noneLabel = "None"
    var validate: (Data) -> String? = { _ in nil }
    var changed: () -> Void = {}
}

// MARK: - The renderer

/// One pane: grouped sections of rows on the theme's colors.
struct PaneList: View {
    let sections: [SSection]
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(sections) { s in
                    Section {
                        ForEach(s.rows) { r in
                            RowView(row: r)
                                .listRowBackground(palette.surface2)
                                .listRowSeparatorTint(palette.border)
                        }
                    } header: {
                        if let h = s.header {
                            Text(h).font(.system(size: 13)).foregroundColor(palette.textFaint).textCase(.uppercase)
                        }
                    } footer: {
                        if let f = s.footer {
                            Text(f).font(.system(size: 13)).foregroundColor(palette.textFaint)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(palette.bg.ignoresSafeArea())
            .padScrollFollow(proxy)
        }
    }
}

private struct RowView: View {
    let row: SRow
    @Environment(\.palette) private var palette

    var body: some View {
        switch row.kind {
        case let .nav(label, value, tile, image, badge, locked, to):
            if let locked {
                Button { Supporter.shared.open(locked) } label: {
                    RowLine(label: label, tile: tile, image: image, badge: badge) {
                        if let value { ValueText(value) }
                        LockGlyph()
                    }
                }
                .buttonStyle(.plain)
                .padFocus(row.id) { Supporter.shared.open(locked) }
            } else {
                NavigationLink(value: to) {
                    RowLine(label: label, tile: tile, image: image, badge: badge) {
                        if let value { ValueText(value) }
                    }
                }
                .padFocus(row.id) { SettingsNav.shared.push(to) }
            }

        case let .toggle(label, isOn, badge, disabled, locked):
            if let locked {
                Button { Supporter.shared.open(locked) } label: {
                    RowLine(label: label, badge: badge) { LockGlyph() }
                }
                .buttonStyle(.plain)
                .padFocus(row.id) { Supporter.shared.open(locked) }
            } else {
                Toggle(isOn: isOn) { RowLine(label: label, badge: badge) { EmptyView() } }
                    .tint(palette.accent)
                    .disabled(disabled)
                    .padFocus(row.id) { isOn.wrappedValue.toggle() }
            }

        case let .segmented(label, options, spoken, selection):
            VStack(alignment: .leading, spacing: 9) {
                Text(label).font(.body).foregroundColor(palette.text)
                let picker = Picker(label, selection: selection) {
                    ForEach(options.indices, id: \.self) { i in Text(options[i]).tag(i) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let spoken {
                    // A segmented picker drops a label put on its segments:
                    // VoiceOver gets a button a segment, each over its own.
                    picker.accessibilityRepresentation {
                        HStack(spacing: 0) {
                            ForEach(options.indices, id: \.self) { i in
                                Button(spoken[i]) { selection.wrappedValue = i }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .accessibilityAddTraits(selection.wrappedValue == i ? .isSelected : [])
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(label)
                    }
                } else {
                    picker
                }
            }
            .padding(.vertical, 6)
            .padFocus(row.id, adjust: { d in
                selection.wrappedValue = max(0, min(options.count - 1, selection.wrappedValue + d))
            }) { selection.wrappedValue = (selection.wrappedValue + 1) % options.count }

        case let .menu(label, options, selection):
            Menu {
                ForEach(options.indices, id: \.self) { i in
                    let o = options[i]
                    Button {
                        if let p = o.locked { Supporter.shared.open(p) } else { selection.wrappedValue = i }
                    } label: {
                        if o.locked != nil { Label(o.label, systemImage: "lock.fill") }
                        else if i == selection.wrappedValue { Label(o.label, systemImage: "checkmark") }
                        else { Text(o.label) }
                    }
                }
            } label: {
                RowLine(label: label) {
                    ValueText(options.indices.contains(selection.wrappedValue) ? options[selection.wrappedValue].label : "")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 13, weight: .medium)).foregroundColor(palette.textFaint)
                }
            }
            .padFocus(row.id, adjust: { d in
                var i = selection.wrappedValue + d
                while options.indices.contains(i), options[i].locked != nil { i += d }
                if options.indices.contains(i) { selection.wrappedValue = i }
            }) {
                var i = (selection.wrappedValue + 1) % options.count
                while options[i].locked != nil, i != selection.wrappedValue { i = (i + 1) % options.count }
                selection.wrappedValue = i
            }

        case let .check(label, selected, swatch, disabled, locked, action):
            let act = { if let locked { Supporter.shared.open(locked) } else { action() } }
            Button(action: act) {
                RowLine(label: label) {
                    if let swatch { Swatch(colors: swatch) }
                    ZStack {
                        if locked != nil { LockGlyph() }
                        else if selected { Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold)).foregroundColor(palette.accent) }
                    }
                    .frame(width: 18, alignment: .trailing)
                }
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .padFocus(row.id, press: act)

        case let .file(label, slot):
            FileRow(id: row.id, label: label, slot: slot)

        case let .button(label, destructive, confirm, message, disabled, action):
            ActionRow(id: row.id, label: label, destructive: destructive, confirm: confirm, message: message, action: action)
                .disabled(disabled)

        case let .info(label, value, keycap):
            RowLine(label: label) {
                if keycap {
                    Text(value)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(palette.text)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface3))
                } else {
                    ValueText(value)
                }
            }
            .accessibilityElement(children: .combine)

        case let .custom(view):
            view
        }
    }
}

/// Label (with an optional tile, image and badge) and trailing content.
struct RowLine<Trailing: View>: View {
    let label: String
    var tile: Tile?
    var image: String?
    var badge: Badge?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            if let tile { TileView(tile: tile) }
            if let image {
                Image(image).interpolation(.none).resizable().frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 8) {
                Text(label).foregroundColor(palette.text)
                if let badge { BadgeView(badge: badge) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 30)
        .contentShape(Rectangle())
    }
}

struct ValueText: View {
    let text: String
    @Environment(\.palette) private var palette
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).foregroundColor(palette.textFaint).lineLimit(1) }
}

struct LockGlyph: View {
    @Environment(\.palette) private var palette
    var body: some View {
        Image(systemName: "lock.fill").font(.system(size: 14)).foregroundColor(palette.textFaint)
            .accessibilityLabel("Supporter")
    }
}

struct BadgeView: View {
    let badge: Badge
    @Environment(\.palette) private var palette
    var body: some View {
        Text(badge.text)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(badge.warn ? Color(hex: 0xFFC37A) : palette.textDim)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(badge.warn ? Color(hex: 0xFFB04D).opacity(0.16) : palette.surface3))
    }
}

struct Swatch: View {
    let colors: [UInt32]
    @Environment(\.palette) private var palette
    var body: some View {
        HStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { i in Rectangle().fill(Color(hex: colors[i])).frame(width: 14, height: 22) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct TileView: View {
    let tile: Tile
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(hex: tile.color))
            .frame(width: 30, height: 30)
            .overlay(glyph.foregroundColor(.white))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        switch tile.glyph {
        case .symbol(let name): Image(systemName: name).font(.system(size: 15, weight: .semibold))
        case .gameBoy: DeviceGlyph(kind: .gameBoy).stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)).frame(width: 19, height: 19)
        case .gba: DeviceGlyph(kind: .gba).stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)).frame(width: 19, height: 19)
        case .ds: DeviceGlyph(kind: .ds).stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)).frame(width: 19, height: 19)
        }
    }
}

/// The handhelds' outlines on a 24-unit grid (no SF Symbol draws them).
struct DeviceGlyph: Shape {
    enum Kind { case gameBoy, gba, ds }
    let kind: Kind

    func path(in r: CGRect) -> Path {
        let k = r.width / 24
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: r.minX + x * k, y: r.minY + y * k, width: w * k, height: h * k), cornerRadius: c * k)
        }
        func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX + x0 * k, y: r.minY + y0 * k))
            p.addLine(to: CGPoint(x: r.minX + x1 * k, y: r.minY + y1 * k))
            return p
        }
        var p = Path()
        switch kind {
        case .gameBoy:
            p.addPath(rect(5, 2, 14, 20, 2)); p.addPath(rect(8, 5, 8, 6, 0.5))
            p.addPath(line(8, 16, 11, 16)); p.addPath(line(9.5, 14.5, 9.5, 17.5)); p.addPath(rect(15, 15.5, 1, 1, 0.5))
        case .gba:
            p.addPath(rect(1, 7, 22, 10, 2)); p.addPath(rect(8, 9, 8, 6, 0.5))
            p.addPath(line(3.5, 12, 6.5, 12)); p.addPath(line(5, 10.5, 5, 13.5)); p.addPath(rect(18.5, 11.5, 1, 1, 0.5))
        case .ds:
            p.addPath(rect(5, 2, 14, 9, 1)); p.addPath(rect(5, 13, 14, 9, 1))
            p.addPath(rect(8, 4.5, 8, 4, 0.5)); p.addPath(rect(8, 15.5, 8, 4, 0.5))
        }
        return p
    }
}

/// A file slot: its name or "None"; the menu chooses or removes it.
private struct FileRow: View {
    let id: String
    let label: String
    let slot: FileSlot
    @Environment(\.palette) private var palette
    @State private var picking = false
    @State private var gen = 0
    @State private var failed: String?

    private var nameURL: URL { slot.url.appendingPathExtension("name") }
    private var present: Bool { _ = gen; return FileManager.default.fileExists(atPath: slot.url.path) }
    private var value: String {
        guard present else { return slot.noneLabel }
        if let n = try? String(contentsOf: nameURL, encoding: .utf8), !n.isEmpty { return n }
        return slot.url.lastPathComponent
    }

    var body: some View {
        Menu {
            Button("Choose File…") { picking = true }
            if present {
                Button("Remove", role: .destructive, action: remove)
            }
        } label: {
            RowLine(label: label) {
                ValueText(value)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 13, weight: .medium)).foregroundColor(palette.textFaint)
            }
        }
        .padFocus(id, alt: present ? remove : nil) { picking = true }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
            guard case .success(let src) = result else { return }
            guard let data = SheetFiles.read(src), !data.isEmpty else {
                failed = "Couldn't read that file."
                return
            }
            if let why = slot.validate(data) {
                failed = why
                return
            }
            do {
                try RomLibrary.ensureDir(slot.url.deletingLastPathComponent())
                try data.write(to: slot.url, options: .atomic)
                try? src.lastPathComponent.write(to: nameURL, atomically: true, encoding: .utf8)
            } catch {
                failed = "Couldn't keep that file: \(error.localizedDescription)"
            }
            gen += 1
            slot.changed()
        }
        .alert(failed ?? "", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func remove() {
        try? FileManager.default.removeItem(at: slot.url)
        try? FileManager.default.removeItem(at: nameURL)
        gen += 1
        slot.changed()
    }
}

/// A text-colored action; a destructive one asks first.
private struct ActionRow: View {
    let id: String
    let label: String
    let destructive: Bool
    let confirm: String?
    let message: String?
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled
    @State private var asking = false

    var body: some View {
        Button(action: tap) {
            Text(label)
                .foregroundColor(destructive ? palette.danger : palette.accent)
                .opacity(enabled ? 1 : 0.45)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padFocus(id, press: tap)
        .confirmationDialog(confirm ?? label, isPresented: $asking, titleVisibility: .visible) {
            Button(label, role: destructive ? .destructive : nil, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let message { Text(message) }
        }
    }

    private func tap() {
        if confirm != nil { asking = true } else { action() }
    }
}

/// Settings' navigation, for a controller (A on a row pushes; B pops) and
/// for the thank-you rows that open a pane under the Supporter sheet.
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var path: [SettingsPane] = [] {
        didSet { moveFocus(from: oldValue.count) }
    }
    @Published var selection: SettingsPane? = .appearance
    /// Sidebar + detail (iPad, wide windows): the top panes are a selection.
    /// Learnt after a deep link may have pushed its pane: it moves to the sidebar.
    var wide = false {
        didSet {
            guard wide, !oldValue, let first = path.first, Self.top.contains(first) else { return }
            select(first, then: Array(path.dropFirst()))
        }
    }

    /// A sidebar pane, and a sub-pane over it: a new selection resets the
    /// detail's stack, so the sub-pane goes on after it has.
    private func select(_ top: SettingsPane, then rest: [SettingsPane]) {
        path = []
        selection = top
        guard !rest.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.path = rest }
    }
    /// The focused row each pushed pane was opened from, for B to return to.
    private var openedFrom: [String?] = []

    /// The pane a controller drives: the sidebar never stacks, so on a wide
    /// screen it stays untagged and in reach beside the detail.
    @MainActor var shownPane: String {
        if Supporter.shared.sheetUp { return "supporter" }
        if let p = path.last { return "\(p)" }
        return wide ? "\(selection ?? .appearance)" : "root"
    }

    private func moveFocus(from old: Int) {
        let pad = PadNav.shared
        if path.count > old {
            openedFrom += [pad.focused] + Array(repeating: nil, count: path.count - old - 1)
            pad.scopeChanged()
        } else if path.count < old {
            let back = openedFrom.count > path.count ? openedFrom[path.count] : nil
            openedFrom = Array(openedFrom.prefix(path.count))
            pad.refocus(back)
        }
    }

    /// The pane a sub-pane is pushed from.
    static func parent(_ p: SettingsPane) -> SettingsPane? {
        switch p {
        case .appIcon: return .appearance
        case .controller, .keyboard: return .controls
        case .channels: return .audio
        case .webhook, .acknowledgements: return .general
        default: return nil
        }
    }

    /// A row pressed with a controller.
    func push(_ p: SettingsPane) {
        if wide && Self.top.contains(p) {
            selection = p
            path = []
        } else {
            path.append(p)
        }
    }

    /// Straight to a pane from anywhere (a deep link, the thank-you rows).
    func open(_ p: SettingsPane) {
        let top = Self.parent(p) ?? p
        if wide {
            select(top, then: top == p ? [] : [p])
        } else {
            path = top == p ? [p] : [top, p]
        }
    }

    /// B: one level up; false at the top (the sheet closes).
    func pop() -> Bool {
        if !path.isEmpty {
            path.removeLast()
            return true
        }
        // Beside the sidebar: back to the pane's row there before closing.
        let pad = PadNav.shared
        if wide, let sel = selection, let f = pad.focused, pad.pane(of: f) == "\(sel)" {
            pad.focus(PadNav.key(AppModel.Sheet.settings(section: nil).id, "nav:" + sel.title))
            return true
        }
        return false
    }
}
