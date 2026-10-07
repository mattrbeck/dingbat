import SwiftUI

/// Cheats (web #cheats-modal): the game's list (enable, name, codes,
/// delete) and an add form. The list is kept as .cht text (CheatStore):
///
///   [x] Infinite health
///   02000000 00000063
///   (blank line)
///
/// Adds are validated by the core before they join; entries an older build
/// stored with errors are disabled and badged "Invalid".
struct CheatsView: View {
    @ObservedObject private var session = GameSession.shared
    @Environment(\.palette) private var palette
    @State private var list: [Cheat] = []
    @State private var name = ""
    @State private var codes = ""
    @State private var error = ""

    struct Cheat: Identifiable {
        let id = UUID()
        var name: String
        var codes: String
        var enabled: Bool
        var error = ""
    }

    var body: some View {
        SheetChrome(title: "Cheats") {
            if session.game == nil {
                SheetHint("No game loaded.")
            } else {
                SheetHint("Game Genie, GameShark and Action Replay codes. Toggle the box to enable a cheat. Codes are saved per game on this device.")
                if !list.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                            row(i, c)
                            if i < list.count - 1 { Rectangle().fill(palette.border).frame(height: 1) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
                    .padding(.bottom, 18)
                }
                SheetSubhead(text: "Add a cheat")
                field {
                    TextField("", text: $name, prompt: Text("Name (optional)").foregroundColor(palette.textFaint))
                        .textInputAutocapitalization(.sentences)
                        .onChange(of: name) { _ in error = "" }
                }
                .padding(.bottom, 8)
                field {
                    ZStack(alignment: .topLeading) {
                        if codes.isEmpty {
                            Text("One code per line")
                                .foregroundColor(palette.textFaint)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $codes)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 72)
                            .onChange(of: codes) { _ in error = "" }
                    }
                }
                Text(session.game?.isGBA == true
                     ? "GameShark/AR v3: XXXXXXXX YYYYYYYY   ·   CodeBreaker: 82XXXXXX YYYY"
                     : "Game Genie: ABC-DEF-GHI    ·    GameShark: 011234C0")
                    .font(.system(size: 12))
                    .foregroundColor(palette.textFaint)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                if !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12.5))
                        .foregroundColor(palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
                Button("Add cheat", action: add).buttonStyle(SheetButtonStyle())
            }
        }
        .onAppear(perform: load)
    }

    private func field<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .font(.system(size: 14))
            .foregroundColor(palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border2, lineWidth: 1))
    }

    private func row(_ i: Int, _ c: Cheat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                list[i].enabled.toggle()
                apply()
            } label: {
                Image(systemName: c.enabled && c.error.isEmpty ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundColor(c.enabled && c.error.isEmpty ? palette.accent : palette.textDim)
            }
            .buttonStyle(.plain)
            .disabled(!c.error.isEmpty)
            .accessibilityLabel("Enable \(c.name.isEmpty ? "cheat" : c.name)")
            .accessibilityValue(c.enabled ? "On" : "Off")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name.isEmpty ? "Cheat \(i + 1)" : c.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(palette.text)
                    if !c.error.isEmpty {
                        Text("Invalid")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(palette.danger)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(palette.danger.opacity(0.14)))
                            .accessibilityHint(c.error)
                    }
                }
                Text(c.codes.replacingOccurrences(of: "\n", with: "  "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(palette.textFaint)
                    .lineLimit(2)
            }
            .opacity(c.error.isEmpty ? 1 : 0.6)
            Spacer(minLength: 0)
            Button {
                list.remove(at: i)
                apply()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(palette.textFaint)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete cheat")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: .cht

    static func serialize(_ list: [Cheat]) -> String {
        var out = ""
        for c in list {
            out += "[\(c.enabled ? "x" : " ")] \(c.name)\n"
            for line in c.codes.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                if !l.isEmpty { out += l + "\n" }
            }
            out += "\n"
        }
        return out
    }

    static func parse(_ text: String) -> [Cheat] {
        var list: [Cheat] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let chars = Array(line)
            if chars.count >= 3 && chars[0] == "[" && chars[2] == "]" {
                list.append(Cheat(name: String(chars[3...]).trimmingCharacters(in: .whitespaces),
                                  codes: "", enabled: chars[1] == "x" || chars[1] == "X"))
            } else if !list.isEmpty {
                let last = list.count - 1
                list[last].codes += (list[last].codes.isEmpty ? "" : "\n") + line
            }
        }
        return list
    }

    /// Probe-parse one cheat alone (the core parses per cheat, so the verdict
    /// matches the full list's). It replaces the core's set: the caller pushes
    /// the real list again afterwards.
    private static func validate(_ c: Cheat) -> String {
        let err = String(cString: dingbat_load_cheats(serialize([c])))
        let prefix = (c.name.isEmpty ? "?" : c.name) + ": "
        return err.hasPrefix(prefix) ? String(err.dropFirst(prefix.count)) : err
    }

    private func load() {
        guard let g = session.game else { return }
        var l = Self.parse(CheatStore.load(for: g))
        for i in l.indices { l[i].error = Self.validate(l[i]) }
        _ = dingbat_load_cheats(Self.serialize(l))
        list = l
    }

    private func apply() {
        guard let g = session.game else { return }
        CheatStore.save(list.isEmpty ? "" : Self.serialize(list), for: g)
    }

    private func add() {
        guard session.game != nil else { error = "Load a game first."; return }
        let text = codes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { error = "Enter at least one code."; return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let candidate = Cheat(name: trimmed.isEmpty ? "Cheat \(list.count + 1)" : trimmed, codes: text, enabled: true)
        let err = Self.validate(candidate)
        if !err.isEmpty {
            // Rejected: the untouched list goes back in, the text stays.
            _ = dingbat_load_cheats(Self.serialize(list))
            error = err
            return
        }
        list.append(candidate)
        name = ""
        codes = ""
        error = ""
        apply()
    }
}
