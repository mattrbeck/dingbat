import SwiftUI

/// Report a Bug (web #report-modal): a title, a description and a save
/// state from the moment it went wrong (scrubbed back through the rewind
/// ring), as one .json file handed to the share sheet. Nothing is sent
/// anywhere, and the ROM is never included. Opened from FaultView, it is
/// filled in from the fault and carries its replay instead: where the game
/// last started fresh (power-on, or the state it last loaded) and every
/// frame's buttons from there to the stop (dingbat_fault_report_size), which
/// re-run the player's frames exactly up to the faulting one
/// (tools/replay_report.nim).
struct ReportBugView: View {
    @ObservedObject private var session = GameSession.shared
    @ObservedObject private var settings = Settings.shared
    @Environment(\.palette) private var palette
    @State private var title = ""
    @State private var desc = ""
    @State private var samples = 0
    @State private var thumbs: [UIImage] = []
    @State private var live: UIImage?
    /// 0..samples; samples = now.
    @State private var slider = 0.0
    /// The core is faulted: the fault's report (see the type's comment).
    @State private var fault = false
    @State private var withReplay = true
    /// What the replay covers, for its row: "since power-on, 33 s".
    @State private var replayWhat = ""

    var body: some View {
        SheetChrome(title: "Report a Bug") {
            SheetHint(fault
                      ? "Filled in from the error. Add anything you noticed, then share the file. Nothing leaves your phone until you do."
                      : "Describe what went wrong. You can attach a save state from the moment it happened — scrub the timeline below to find it. Nothing is sent anywhere; this makes a report file you can share.")
            label("Title")
            box {
                TextField("", text: $title, prompt: Text("Short summary").foregroundColor(palette.textFaint))
                    .onChange(of: title) { t in if t.count > 120 { title = String(t.prefix(120)) } }
            }
            .padding(.bottom, 12)
            label(fault ? "What were you doing? (optional)" : "Description")
            box {
                ZStack(alignment: .topLeading) {
                    if desc.isEmpty {
                        Text("What happened, and what did you expect?")
                            .foregroundColor(palette.textFaint)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $desc)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
                }
            }
            .padding(.bottom, 14)
            if fault { faultBox } else { scrubBox }
            HStack(spacing: 10) {
                Spacer()
                PadButton("Cancel") { SheetNav.close() }.buttonStyle(SheetButtonStyle())
                Button(fault ? "Share report" : "Download report", action: download)
                    .buttonStyle(SheetButtonStyle(kind: .primary))
                    .disabled(session.game == nil)
            }
            .padding(.top, 16)
        }
        .onAppear(perform: load)
    }

