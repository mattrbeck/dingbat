// The shared modal look (web .modal, styles.css "Modals"): a surface-1
// panel with a 17pt title and a close ×, rows of label + helper text with a
// control beside them, uppercase subheads with a rule, and the web's button
// family — plain, primary (accent), ghost, danger, and the two-tap confirm
// that arms red. Every sheet in StubsSheets' place is built from these.
import SwiftUI

enum SheetNav {
    /// Close whatever sheet is up; RootView resumes the game on dismiss.
    static func close() { AppModel.shared.sheet = nil }
}

/// Title bar + scrolling body on the modal surface. `fit`: the sheet is as
/// tall as its content (web: a short modal is a small box, not a page).
struct SheetChrome<Content: View>: View {
    let title: String
    var scroll = true
    var fit = false
    var onClose: () -> Void = SheetNav.close
    @ViewBuilder var content: () -> Content
    @Environment(\.palette) private var palette
    @State private var headerH: CGFloat = 0
    @State private var bodyH: CGFloat = 0

    var body: some View {
        let chrome = VStack(spacing: 0) {
            SheetHeader(title: title, onClose: onClose)
                .background(GeometryReader { g in
                    Color.clear.onAppear { headerH = g.size.height }
                        .onChange(of: g.size.height) { headerH = $0 }
                })
            if scroll {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) { content() }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .padding(.top, 4)
                            .padding(.bottom, 28)
                            .background(GeometryReader { g in
                                Color.clear.onAppear { bodyH = g.size.height }
                                    .onChange(of: g.size.height) { bodyH = $0 }
                            })
                    }
                    .padScrollFollow(proxy)
                }
            } else {
                content()
            }
        }
        .foregroundColor(palette.text)
        .background(palette.surface1.ignoresSafeArea())
        .sheetToasts()
        if fit && scroll && bodyH > 0 {
            chrome.presentationDetents([.height(headerH + bodyH + 8)])
        } else {
            chrome
        }
    }
}

extension View {
    /// The toast stack again, over the sheet: the one on the root view sits
    /// underneath it ("Saved to slot 2" must show while Save States is up).
    func sheetToasts() -> some View {
        overlay(ToastStack().environmentObject(AppModel.shared))
    }
}

/// web .modal h2 + .modal-close; `leading` holds the settings back chevron.
struct SheetHeader<Leading: View, Trailing: View>: View {
    let title: String
    var onClose: (() -> Void)?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            leading()
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(palette.text)
                .lineLimit(2)
            Spacer(minLength: 8)
            trailing()
            if let onClose { SheetCloseButton(action: onClose) }
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }
}

extension SheetHeader where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, onClose: (() -> Void)?) {
        self.init(title: title, onClose: onClose, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

struct SheetCloseButton: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(palette.textFaint)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .padFocus("close", press: action)
    }
}

// MARK: buttons

/// web .button / .button-primary / .button-ghost / .button-danger, and the
/// armed state of a two-tap confirm (.saves-reset-btn.armed et al.).
enum SheetButtonKind { case normal, primary, ghost, danger, armed }

struct SheetButtonStyle: ButtonStyle {
    var kind: SheetButtonKind = .normal
    var small = true
    var fill = false
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: small ? 12.5 : 13.5, weight: kind == .primary || kind == .armed ? .semibold : .medium))
            .foregroundColor(ink)
            .lineLimit(1)
            .padding(.horizontal, small ? 12 : 16)
            .padding(.vertical, small ? 7 : 9)
            .frame(maxWidth: fill ? .infinity : nil, minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(background(pressed)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .offset(y: pressed ? 1 : 0)
            .contentShape(Rectangle())
    }

    private var ink: Color {
        guard enabled else { return palette.textFaint }
        switch kind {
        case .normal: return palette.text
        case .primary: return palette.accentInk
        case .ghost: return palette.textDim
        case .danger: return palette.danger
        case .armed: return .white
        }
    }

    private func background(_ pressed: Bool) -> LinearGradient {
        func grad(_ a: Color, _ b: Color) -> LinearGradient {
            LinearGradient(colors: [a, b], startPoint: .top, endPoint: .bottom)
        }
        if !enabled { return grad(palette.surface3, palette.surface2) }
        switch kind {
        case .normal, .danger:
            return pressed ? grad(palette.surfaceHover, palette.surface3) : grad(palette.surface3, palette.surface2)
        case .primary:
            return pressed ? grad(palette.accentHi, palette.accent2) : grad(palette.accent2, palette.accent)
        case .ghost:
            return grad(.clear, .clear)
        case .armed:
            return grad(palette.dangerHi, palette.danger)
        }
    }

    private var border: Color {
        guard enabled else { return palette.border2 }
        switch kind {
        case .normal: return palette.border2
        case .primary: return palette.accent.opacity(0.6)
        case .ghost: return palette.border
        case .danger: return palette.danger.opacity(0.4)
        case .armed: return palette.danger.opacity(0.6)
        }
    }
}

