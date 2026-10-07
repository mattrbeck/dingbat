import Foundation
import UIKit

/// Earlier moments of play (web checkpoints): every minute of play the
/// session is taken again, and kept here too as a checkpoint, a few spread
/// over play time, for when the newest moment is the thing that crashes the
/// game ("Resume from earlier"). This device only, never on Drive.
///
/// Files in the game's folder: ckpts.json is the index ({ play, list:
/// [{ slot, ts, play, saveSig }] }, `play` the game's play clock as of the
/// last session, ms), ckpt<slot>.state and ckpt<slot>.jpg each moment.
enum Checkpoints {
    static let slots = 9
    /// Which to keep: the newest, and the oldest of each span of play behind
    /// it (3 min, 10 min, 30 min, 2 h, 8 h, beyond); past 30 days one goes.
    static let spans: [Double] = [3, 10, 30, 120, 480].map { $0 * 60_000 }
    static let maxAge: Double = 30 * 24 * 3600 * 1000
    /// After a crash the moments from before it are frozen; the runs since
    /// share this many slots.
    static let crashRoom = 2

    struct Entry: Equatable {
        var slot: Int
        var ts: Double
        var play: Double
        var saveSig: String?
        var hasSaveSig = true
    }

    struct Index {
        var play: Double = 0
        var list: [Entry] = []
    }

    static func indexURL(_ e: RomEntry) -> URL { e.dir.appendingPathComponent("ckpts.json") }
    static func stateURL(_ e: RomEntry, _ slot: Int) -> URL { e.dir.appendingPathComponent("ckpt\(slot).state") }
    static func picURL(_ e: RomEntry, _ slot: Int) -> URL { e.dir.appendingPathComponent("ckpt\(slot).jpg") }