    private var back: Int { samples - Int(slider.rounded()) }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(palette.textDim)
            .padding(.bottom, 6)
    }

    private func box<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .font(.system(size: 14))
            .foregroundColor(palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border2, lineWidth: 1))
    }

    private var whenText: String {
        back == 0 ? "now"
            : String(format: "%.1fs ago", Double(dingbat_rewind_scrub_seconds_ago(Int32(back - 1))) / 10)
    }

    private var scrubBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Attach a moment")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(palette.textDim)
                Spacer()
                Text(whenText)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(palette.accent)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(palette.stage)
                if let img = back == 0 ? live : (back - 1 < thumbs.count ? thumbs[back - 1] : nil) {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .frame(maxWidth: 220)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
            if settings.rewind && samples > 0 {
                Slider(value: $slider, in: 0...Double(samples), step: 1)
                    .tint(palette.accent)
                    .accessibilityLabel("Rewind timeline")
                    .accessibilityValue(whenText)
            } else {
                Text(settings.rewind
                     ? "Slide left to go further back in time. Enable Rewind in Settings to capture a longer timeline."
                     : "Rewind is off, so only this moment can be attached. Turn Rewind on in Settings to pick an earlier one.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(palette.surface2.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.border, lineWidth: 1))
        .opacity(session.game == nil ? 0.45 : 1)
    }

    /// What a fault's report carries; the replay's two parts can be left out.
    private var faultBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("In the report")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(palette.textDim)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
            if !replayWhat.isEmpty {
                faultToggle("A replay of this session", replayWhat, $withReplay)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The error, settings and device").font(.system(size: 14.5, weight: .medium))
                    Text(String(cString: dingbat_fault_message()))
                        .font(.system(size: 12.5))
                        .foregroundColor(palette.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "lock")
                    .foregroundColor(palette.textFaint)
                    .accessibilityLabel("Always included")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 58)
            .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
            Text("The game itself (the ROM) is never included.")
                .font(.system(size: 12))
                .foregroundColor(palette.textFaint)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
        }
        .background(RoundedRectangle(cornerRadius: 11).fill(palette.surface2.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.border, lineWidth: 1))
    }

    private func faultToggle(_ title: String, _ sub: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14.5, weight: .medium))
                Text(sub).font(.system(size: 12.5)).foregroundColor(palette.textDim)
            }
        }
        .tint(palette.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 58)
        .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private func load() {
        fault = dingbat_fault() != 0
        if fault {
            replayWhat = ""
            let size = Int(dingbat_fault_report_size(Int32(FaultView.backSeconds)))
            if size >= 0 {
                let secs = Double(dingbat_fault_report_input_count()) / 59.73
                let len = secs >= 90 ? String(format: "%.0f min", secs / 60) : String(format: "%.0f s", secs)
                let from = dingbat_fault_report_power_on() != 0 ? "power-on" : "where it last loaded a state"
                replayWhat = "From \(from) to the stop (\(len)): the start and every button you pressed"
            }
            if title.isEmpty {
                let frame = Int(dingbat_fault_frame())
                let at = frame >= 0 ? String(format: " at %.1f s", Double(frame) / 59.73) : ""
                title = "\(session.game?.name ?? "Game") stopped: internal error\(at)"
            }
            return
        }
        live = session.currentImage()
        samples = 0
        thumbs = []
        if session.game != nil && settings.rewind {
            let n = Int(dingbat_rewind_scrub_generate(48))
            if n > 0, let base = dingbat_rewind_scrub_thumbs() {
                let w = Int(dingbat_rewind_scrub_thumb_w()), h = Int(dingbat_rewind_scrub_thumb_h())
                let shades = GameSession.pictureShades()
                thumbs = (0..<n).compactMap { GameSession.bgr555Image(base + $0 * w * h * 2, width: w, height: h, shades: shades) }
                samples = thumbs.count
            }
        }
        slider = Double(samples)
    }

    /// web logContext, for this app: build, system, device, screen.
    static func diagnostics() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let d = UIDevice.current
        let s = UIScreen.main
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "dingbat \(version) (\(build)) \(AppBuild.commit) | ios | \(d.systemName) \(d.systemVersion) | \(machine) | "
            + "\(Int(s.bounds.width))x\(Int(s.bounds.height))@\(Int(s.scale))"
    }

    private func download() {
        guard let g = session.game else {
            AppModel.shared.toast("Load a game first")
            return
        }
        var state: Data?
        var savedFrom = "current frame"
        var extra: [String: Any] = [:]
        if fault {
            savedFrom = "no state"
            let size = withReplay ? Int(dingbat_fault_report_size(Int32(FaultView.backSeconds))) : -1
            if size >= 0 {
                let powerOn = dingbat_fault_report_power_on() != 0
                if size > 0, let p = dingbat_state_data() { state = Data(bytes: p, count: size) }
                let from = Int(dingbat_fault_report_from())
                let n = Int(dingbat_fault_report_input_count())
                savedFrom = powerOn ? "power-on (replay)"
                    : String(format: "%.1fs before it stopped (frame %d)", Double(n) / 59.73, from)
                // Little-endian uint16 per frame: bit i = dingbat_set_input id i,
                // bit 15 = a run-ahead frame.
                let buttons = n > 0 ? dingbat_fault_report_inputs().map { Data(bytes: $0, count: n * 2) } : nil
                extra["replay"] = [
                    "fromPowerOn": powerOn,
                    "fromFrame": from,
                    "frames": n,
                    "buttons": buttons?.base64EncodedString() ?? "",
                    "checks": String(cString: dingbat_fault_report_checks()),
                ] as [String: Any]
            }
            extra["fault"] = [
                "message": String(cString: dingbat_fault_message()),
                "frame": Int(dingbat_fault_frame()),
                "count": Int(dingbat_fault_count()),
                "sameFrame": dingbat_fault_same() != 0,
            ] as [String: Any]
            // What changes how the frames run (the state carries the rest).
            extra["settings"] = [
                "sgb": settings.sgbEnable,
                "gbaBiosMode": settings.gbaBiosMode,
                "gbaRunBios": settings.gbaRunBios,
                "mp2kHle": settings.mp2kHle,
                "fifoInterp": settings.fifoInterp,
                "runahead": settings.runahead,
                "cheats": CheatStore.load(for: g),
            ] as [String: Any]
        } else if back == 0 {
            state = session.captureState()
        } else {
            let sample = Int32(back - 1)
            let size = Int(dingbat_rewind_scrub_state_size(sample))
            if size > 0, let p = dingbat_state_data() {
                state = Data(bytes: p, count: size)
                savedFrom = String(format: "%.1fs before report",
                                   Double(dingbat_rewind_scrub_seconds_ago(sample)) / 10)
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        var report: [String: Any] = [
            "kind": "dingbat-bug-report",
            "version": fault ? 2 : 1,
            "createdAt": iso.string(from: now),
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "description": desc.trimmingCharacters(in: .whitespacesAndNewlines),
            "game": g.fileName,
            "savedFrom": savedFrom,
            "diagnostics": Self.diagnostics(),
            // Never the ROM.
            "state": state.map { $0.base64EncodedString() } ?? NSNull(),
        ]
        report.merge(extra) { a, _ in a }
        guard let json = try? JSONSerialization.data(withJSONObject: report,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        guard let url = SheetFiles.temp(json, name: "dingbat-bugreport-\(g.stem)-\(f.string(from: now)).json") else { return }
        Share.present([url])
        AppModel.shared.toast("Report ready")
    }
}