/// Two-step inline confirm (web makeConfirmButton): the first tap arms it
/// (red, `confirmLabel`), a second within 3.5 s runs `action`.
struct SheetConfirmButton: View {
    let label: String
    var confirmLabel = "Confirm?"
    var kind: SheetButtonKind = .normal
    var fill = false
    let action: () -> Void
    @State private var armed = false
    @State private var armGen = 0

    var body: some View {
        Button(armed ? confirmLabel : label, action: tap)
            .buttonStyle(SheetButtonStyle(kind: armed ? .armed : kind, fill: fill))
            .padFocus("confirm:" + label, press: tap)
    }

    private func tap() {
        if !armed {
            armed = true
            armGen += 1
            let gen = armGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                if armGen == gen { armed = false }
            }
            return
        }
        armed = false
        action()
    }
}

// MARK: rows

/// web .modal-row-label + .modal-toggle-sub.
struct SheetLabel: View {
    let label: String
    var sub: String?
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundColor(palette.text)
            if let sub, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundColor(palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(enabled ? 1 : 0.45)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label and helper text with a control on the right (web .modal-toggle-row).
struct SheetRow<Control: View>: View {
    let label: String
    var sub: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            SheetLabel(label: label, sub: sub)
            control()
        }
        .padding(.bottom, 18)
    }
}

/// A row whose control is wide (chips, a picker): beside the label when it
/// fits, under it when not; the helper text below (web .row-flow).
struct SheetFlowRow<Control: View>: View {
    let label: String
    var sub: String?
    @ViewBuilder var control: () -> Control
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    labelText.fixedSize()
                    Spacer(minLength: 8)
                    control().fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    labelText
                    control()
                }
            }
            if let sub, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundColor(palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(enabled ? 1 : 0.45)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 18)
    }

    private var labelText: some View {
        Text(label)
            .font(.system(size: 14.5, weight: .medium))
            .foregroundColor(palette.text)
            .opacity(enabled ? 1 : 0.45)
    }
}

struct SheetToggleRow: View {
    let label: String
    var sub: String?
    @Binding var isOn: Bool

    var body: some View {
        SheetRow(label: label, sub: sub) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SheetSwitchStyle())
                .accessibilityLabel(label)
                .padFocus("toggle:" + label, radius: 13) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { isOn.toggle() }
                }
        }
    }
}

/// web .switch: 42x24 track, accent gradient when on.
struct SheetSwitchStyle: ToggleStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? AnyShapeStyle(LinearGradient(colors: [palette.accent2, palette.accent],
                                                        startPoint: .top, endPoint: .bottom))
                         : AnyShapeStyle(palette.surface3))
                .overlay(Capsule().stroke(on ? palette.accent.opacity(0.6) : palette.border2, lineWidth: 1))
                .frame(width: 44, height: 26)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                .frame(width: 20, height: 20)
                .padding(3)
        }
        .frame(width: 44, height: 26)
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { configuration.isOn.toggle() }
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// web .modal-subhead: small caps over a rule.
struct SheetSubhead: View {
    let text: String
    var rule = true
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rule { Rectangle().fill(palette.border).frame(height: 1).padding(.bottom, 14) }
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundColor(palette.textFaint)
        }
        .padding(.top, rule ? 2 : 4)
        .padding(.bottom, 12)
    }
}