    static func readIndex(_ e: RomEntry) -> Index {
        guard let d = try? Data(contentsOf: indexURL(e)),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return Index() }
        var idx = Index()
        idx.play = (o["play"] as? NSNumber)?.doubleValue ?? 0
        for r in o["list"] as? [[String: Any]] ?? [] {
            guard let slot = (r["slot"] as? NSNumber)?.intValue, (0..<slots).contains(slot),
                  let ts = (r["ts"] as? NSNumber)?.doubleValue else { continue }
            idx.list.append(Entry(slot: slot, ts: ts, play: (r["play"] as? NSNumber)?.doubleValue ?? 0,
                                  saveSig: r["saveSig"] as? String, hasSaveSig: r.keys.contains("saveSig")))
        }
        return idx
    }

    private static func write(_ idx: Index, _ e: RomEntry) {
        var o = JSObject()
        o["play"] = .number(idx.play)
        o["list"] = .array(idx.list.map { x in
            var r = JSObject()
            r["slot"] = .number(Double(x.slot))
            r["ts"] = .number(x.ts)
            r["play"] = .number(x.play)
            if x.hasSaveSig { r["saveSig"] = x.saveSig.map { .string($0) } ?? .null }
            return .object(r)
        })
        try? RomLibrary.ensureDir(e.dir)
        try? JSValue.object(o).data().write(to: indexURL(e), options: .atomic)
    }

    static func newestFirst(_ a: Entry, _ b: Entry) -> Bool {
        a.play != b.play ? a.play > b.play : a.ts > b.ts
    }

    /// The newest, then the oldest in each span behind it.
    static func spread(_ list: [Entry]) -> [Entry] {
        let sorted = list.sorted(by: newestFirst)
        guard let top = sorted.first else { return [] }
        var oldest: [Int: Entry] = [:]
        for e in sorted.dropFirst() {
            let age = top.play - e.play
            oldest[spans.firstIndex { age <= $0 } ?? spans.count] = e
        }
        return [top] + oldest.keys.sorted().map { oldest[$0]! }
    }

    static func keep(_ list: [Entry], crashSince: Double, now: Double) -> [Entry] {
        let live = list.filter { now - $0.ts < maxAge }
        guard crashSince > 0 else { return spread(live) }
        let frozen = live.filter { $0.ts < crashSince }
        let since = live.filter { $0.ts >= crashSince }.sorted(by: newestFirst).prefix(crashRoom)
        return Array((Array(since) + frozen.sorted(by: newestFirst)).prefix(slots))
    }

    /// The play clock as of a session just taken (the session's own place on
    /// it, for the moments list).
    static func notePlay(_ e: RomEntry, _ play: Double) {
        var idx = readIndex(e)
        guard play > idx.play else { return }
        idx.play = play
        write(idx, e)
    }

    /// Keep this moment if the spread wants it. The record before the index:
    /// a slot the index names always holds the moment it says.
    static func add(_ e: RomEntry, bytes: Data, pic: Data?, ts: Double, play: Double, saveSig: String?) {
        var idx = readIndex(e)
        var entry = Entry(slot: -1, ts: ts, play: play, saveSig: saveSig)
        let kept = keep(idx.list + [entry], crashSince: CrashWatch.info(e.fileName)?.since ?? 0,
                        now: DriveSync.now())
        guard kept.contains(entry) else { return }
        let used = Set(kept.filter { $0 != entry }.map(\.slot))
        guard let slot = (0..<slots).first(where: { !used.contains($0) }) else { return }
        entry.slot = slot
        try? RomLibrary.ensureDir(e.dir)
        guard (try? bytes.write(to: stateURL(e, slot), options: .atomic)) != nil else { return }
        try? FileManager.default.removeItem(at: picURL(e, slot))
        if let pic { try? pic.write(to: picURL(e, slot), options: .atomic) }
        idx.list = kept.map { $0.ts == entry.ts && $0.slot == -1 ? entry : $0 }
        idx.play = max(idx.play, play)
        write(idx, e)
    }

    static func hasAny(_ e: RomEntry) -> Bool { !readIndex(e).list.isEmpty }

    /// With the session (reset save data): they are all of a save now gone.
    static func delete(_ e: RomEntry) {
        let fm = FileManager.default
        try? fm.removeItem(at: indexURL(e))
        for s in 0..<slots {
            try? fm.removeItem(at: stateURL(e, s))
            try? fm.removeItem(at: picURL(e, s))
        }
    }

    /// A rename carries them over.
    static func move(from: RomEntry, to: RomEntry) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexURL(from).path), !fm.fileExists(atPath: indexURL(to).path) else { return }
        try? RomLibrary.ensureDir(to.dir)
        try? fm.moveItem(at: indexURL(from), to: indexURL(to))
        for s in 0..<slots {
            try? fm.moveItem(at: stateURL(from, s), to: stateURL(to, s))
            try? fm.moveItem(at: picURL(from, s), to: picURL(to, s))
        }
    }

    // MARK: moments

    /// A moment the game can go back into: its session or a checkpoint.
    struct Moment: Identifiable {
        enum Kind: Equatable { case session, checkpoint(Int) }
        let kind: Kind
        let ts: Double
        let play: Double
        let saveSig: String?
        var id: String { kind == .session ? "session" : "ckpt\(ts)" }
    }

    /// The session (where it stopped) and the checkpoints, newest first.
    static func moments(_ e: RomEntry) -> [Moment] {
        let idx = readIndex(e)
        let ckpts = idx.list.sorted(by: newestFirst)
        var out: [Moment] = []
        let meta = RomLibrary.shared.sessionMeta(e)
        let haveSession = meta != nil && ((try? Data(contentsOf: e.sessionURL))?.isEmpty == false)
        if let meta, haveSession {
            out.append(Moment(kind: .session, ts: meta.ts, play: max(idx.play, ckpts.first?.play ?? 0),
                              saveSig: meta.saveSig))
        }
        for c in ckpts {
            // The session is that moment, or newer.
            if haveSession, let meta, c.ts >= meta.ts { continue }
            out.append(Moment(kind: .checkpoint(c.slot), ts: c.ts, play: c.play, saveSig: c.saveSig))
        }
        return out
    }

    static func bytes(_ e: RomEntry, _ m: Moment) -> Data? {
        switch m.kind {
        case .session: return try? Data(contentsOf: e.sessionURL)
        case .checkpoint(let s): return try? Data(contentsOf: stateURL(e, s))
        }
    }

    static func picture(_ e: RomEntry, _ m: Moment) -> UIImage? {
        switch m.kind {
        case .session: return UIImage(contentsOfFile: e.sessionPicURL.path)
        case .checkpoint(let s): return UIImage(contentsOfFile: picURL(e, s).path)
        }
    }

    /// "4 min earlier", "2 h earlier": play time, the clock they are kept on.
    static func fmtPlayGap(_ ms: Double) -> String {
        let m = Int((ms / 60_000).rounded())
        if m < 1 { return "Just before" }
        if m < 60 { return "\(m) min earlier" }
        let h = ms / 3_600_000
        let v = h < 10 ? (h * 2).rounded() / 2 : h.rounded()
        return (v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)) + " h earlier"
    }
}