/// web .modal-hint.
struct SheetHint: View {
    let text: String
    var color: Color?
    @Environment(\.palette) private var palette

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(color ?? palette.textDim)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 14)
    }
}

/// web .choice-chip.
struct SheetChip<Leading: View>: View {
    let label: String
    let selected: Bool
    /// Stretch to the width it is given (a grid cell).
    var fill = false
    let action: () -> Void
    @ViewBuilder var leading: () -> Leading
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                leading()
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: fill ? .infinity : nil, minHeight: fill ? 26 : nil, alignment: .leading)
            .foregroundColor(selected ? palette.text : palette.textDim)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? palette.accent.opacity(0.07) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? palette.accent.opacity(0.55) : palette.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padFocus("chip:" + padID, press: action)
    }

    @State private var padID = UUID().uuidString
}

extension SheetChip where Leading == EmptyView {
    init(label: String, selected: Bool, action: @escaping () -> Void) {
        self.init(label: label, selected: selected, fill: false, action: action, leading: { EmptyView() })
    }
}

/// A radiogroup of chips over any value (web .chip-row).
struct SheetChipPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { opt in
                SheetChip(label: opt.1, selected: selection == opt.0) { selection = opt.0 }
            }
        }
    }
}

/// web .kb-select: a native menu styled as the web's select.
struct SheetSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var accessibilityLabel = ""
    @Environment(\.palette) private var palette

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { opt in
                Button {
                    selection = opt.0
                } label: {
                    if opt.0 == selection { Label(opt.1, systemImage: "checkmark") } else { Text(opt.1) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.0 == selection }?.1 ?? "")
                    .font(.system(size: 13.5))
                    .foregroundColor(palette.text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(palette.textDim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border2, lineWidth: 1))
        }
        .accessibilityLabel(accessibilityLabel)
        // A pad cannot open the menu: A steps to the next option.
        .padFocus("select:" + padID) {
            let i = options.firstIndex { $0.0 == selection } ?? -1
            if !options.isEmpty { selection = options[(i + 1) % options.count].0 }
        }
    }

    @State private var padID = UUID().uuidString
}

/// web .settings-disclosure: a folding section header.
struct SheetDisclosure: View {
    let title: String
    @Binding var open: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(palette.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(palette.textDim)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padFocus("disclosure:" + title) { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } }
        .padding(.bottom, open ? 6 : 12)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

/// web .rewind-warn: a callout above the confirm.
struct SheetWarning: View {
    let text: String
    var severe = false
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(severe ? palette.dangerHi : palette.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(severe ? palette.danger.opacity(0.14) : palette.accent.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(severe ? palette.danger.opacity(0.5) : palette.accent.opacity(0.35), lineWidth: 1))
    }
}

/// A modal confirm (web confirm()) as a SwiftUI alert payload.
struct SheetAsk: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirm: String
    var destructive = false
    let run: () -> Void
}

extension View {
    func sheetAsk(_ ask: Binding<SheetAsk?>) -> some View {
        alert(ask.wrappedValue?.title ?? "", isPresented: Binding(
            get: { ask.wrappedValue != nil },
            set: { if !$0 { ask.wrappedValue = nil } }
        ), presenting: ask.wrappedValue) { a in
            Button(a.confirm, role: a.destructive ? .destructive : nil) { a.run() }
            Button("Cancel", role: .cancel) {}
        } message: { a in
            Text(a.message)
        }
    }
}

// MARK: shared helpers

enum SheetFiles {
    /// A temporary copy named for sharing (the share sheet shows its name).
    static func temp(_ data: Data, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Read a picked file (security-scoped URL from fileImporter).
    static func read(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }
}

/// "8.4s" / "2m 14s" from tenths of a second (web fmtDuration).
func fmtDuration(tenths: Int) -> String {
    let s = Double(tenths) / 10
    if s < 60 { return s < 10 ? String(format: "%.1fs", s) : "\(Int(s.rounded()))s" }
    let m = Int(s / 60)
    return "\(m)m \(Int((s - Double(m) * 60).rounded()))s"
}