/// Runs that end without the game being left (a crash, or a kill in the
/// foreground) are counted per game, in a row (web noteCrashedRuns). While
/// a game runs in view, playing.json names it; pausing, the background or
/// leaving the game take it out. One found at launch is a crash. Two in a
/// row and a tap on the game asks first (the "stopped unexpectedly" sheet).
/// A run that played a minute starts a new row at one whatever ended it,
/// and one that played a minute and ended normally clears the count.
enum CrashWatch {
    static let cleanRun: Double = 60       // seconds
    static let askStreak = 2

    struct Info { var streak: Int; var since: Double }

    private static let playingURL = RomLibrary.support.appendingPathComponent("playing.json")
    private static let crashesURL = RomLibrary.support.appendingPathComponent("crashes.json")
    private static var marked = false
    private static var markedLong = false
    /// Read at launch and written through.
    private static var games: [String: Info] = load()

    private static func load() -> [String: Info] {
        guard let d = try? Data(contentsOf: crashesURL),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String: Any]] else { return [:] }
        var out: [String: Info] = [:]
        for (g, r) in o {
            out[g] = Info(streak: (r["streak"] as? NSNumber)?.intValue ?? 0,
                          since: (r["since"] as? NSNumber)?.doubleValue ?? 0)
        }
        return out
    }

    private static func store() {
        let o = games.mapValues { ["streak": $0.streak, "since": $0.since] as [String: Any] }
        try? RomLibrary.ensureDir(RomLibrary.support)
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: crashesURL, options: .atomic) }
    }

    static func info(_ game: String) -> Info? { games[game] }
    static func streak(_ game: String) -> Int { games[game]?.streak ?? 0 }

    /// At launch: a mark left behind is a run that crashed.
    static func noteCrashedRun() {
        guard let d = try? Data(contentsOf: playingURL),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let game = o["game"] as? String else { return }
        let c = games[game] ?? Info(streak: 0, since: 0)
        games[game] = (o["long"] as? Bool) == true
            ? Info(streak: 1, since: DriveSync.now())
            : Info(streak: c.streak + 1, since: c.since > 0 ? c.since : DriveSync.now())
        NSLog("previous run of %@ ended unexpectedly (%d in a row)", game, games[game]!.streak)
        // The count first; then the mark goes.
        store()
        try? FileManager.default.removeItem(at: playingURL)
    }

    private static func putMark(_ game: String, long: Bool) {
        let o: [String: Any] = ["game": game, "at": DriveSync.now(), "long": long]
        try? RomLibrary.ensureDir(RomLibrary.support)
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: playingURL, options: .atomic) }
    }

    /// The game is running in view. `played`: seconds this run has played.
    static func playing(_ game: String, played: Double) {
        let long = played >= cleanRun
        if marked && (markedLong || !long) { return }
        marked = true
        markedLong = long
        putMark(game, long: long)
    }

    /// The run stopped normally (paused, backgrounded, left).
    static func stopped(_ game: String?, played: Double) {
        guard marked else { return }
        marked = false
        markedLong = false
        try? FileManager.default.removeItem(at: playingURL)
        if let game, played >= cleanRun, games[game] != nil {
            games[game] = nil
            store()
        }
    }

    /// The count goes with the game (deleted, reset, renamed away).
    static func forget(_ game: String) {
        guard games[game] != nil else { return }
        games[game] = nil
        store()
    }
}
