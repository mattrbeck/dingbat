import Foundation
import Network
import SwiftUI
import UIKit

// Google Drive sync, ported from web/index.js ("Google Drive sync" through
// "Sync triggers") so the app and dingbat.gg share one library in the
// account's appDataFolder. The rules are the web's, and so are the names:
// every Drive file is named for the record it mirrors ("save:<game>",
// "state:<game>:slot3", "stateauto:<game>", "frame:<game>", ...), and one
// file, "library", holds the merged play history, tombstones and rename
// markers:
//
//     { recents: [{ name, ts, imp?, gen? }], tomb: [{ name, ts, gen? }],
//       ren: [{ from, to, ts }] }
//
// Uploads go through a persisted queue, flushed 2 s after the last change
// and at most 10 s after the first; pulls run at sign-in, app start, return
// to the foreground, a regained network, every 3 minutes and Sync now. ROMs
// are never bulk-downloaded: a game only on Drive downloads when tapped.
// docs/ios-app.md and the web code's comments say why each rule is so; the
// comments here keep the web's reasoning where it decides an edge.

/// A tombstone: a game deleted at `ts`, of generation `gen`.
struct Tomb: Codable, Equatable {
    var name: String
    var ts: Double
    var gen: Int = 0
    var js: JSObject {
        var o = JSObject([("name", .string(name)), ("ts", .number(ts))])
        if gen > 0 { o["gen"] = .number(Double(gen)) }
        return o
    }
}

/// A rename marker: other devices move `from`'s records to `to`.
struct Ren: Codable, Equatable {
    var from: String
    var to: String
    var ts: Double
    var js: JSObject { JSObject([("from", .string(from)), ("to", .string(to)), ("ts", .number(ts))]) }
}

/// A queued in-place rename of one Drive file.
struct QRen: Codable, Equatable {
    var from: String
    var to: String
}

/// The library as merged (web { recents, tomb, ren }).
struct DriveLibrary {
    var recents: [JSObject] = []
    var tomb: [Tomb] = []
    var ren: [Ren] = []

    var js: JSValue {
        .object(JSObject([("recents", .array(recents.map { .object($0) })),
                          ("tomb", .array(tomb.map { .object($0.js) })),
                          ("ren", .array(ren.map { .object($0.js) }))]))
    }

    static func parse(_ data: Data) -> DriveLibrary {
        guard let o = JSValue.parse(data)?.objectValue else { return DriveLibrary() }
        var lib = DriveLibrary()
        lib.recents = (o["recents"]?.arrayValue ?? []).compactMap { $0.objectValue }
        lib.tomb = (o["tomb"]?.arrayValue ?? []).compactMap { v in
            guard let t = v.objectValue, let n = t.string("name") else { return nil }
            return Tomb(name: n, ts: t.number("ts") ?? 0, gen: Lib.gen(t))
        }
        lib.ren = (o["ren"]?.arrayValue ?? []).compactMap { v in
            guard let r = v.objectValue, let f = r.string("from"), let t = r.string("to") else { return nil }
            return Ren(from: f, to: t, ts: r.number("ts") ?? 0)
        }
        return lib
    }

    /// Deleted: a tombstone with no entry of a newer generation beside it.
    func deleted(_ name: String) -> Bool {
        tomb.contains { $0.name == name } && !recents.contains { $0.string("name") == name }
    }

    func gen(_ name: String) -> Int {
        recents.first { $0.string("name") == name }.map(Lib.gen) ?? 0
    }
}

/// An insertion-ordered map (a JS Map: re-setting a key keeps its place).
private struct OMap<V> {
    private(set) var keys: [String] = []
    private var dict: [String: V] = [:]
    subscript(k: String) -> V? {
        get { dict[k] }
        set {
            if let v = newValue {
                if dict[k] == nil { keys.append(k) }
                dict[k] = v
            } else if dict.removeValue(forKey: k) != nil {
                keys.removeAll { $0 == k }
            }
        }
    }
    var values: [V] { keys.map { dict[$0]! } }
}

/// Array.prototype.sort is stable; so is this.
private func stableSorted<T>(_ a: [T], by less: (T, T) -> Bool) -> [T] {
    a.enumerated().sorted { x, y in
        if less(x.element, y.element) { return true }
        if less(y.element, x.element) { return false }
        return x.offset < y.offset
    }.map(\.element)
}

/// web mergeLibrary, line for line.
func mergeLibrary(_ a: DriveLibrary, _ b: DriveLibrary) -> DriveLibrary {
    func ts(_ o: JSObject) -> Double { o.number("ts") ?? 0 }
    func imp(_ o: JSObject?) -> Double { o?.number("imp") ?? 0 }
    var byName = OMap<JSObject>()
    for e in a.recents + b.recents {
        guard let name = e.string("name"), !name.isEmpty else { continue }
        let prev = byName[name]
        let im = max(imp(prev), imp(e))
        let g = Lib.gen(e)
        let pg = prev.map(Lib.gen) ?? -1
        if prev == nil || g > pg || (g == pg && ts(e) > ts(prev!)) {
            byName[name] = Lib.entry(name: name, ts: ts(e), imp: nil, gen: g)
        }
        if im != 0 { byName[name]!["imp"] = .number(im) }
    }
    var ren = OMap<Ren>()
    for r in a.ren + b.ren {
        guard !r.from.isEmpty, !r.to.isEmpty, r.from != r.to else { continue }
        if let prev = ren[r.from], r.ts <= prev.ts { continue }
        ren[r.from] = Ren(from: r.from, to: r.to, ts: r.ts)
    }
    var done = Set<String>()
    for r in stableSorted(ren.values, by: { $0.ts < $1.ts }) {
        let e = byName[r.from]
        let reimported = e != nil && imp(e) > r.ts
        if let e, !reimported {
            byName[r.from] = nil
            let t = byName[r.to]
            if t == nil || Lib.gen(t!) < Lib.gen(e) || (Lib.gen(t!) == Lib.gen(e) && ts(t!) < ts(e)) {
                byName[r.to] = Lib.entry(name: r.to, ts: ts(e), impFirst: imp(e) != 0 ? imp(e) : nil, gen: Lib.gen(e))
            }
            if r.ts > imp(byName[r.to]) { byName[r.to]!["imp"] = .number(r.ts) }
            if done.contains(r.to) { ren[r.to] = nil }
        }
        if reimported { ren[r.from] = nil }
        done.insert(r.from)
    }
    var tomb = OMap<Tomb>()
    for t in a.tomb + b.tomb {
        guard !t.name.isEmpty else { continue }
        let prev = tomb[t.name]
        let pg = prev?.gen ?? -1
        if prev == nil || t.gen > pg || (t.gen == pg && t.ts > prev!.ts) {
            tomb[t.name] = Tomb(name: t.name, ts: t.ts, gen: t.gen)
        }
    }
    for name in tomb.keys {
        guard let t = tomb[name] else { continue }
        let e = byName[name]
        if let e, Lib.gen(e) > t.gen { continue }
        if let e, Lib.gen(e) == t.gen, ts(e) > t.ts { tomb[name] = nil } else { byName[name] = nil }
    }
    return DriveLibrary(recents: stableSorted(byName.values, by: { ts($0) > ts($1) }),
                        tomb: tomb.values, ren: ren.values)
}

/// Drive file name -> (game, kind); nil for anything unknown. Slot 0 keeps
/// "state"/"statemeta", slots 1..8 append ":slotN".
func parseDriveFileName(_ n: String) -> (game: String, kind: String)? {
    if n.hasPrefix("rom:") { return (String(n.dropFirst(4)), "rom") }
    if n.hasPrefix("frame:") { return (String(n.dropFirst(6)), "frame") }
    for (prefix, cat) in [("statemeta:", "statemeta"), ("state:", "state")] where n.hasPrefix(prefix) {
        var g = String(n.dropFirst(prefix.count))
        var slot = 0
        if let r = g.range(of: #":slot(\d+)$"#, options: .regularExpression) {
            slot = Int(g[r].dropFirst(5)) ?? 0
            g = String(g[..<r.lowerBound])
        }
        return (g, slot == 0 ? cat : "\(cat):\(slot)")
    }
    if n.hasPrefix("save:") {
        let g = String(n.dropFirst(5))
        return g.hasSuffix("-p2") ? (String(g.dropLast(3)), "save2") : (g, "save")
    }
    if n.hasPrefix("oldsave:") { return (String(n.dropFirst(8)), "oldsave") }
    if n.hasPrefix("stateauto:") { return (String(n.dropFirst(10)), "session") }
    return nil
}

/// The kinds that belong to one generation of a game (a ROM carries no
/// progress, and a kept save says for itself where it came from).
private func genBound(_ kind: String) -> Bool { kind != "rom" && kind != "oldsave" }

private final class UploadPool: @unchecked Sendable {
    var next = 0
    var failure: Error?
}

/// The work of an ended session (sign out, another account) stops at its
/// next await.
struct DriveSessionEnded: Error {}

final class DriveSync: ObservableObject {
    static let shared = DriveSync()

    static let libraryFile = "library"
    static let saveHookFile = "save-hook"
    static let keptSaveMs: Double = 30 * 24 * 3600 * 1000
    static let parallel = 6

    enum Status: String { case idle, syncing, done, offline }

    /// Everything that describes one account's Drive, parked under its id
    /// when another account signs in here.
    struct AccountState: Codable {
        var queueUp: [String] = []
        var queueDel: [String] = []
        var queueRen: [QRen] = []
        var tomb: [Tomb] = []
        var ren: [Ren] = []
        var sigs: [String: String] = [:]
        var rmt: [String: String] = [:]
        var delTs: [String: Double] = [:]
        /// Library entries this device held only for that account.
        var recents: String?
    }

    /// Persisted (web syncState, "gdrive_sync").
    struct State: Codable {
        var queueUp: [String] = []
        var queueDel: [String] = []
        var queueRen: [QRen] = []
        var tomb: [Tomb] = []
        var ren: [Ren] = []
        var sigs: [String: String] = [:]
        var rmt: [String: String] = [:]
        var delTs: [String: Double] = [:]
        var acct: String?
        var parked: [String: AccountState] = [:]
        var connected = false
        var token: String?
        var tokenExp: Double = 0
        var refresh: String?
        var refreshAcct: String?
        var email: String?
        var saveHook = SaveHookRec()
    }

    /// Settings › General › Advanced › Save webhook, synced in its own file.
    struct SaveHookRec: Codable {
        var url = ""
        var ts: Double = 0
        var dirty = false
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var stateTick = 0
    /// Games coming down on demand: (bytes so far, total).
    @Published private(set) var downloading: [String: (Int, Int)] = [:]
    /// Drive-only games, and games whose ROM is on Drive (byte-less tiles).
    var state = State()

    /// Names renamed away here whose old records a pull must not write back.
    var renamedAway = Set<String>()

    private var session = 0
    private var connecting = 0
    private var remarked = Set<String>()
    private var handoffForce = Set<String>()
    private var handoffOffered = ""
    private var handoffStash: (game: String, news: [(key: String, f: DriveFile, bytes: Data)])?
    private var chain: Task<Void, Never>?
    private var pullQueued = false
    private var debounce: Timer?
    private var cap: Timer?
    private var poll: Timer?
    private var brokerRetryAt: Double = 0
    private var refreshInFlight: Task<Bool, Never>?
    private let client = DriveClient()
    private let monitor = NWPathMonitor()
    private var online = true

    private static let stateURL = RomLibrary.support.appendingPathComponent("gdrive_sync.json")

    private init() {
        if let data = try? Data(contentsOf: Self.stateURL),
           let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        }
        #if DEBUG
        // Dev hook: `-drive-stub http://127.0.0.1:PORT` talks to a fake Drive
        // (ios/e2e/drive-sync.mjs serves web/e2e/fakedrive.mjs), signed in as
        // the fake's account, so sync runs end to end with no Google.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-drive-stub"), i + 1 < args.count {
            let base = args[i + 1]
            DriveClient.files = base + "/www.googleapis.com/drive/v3/files"
            DriveClient.upload = base + "/www.googleapis.com/upload/drive/v3/files"
            DriveAuth.tokenInfoURL = base + "/oauth2.googleapis.com/tokeninfo"
            if !state.connected {
                state.connected = true
                state.acct = "acct1"
                state.email = "player@example.com"
            }
            state.token = "tok"
            state.tokenExp = Self.now() + 3600e3
        }
        #endif
        client.token = { [weak self] in self?.state.token }
        client.renew = { [weak self] in await self?.refreshSilently(force: true) ?? false }
    }

    // MARK: identity

    var linked: Bool { state.connected }
    /// This device belongs to an account, signed in this minute or not:
    /// intent recorded offline or signed out flushes when it comes back.
    var enrolled: Bool { state.connected || state.acct != nil }
    var active: Bool { state.token != nil && state.connected && connecting == 0 }
    var email: String? { state.email }
    var pendingCount: Int { state.queueUp.count + state.queueDel.count + state.queueRen.count }

    func saveState() {
        try? RomLibrary.ensureDir(RomLibrary.support)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.stateURL, options: .atomic) }
        stateTick &+= 1
    }

    private func guardSession() -> () throws -> Void {
        let at = session
        return { [weak self] in if self?.session != at { throw DriveSessionEnded() } }
    }

    private func setStatus(_ s: Status) {
        if status != s { status = s }
        if s == .done {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.status == .done { self?.status = .idle }
            }
        }
    }

    private func refreshStatus() {
        if !active { setStatus(.idle) } else if status == .offline && pendingCount == 0 { setStatus(.idle) }
        stateTick &+= 1
    }

    // MARK: the queue

    func scheduleFlush() {
        guard linked else { return }
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.flush() }
        if cap == nil {
            cap = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.flush() }
        }
        stateTick &+= 1
    }

    func markUpload(_ name: String) {
        guard enrolled, parseDriveFileName(name) != nil else { return }
        if !state.queueUp.contains(name) { state.queueUp.append(name) } else { remarked.insert(name) }
        saveState()
        scheduleFlush()
    }

    func markDelete(_ name: String) {
        guard enrolled, parseDriveFileName(name) != nil else { return }
        if !state.queueDel.contains(name) { state.queueDel.append(name) }
        // Stamped when asked for, not when it reaches Drive: an offline
        // Tuesday delete must not outrank another device's Wednesday write.
        state.delTs[name] = Self.now()
        state.queueUp.removeAll { $0 == name }
        saveState()
        scheduleFlush()
    }

    func markDeleteAll(_ names: [String]) {
        guard enrolled else { return }
        for n in names { markDelete(n) }
    }

    func markGameUpload(_ game: String) {
        guard enrolled else { return }
        for n in localFiles(for: game) where !state.queueUp.contains(n) { state.queueUp.append(n) }
        saveState()
        scheduleFlush()
    }

    /// A local save-data wipe reaches Drive: the saves and the session.
    func queueSaveDataDeletes(_ game: String) {
        guard enrolled else { return }
        for k in RomLibrary.perGameKeys(game).saves { markDelete(k) }
        markDelete("stateauto:" + game)
    }

    func addTombstone(_ name: String, gen: Int) {
        guard enrolled else { return }
        state.tomb.removeAll { $0.name == name }
        state.tomb.append(Tomb(name: name, ts: Self.now(), gen: gen))
    }

    /// The Drive side of a rename (web renameGame's `renamed`): every synced
    /// key renames in place on Drive, sigs and rmt follow, and the marker
    /// tells the other devices.
    func renameLocal(from old: String, to new: String, ts: Double) {
        renamedAway.insert(old)
        renamedAway.remove(new)
        guard enrolled else { return }
        let pairs = zip(RomLibrary.perGameKeys(old).all, RomLibrary.perGameKeys(new).all)
            .filter { parseDriveFileName($0.0) != nil && !state.queueDel.contains($0.0) }
        let oldKeys = pairs.map(\.0), newKeys = pairs.map(\.1)
        for (f, t) in pairs {
            if let v = state.sigs.removeValue(forKey: f) { state.sigs[t] = v }
            if let v = state.rmt.removeValue(forKey: f) { state.rmt[t] = v }
        }
        var up: [String] = []
        for n in state.queueUp {
            let m = oldKeys.firstIndex(of: n).map { newKeys[$0] } ?? n
            if !up.contains(m) { up.append(m) }
        }
        state.queueUp = up
        state.queueDel.removeAll { newKeys.contains($0) }
        var d: [String: Double] = [:]
        for (k, v) in state.delTs where !newKeys.contains(k) {
            d[oldKeys.firstIndex(of: k).map { newKeys[$0] } ?? k] = v
        }
        state.delTs = d
        state.queueRen += pairs.map { QRen(from: $0.0, to: $0.1) }
        state.tomb.removeAll { $0.name == old || $0.name == new }
        state.ren.removeAll { $0.from == old || $0.from == new }
        state.ren.append(Ren(from: old, to: new, ts: ts))
        saveState()
    }

    // MARK: local records as bytes (web readSyncBytes / writeSyncBytes)

    /// The keys this device holds that Drive mirrors, with their game/kind.
    func localSyncFiles() -> [String: (game: String, kind: String)] {
        var out: [String: (String, String)] = [:]
        let fm = FileManager.default
        var games = Set((try? fm.contentsOfDirectory(atPath: RomLibrary.gamesDir.path)) ?? [])
        for f in (try? fm.contentsOfDirectory(atPath: RomLibrary.romsDir.path)) ?? []
        where RomLibrary.romExtensions.contains((f as NSString).pathExtension.lowercased()) {
            games.insert(f)
        }
        for g in games {
            for k in RomLibrary.perGameKeys(g).all {
                guard let p = parseDriveFileName(k), RomLibrary.hasKey(k) else { continue }
                out[k] = p
            }
        }
        return out
    }

    func localFiles(for game: String) -> [String] {
        RomLibrary.perGameKeys(game).all.filter { parseDriveFileName($0) != nil && RomLibrary.hasKey($0) }
    }

    func readSyncBytes(_ key: String) -> Data? {
        if key.hasPrefix("stateauto:") { return sessionBundle(String(key.dropFirst(10))) }
        if key.hasPrefix("save:"), let g = GameSession.shared.game, key == "save:" + g.fileName {
            dingbat_flush_save()  // the core's RAM may be ahead of its file
        }
        guard let f = RomLibrary.files(forKey: key).first,
              let d = try? Data(contentsOf: f), !d.isEmpty else { return nil }
        return d
    }

    func writeSyncBytes(_ key: String, _ bytes: Data) throws {
        guard let p = parseDriveFileName(key) else { return }
        let e = RomEntry(fileName: p.game)
        try RomLibrary.ensureDir(e.dir)
        switch p.kind {
        case "session":
            guard let s = Self.parseBundle(bytes) else { return }
            try? FileManager.default.removeItem(at: e.sessionPicURL)
            try s.state.write(to: e.sessionURL, options: .atomic)
            try s.header.write(to: e.sessionMetaURL, options: .atomic)
            if let pic = s.pic { try? pic.write(to: e.sessionPicURL, options: .atomic) }
        case "oldsave":
            storeKeptRecord(p.game, bytes)
        case "rom":
            try bytes.write(to: e.url, options: .atomic)
            RomLibrary.shared.noteRomSize(p.game, bytes.count)
        default:
            guard let f = RomLibrary.files(forKey: key).first else { return }
            try bytes.write(to: f, options: .atomic)
        }
        if ["frame", "session"].contains(p.kind) { RomLibrary.shared.pictureGen += 1 }
    }

    // MARK: sessions as one Drive file

    private static let sessionMagic = Array("DGBSESS1".utf8)

    /// "DGBSESS1", the header's length (u32 LE), the header JSON, the state,
    /// then the picture (web sessionBundle).
    func sessionBundle(_ game: String) -> Data? {
        let e = RomEntry(fileName: game)
        guard let meta = RomLibrary.shared.sessionMeta(e),
              let state = try? Data(contentsOf: e.sessionURL), !state.isEmpty else { return nil }
        let pic = (try? Data(contentsOf: e.sessionPicURL)) ?? Data()
        let head = meta.header(state: state.count, pic: pic.count)
        var out = Data(Self.sessionMagic)
        var hl = UInt32(head.count).littleEndian
        out.append(Data(bytes: &hl, count: 4))
        out.append(head)
        out.append(state)
        out.append(pic)
        return out
    }

    static func parseBundle(_ b: Data) -> (header: Data, state: Data, pic: Data?, meta: SessionMeta)? {
        let bytes = [UInt8](b)
        guard bytes.count >= 12, Array(bytes[0..<8]) == sessionMagic else { return nil }
        let hl = Int(UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24)
        guard 12 + hl <= bytes.count else { return nil }
        let head = Data(bytes[12..<(12 + hl)])
        guard let o = (try? JSONSerialization.jsonObject(with: head)) as? [String: Any],
              let meta = SessionMeta(json: head) else { return nil }
        let sl = (o["state"] as? NSNumber)?.intValue ?? 0
        let pl = (o["pic"] as? NSNumber)?.intValue ?? 0
        let at = 12 + hl
        guard sl > 0, at + sl + pl <= bytes.count else { return nil }
        let pic = pl > 0 ? Data(bytes[(at + sl)..<(at + sl + pl)]) : nil
        return (head, Data(bytes[at..<(at + sl)]), pic, meta)
    }

    // MARK: kept saves (oldsave:<name>: { at, del, kept, why, data(base64) })

    struct KeptSave {
        var data: Data?
        var at: Double, del: Double, kept: Double
        var why: String

        var json: Data {
            var o = JSObject()
            o["at"] = .number(at); o["del"] = .number(del); o["kept"] = .number(kept)
            o["why"] = .string(why)
            o["data"] = data.flatMap { $0.isEmpty ? nil : JSValue.string($0.base64EncodedString()) } ?? .null
            return JSValue.object(o).data()
        }

        init(data: Data?, at: Double, del: Double, kept: Double, why: String) {
            self.data = data; self.at = at; self.del = del; self.kept = kept; self.why = why
        }

        init?(json: Data) {
            guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
            data = (o["data"] as? String).flatMap { Data(base64Encoded: $0) }
            at = (o["at"] as? NSNumber)?.doubleValue ?? 0
            del = (o["del"] as? NSNumber)?.doubleValue ?? 0
            kept = (o["kept"] as? NSNumber)?.doubleValue ?? 0
            why = o["why"] as? String ?? "deleted"
        }

        var title: String { why == "replaced" ? "The save you replaced" : "Save from before you deleted this game" }
    }

    /// The kept save a game's menu and Manage Saves offer (nil: none, or a
    /// "restored" record offering nothing).
    func keptSave(_ game: String) -> KeptSave? {
        guard let d = try? Data(contentsOf: RomEntry(fileName: game).oldSaveURL),
              let k = KeptSave(json: d), let data = k.data, !data.isEmpty else { return nil }
        return k
    }

    /// Two copies of one kept save: the one written later stands; ours
    /// newer, Drive gets ours back. True when `bytes` was stored.
    @discardableResult
    private func storeKeptRecord(_ game: String, _ bytes: Data) -> Bool {
        guard let rec = KeptSave(json: bytes) else { return false }
        let url = RomEntry(fileName: game).oldSaveURL
        if let curData = try? Data(contentsOf: url), let cur = KeptSave(json: curData), cur.kept >= rec.kept {
            if cur.kept > rec.kept { markUpload("oldsave:" + game) }
            return false
        }
        try? RomLibrary.ensureDir(RomEntry(fileName: game).dir)
        try? rec.json.write(to: url, options: .atomic)
        return true
    }

    @discardableResult
    private func keepOldSave(_ game: String, _ rec: KeptSave) -> Bool {
        let stored = storeKeptRecord(game, rec.json)
        if stored { markUpload("oldsave:" + game) }
        return stored
    }

    /// A save about to be replaced by an earlier moment's battery, kept aside
    /// (web resumeMoment): Restore old save switches back.
    func keepReplacedSave(_ game: String, _ data: Data) {
        let now = Self.now()
        keepOldSave(game, KeptSave(data: data, at: now, del: now, kept: now, why: "replaced"))
    }

    /// Restore: the kept save becomes the game's save, and the game's save
    /// is kept in its place, so a second Restore undoes the first.
    @MainActor
    func restoreKeptSave(_ game: String) {
        guard let rec = keptSave(game), let data = rec.data else { return }
        let e = RomEntry(fileName: game)
        let wasOpen = GameSession.shared.game == e
        if wasOpen { AppModel.shared.closeGame() }
        let cur = try? Data(contentsOf: e.saveURL)
        let now = Self.now()
        let at = (cur?.isEmpty ?? true) ? 0
            : (wasOpen || state.queueUp.contains("save:" + game)) ? now
            : (Self.parseTime(state.rmt["save:" + game]) ?? now)
        try? RomLibrary.ensureDir(e.dir)
        try? data.write(to: e.saveURL, options: .atomic)
        RomLibrary.deleteKeys(["stateauto:" + game])
        markDelete("stateauto:" + game)
        markUpload("save:" + game)
        let next = (cur?.isEmpty ?? true)
            ? KeptSave(data: nil, at: 0, del: rec.del, kept: now, why: "restored")
            : KeptSave(data: cur, at: at, del: rec.del, kept: now, why: "replaced")
        try? next.json.write(to: e.oldSaveURL, options: .atomic)
        markUpload("oldsave:" + game)
        RomLibrary.shared.pictureGen += 1
        AppModel.shared.toast(cur?.isEmpty ?? true ? "Old save restored" : "Old save restored — Restore again to switch back")
    }

    /// Past its 30 days, a kept save leaves this device and (queued) Drive.
    private func expireKeptSaves() {
        let now = Self.now()
        for (k, p) in localSyncFiles() where p.kind == "oldsave" {
            let url = RomEntry(fileName: p.game).oldSaveURL
            if let d = try? Data(contentsOf: url), let rec = KeptSave(json: d), now < rec.del + Self.keptSaveMs { continue }
            try? FileManager.default.removeItem(at: url)
            markDelete(k)
        }
    }

    // MARK: the library file

    private struct Listing {
        var map: [String: DriveFile] = [:]
        var libraryCopies: [DriveFile] = []
        var libraryRead: [String] = []
        var libraryText: String?
    }

    private func listMap() async throws -> Listing {
        let files = try await client.listAll()
        var l = Listing()
        let libs = files.filter { $0.name == Self.libraryFile }.sorted {
            let a = Self.parseTime($0.createdTime) ?? 0, b = Self.parseTime($1.createdTime) ?? 0
            return a != b ? a < b : $0.id < $1.id
        }
        for f in files where f.name != Self.libraryFile { l.map[f.name] = f }
        if let first = libs.first { l.map[Self.libraryFile] = first }
        l.libraryCopies = libs
        return l
    }

    /// Every copy, merged (two devices' first syncs can each create one).
    private func readLibrary(_ l: inout Listing, live: () throws -> Void) async throws -> DriveLibrary {
        var libs: [DriveLibrary] = []
        var read: [String] = []
        for f in l.libraryCopies {
            let bytes = try await client.download(f.id)
            try live()
            if l.libraryCopies.count == 1 { l.libraryText = String(decoding: bytes, as: UTF8.self) }
            libs.append(DriveLibrary.parse(bytes))
            read.append(f.id)
        }
        l.libraryRead = read
        guard let first = libs.first else { return DriveLibrary() }
        return libs.dropFirst().reduce(first) { mergeLibrary($0, $1) }
    }

    private func libraryUnchanged(_ lib: DriveLibrary, _ l: Listing) -> Bool {
        l.libraryText != nil && l.libraryText == lib.js.stringify()
    }

    private func writeLibrary(_ lib: DriveLibrary, _ remote: Listing, readFrom: Listing) async throws {
        let keep = remote.map[Self.libraryFile]
        try await client.uploadFile(name: Self.libraryFile, bytes: lib.js.data(), existingID: keep?.id)
        for f in remote.libraryCopies where f.id != keep?.id && readFrom.libraryRead.contains(f.id) {
            try? await client.delete(f.id)
        }
    }

    private func localLibrary() -> DriveLibrary {
        DriveLibrary(recents: RomLibrary.shared.recents, tomb: state.tomb, ren: state.ren)
    }

    // MARK: exclusive runs

    /// Drive operations run one at a time; a busy engine defers work, never
    /// drops it.
    @MainActor
    private func runExclusive(_ fn: @escaping @MainActor () async -> Void) async {
        let prev = chain
        let t = Task { @MainActor in
            await prev?.value
            await fn()
        }
        chain = t
        await t.value
    }

    func flush() {
        debounce?.invalidate(); debounce = nil
        cap?.invalidate(); cap = nil
        Task { @MainActor in await self.flushNow() }
    }

    @MainActor
    func flushNow() async {
        debounce?.invalidate(); debounce = nil
        cap?.invalidate(); cap = nil
        await runExclusive { await self.flushInner() }
    }

    @MainActor
    func pull(silent: Bool = true) async {
        if pullQueued { await chain?.value; return }
        pullQueued = true
        await runExclusive {
            self.pullQueued = false
            await self.pullInner(silent: silent)
        }
    }

    // MARK: flush (web flushSyncInner)

    @MainActor
    private func flushInner() async {
        guard active else { return }
        if pendingCount == 0 && state.tomb.isEmpty && state.ren.isEmpty { refreshStatus(); return }
        let live = guardSession()
        client.live = live
        setStatus(.syncing)
        do {
            var remote = try await listMap(); try live()
            var lib = mergeLibrary(try await readLibrary(&remote, live: live), localLibrary())
            try live()
            // A tombstone the merge dropped: a later play elsewhere says the
            // delete was not meant; its queued file deletes are cancelled.
            let revived = Set(state.tomb.map(\.name).filter { n in !lib.tomb.contains { $0.name == n } })
            if !revived.isEmpty {
                state.queueDel.removeAll { n in
                    guard let g = parseDriveFileName(n)?.game, revived.contains(g) else { return false }
                    state.delTs[n] = nil
                    return true
                }
            }
            // A marker the merge spent: the old name was imported afresh.
            let spent = Set(state.ren.map(\.from).filter { f in !lib.ren.contains { $0.from == f } })
            if !spent.isEmpty {
                state.queueRen.removeAll { q in parseDriveFileName(q.from).map { spent.contains($0.game) } ?? false }
            }
            // Renames first: every later step speaks in new names.
            for r in state.queueRen {
                if let f = remote.map[r.from], remote.map[r.to] == nil {
                    let mt = try await client.rename(f.id, to: r.to); try live()
                    remote.map[r.from] = nil
                    var nf = f; nf.name = r.to; nf.modifiedTime = mt ?? f.modifiedTime
                    remote.map[r.to] = nf
                    if let mt, state.rmt[r.to] != nil { state.rmt[r.to] = mt }
                } else if let f = remote.map[r.from] {
                    try await client.delete(f.id); try live()
                    remote.map[r.from] = nil
                } else if remote.map[r.to] == nil, !state.queueUp.contains(r.to), readSyncBytes(r.to) != nil {
                    state.queueUp.append(r.to)
                }
                state.queueRen.removeAll { $0 == r }
            }
            for name in state.queueDel {
                let r = remote.map[name]
                let asked = state.delTs[name] ?? 0
                let outranked = r != nil && asked != 0 && (Self.parseTime(r!.modifiedTime) ?? 0) > asked
                if let r, !outranked {
                    try await client.delete(r.id); try live()
                    remote.map[name] = nil
                }
                if !outranked { state.sigs[name] = nil; state.rmt[name] = nil }
                state.delTs[name] = nil
                state.queueDel.removeAll { $0 == name }
            }
            // Several files at once, started in order; the first failure
            // starts nothing further (web runPool).
            let queue = state.queueUp
            let pool = UploadPool()
            let libNow = lib, remoteNow = remote
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<min(Self.parallel, queue.count) {
                    group.addTask { @MainActor in
                        while pool.failure == nil && pool.next < queue.count {
                            let name = queue[pool.next]
                            pool.next += 1
                            do { try await self.uploadOne(name, lib: libNow, remote: remoteNow, live: live) }
                            catch { if pool.failure == nil { pool.failure = error } }
                        }
                    }
                }
            }
            if let failure = pool.failure { throw failure }
            if !libraryUnchanged(lib, remote) {
                let again = try await listMap(); try live()
                try await writeLibrary(lib, again, readFrom: remote)
            }
            try live()
            // Merged again with the library as it is now (a delete, import
            // or rename made meanwhile must not be dropped), under the lock.
            try await RomLibrary.shared.updateRecent { here in
                try live()
                let now = mergeLibrary(lib, DriveLibrary(recents: here, tomb: self.state.tomb, ren: self.state.ren))
                self.state.tomb = now.tomb
                self.state.ren = now.ren
                let add = now.recents.filter { r in
                    revived.contains(r.string("name") ?? "") && !here.contains { $0.string("name") == r.string("name") }
                }
                lib = now
                guard !add.isEmpty else { return nil }
                return stableSorted(here + add) { ($0.number("ts") ?? 0) > ($1.number("ts") ?? 0) }
            }
            saveState()
            setStatus(.done)
        } catch is DriveSessionEnded {
            refreshStatus()
        } catch {
            saveState()
            setStatus(.offline)
        }
    }

    @MainActor
    private func uploadOne(_ name: String, lib: DriveLibrary, remote: Listing, live: () throws -> Void) async throws {
        guard state.queueUp.contains(name) else { return }
        let parsed = parseDriveFileName(name)
        let game = parsed?.game
        if let game, lib.deleted(game) { state.queueUp.removeAll { $0 == name }; return }
        if let game, lib.ren.contains(where: { $0.from == game }) { return }
        let gen = game.map { RomLibrary.shared.gen(of: $0) } ?? 0
        if let game, let p = parsed, genBound(p.kind), lib.gen(game) > gen {
            state.queueUp.removeAll { $0 == name }
            return
        }
        remarked.remove(name)
        let held0 = remote.map[name]
        if parsed?.kind == "rom", let held0, held0.gen >= gen, state.sigs[name] != nil {
            state.queueUp.removeAll { $0 == name }
            return
        }
        let bytes = readSyncBytes(name)
        // A session another device wrote since this one last saw Drive's
        // copy is not written over unseen: the pull after decides.
        let forced = handoffForce.remove(name) != nil
        if let bytes, parsed?.kind == "session", let r0 = remote.map[name], r0.gen >= gen,
           state.rmt[name] != r0.modifiedTime, Self.sig(bytes) != state.sigs[name], !forced {
            return
        }
        if let bytes {
            let r = remote.map[name]
            let sig = Self.sig(bytes)
            let restamp = r != nil && r!.gen != gen
            if r == nil || (restamp && r!.gen < gen) || (!name.hasPrefix("rom:") && sig != state.sigs[name]) {
                let mt = try await client.uploadFile(name: name, bytes: bytes, existingID: r?.id, gen: gen, restamp: restamp)
                try live()
                if let mt { state.rmt[name] = mt }
                if state.queueDel.contains(name) {
                    if let t = Self.parseTime(mt) { state.delTs[name] = max(state.delTs[name] ?? 0, t) } else { state.delTs[name] = nil }
                }
            }
            state.sigs[name] = sig
        }
        if !remarked.contains(name) { state.queueUp.removeAll { $0 == name } }
    }

    // MARK: pull (web pullSyncInner)

    @MainActor
    private func pullInner(silent: Bool) async {
        guard active else { return }
        let live = guardSession()
        client.live = live
        if !silent { setStatus(.syncing) }
        var queuedMissing = false
        do {
            var remote = try await listMap(); try live()
            try await syncSaveHook(remote, live: live)
            var lib = mergeLibrary(try await readLibrary(&remote, live: live), localLibrary())
            try live()

            // Remote renames first, oldest first so chains replay in order.
            var renPending = Set<String>()
            for r in stableSorted(lib.ren, by: { $0.ts < $1.ts }) {
                guard RomLibrary.shared.hasAnyLocalRecord(r.from) else { continue }
                guard let moved = applyRemoteRename(r.from, r.to) else { renPending.insert(r.from); continue }
                let fk = RomLibrary.perGameKeys(r.from).all, tk = RomLibrary.perGameKeys(r.to).all
                for (f, t) in zip(fk, tk) where remote.map[f] != nil && parseDriveFileName(f) != nil
                    && !state.queueRen.contains(where: { $0.from == f }) {
                    state.queueRen.append(QRen(from: f, to: t))
                    queuedMissing = true
                }
                if state.queueUp.contains(where: { parseDriveFileName($0)?.game == r.to }) { queuedMissing = true }
                if moved > 0 {
                    AppModel.shared.toast("“\(Self.display(r.from))” is now “\(Self.display(r.to))” — renamed on another device")
                }
            }

            // Tombstones for games this device holds: ask, then delete or restore.
            let pending = lib.tomb.map(\.name).filter { lib.deleted($0) && !localFiles(for: $0).isEmpty }
            if !pending.isEmpty {
                let keep = await AppModel.shared.confirmTombstones(pending)
                try live()
                if keep {
                    let now = Self.now()
                    for g in pending {
                        let gen = lib.tomb.first { $0.name == g }?.gen ?? 0
                        lib.recents.removeAll { $0.string("name") == g }
                        lib.recents.insert(Lib.entry(name: g, ts: now, imp: nil, gen: gen), at: 0)
                        markGameUpload(g)
                    }
                    lib.tomb.removeAll { pending.contains($0.name) }
                } else {
                    for g in pending where GameSession.shared.game?.fileName != g {
                        RomLibrary.shared.deleteLocalData(g)
                    }
                }
            }

            // Games deleted and loaded again elsewhere while held here: what
            // this device holds is the deleted game's. Its save is kept aside.
            var stale: [String: Int] = [:]
            let hereList = RomLibrary.shared.recents
            for e in lib.recents {
                guard let name = e.string("name") else { continue }
                let h = hereList.first { $0.string("name") == name }
                if Lib.gen(e) <= (h.map(Lib.gen) ?? 0) { continue }
                let held = RomLibrary.perGameKeys(name).all.contains { $0 != "oldsave:" + name && RomLibrary.hasKey($0) }
                if !held { continue }
                if GameSession.shared.game?.fileName == name { stale[name] = h.map(Lib.gen) ?? 0; continue }
                if convertStaleGame(name, lib: lib, entry: h) {
                    AppModel.shared.toast("“\(Self.display(name))” was deleted and loaded again on another device. Your save from before is kept for 30 days — Restore it from the game's menu.", duration: 8)
                }
            }
            expireKeptSaves()

            // The game in memory, played on another device since.
            try await handoff(remote: remote, lib: lib, live: live, queuedMissing: &queuedMissing)

            // Saves/states for games held here; pictures for every library game.
            var local = localSyncFiles()
            let romsHere = Set(local.values.filter { $0.kind == "rom" }.map(\.game))
            for (name, f) in remote.map {
                try live()
                if name == Self.libraryFile { continue }
                guard let p = parseDriveFileName(name) else { continue }
                if p.kind == "rom" {
                    // Recorded, never fetched: a ROM comes down when tapped.
                    state.rmt[name] = f.modifiedTime
                    if f.size > 0 { RomLibrary.shared.noteRomSize(p.game, f.size) }
                    continue
                }
                if p.kind == "oldsave" {
                    let t = lib.tomb.first { $0.name == p.game }
                    let from = t?.ts ?? Self.parseTime(f.modifiedTime) ?? 0
                    if Self.now() >= from + Self.keptSaveMs {
                        if !state.queueDel.contains(name) { markDelete(name) }
                        continue
                    }
                }
                if p.kind == "frame" {
                    if !lib.recents.contains(where: { $0.string("name") == p.game }) { continue }
                } else if !romsHere.contains(p.game) && !(p.kind == "oldsave" && local[name] != nil) {
                    continue
                }
                if GameSession.shared.game?.fileName == p.game { continue }
                if state.rmt[name] == f.modifiedTime { continue }
                if genBound(p.kind) && f.gen < lib.gen(p.game) {
                    if p.kind == "save" {
                        let old = try await client.download(f.id); try live()
                        let at = Self.parseTime(f.modifiedTime) ?? Self.now()
                        let t = lib.tomb.first { $0.name == p.game }
                        if !old.isEmpty, keepOldSave(p.game, KeptSave(data: old, at: at, del: t?.ts ?? Self.now(), kept: at, why: "deleted")) {
                            AppModel.shared.toast("A save of “\(Self.display(p.game))” from before you deleted it came back from another device. It is kept for 30 days — Restore it from the game's menu.", duration: 8)
                        }
                    }
                    if state.queueDel.contains(name) { continue }
                    if readSyncBytes(name) != nil { markUpload(name) } else { markDelete(name) }
                    continue
                }
                let bytes = try await client.download(f.id); try live()
                if GameSession.shared.game?.fileName == p.game { continue }
                if state.queueDel.contains(name) { continue }
                if renamedAway.contains(p.game) { continue }
                let sig = Self.sig(bytes)
                if sig != state.sigs[name] {
                    try writeSyncBytes(name, bytes)
                    state.sigs[name] = sig
                }
                state.rmt[name] = f.modifiedTime
                local[name] = nil
            }
            try live()
            // Reconcile upward: anything held here that the listing lacks.
            for (name, p) in local {
                if remote.map[name] != nil || lib.deleted(p.game) || renPending.contains(p.game) { continue }
                if !state.queueUp.contains(name) { state.queueUp.append(name); queuedMissing = true }
            }
            // Merged again with the library as it is now, under the lock.
            try await RomLibrary.shared.updateRecent { here in
                try live()
                lib = mergeLibrary(lib, DriveLibrary(recents: here, tomb: self.state.tomb, ren: self.state.ren))
                self.state.tomb = lib.tomb
                self.state.ren = lib.ren
                for t in lib.tomb where lib.deleted(t.name) {
                    for n in remote.map.keys where parseDriveFileName(n)?.game == t.name && !self.state.queueDel.contains(n) {
                        self.markDelete(n)
                    }
                }
                var recents = lib.recents
                if !stale.isEmpty {
                    recents = recents.map { e in
                        guard let n = e.string("name"), let g = stale[n] else { return e }
                        var o = e
                        o["gen"] = nil
                        if g > 0 { o["gen"] = .number(Double(g)) }
                        return o
                    }
                }
                if !renPending.isEmpty {
                    var back: [String: Ren] = [:]
                    for m in lib.ren where renPending.contains(m.from) { back[m.to] = m }
                    recents = recents.map { e in
                        guard let n = e.string("name"), let m = back[n] else { return e }
                        return JSObject([("name", .string(m.from)),
                                         ("ts", .number(min(e.number("ts") ?? 0, (m.ts != 0 ? m.ts : 1) - 1)))])
                    }
                }
                return recents
            }
            if !libraryUnchanged(lib, remote) { try await writeLibrary(lib, remote, readFrom: remote) }
            try live()
            saveState()
        } catch is DriveSessionEnded {
            refreshStatus()
            return
        } catch {
            setStatus(.offline)
            return
        }
        refreshStatus()
        if !silent && status == .syncing { setStatus(.done) }
        if queuedMissing { scheduleFlush() }
        RomLibrary.shared.pictureGen += 1
    }

    /// Another device's rename, applied here: every record moves; a
    /// collision keeps both unless the bytes match. Nil when the game is
    /// open (deferred to a later pull); else how many records moved.
    private func applyRemoteRename(_ from: String, _ to: String) -> Int? {
        renamedAway.remove(to)
        if GameSession.shared.game?.fileName == from { return nil }
        let fk = RomLibrary.perGameKeys(from).all, tk = RomLibrary.perGameKeys(to).all
        func mapKey(_ k: String) -> String { fk.firstIndex(of: k).map { tk[$0] } ?? k }
        for (f, t) in zip(fk, tk) {
            if let v = state.sigs.removeValue(forKey: f) { state.sigs[t] = v }
            if let v = state.rmt.removeValue(forKey: f) { state.rmt[t] = v }
        }
        var up: [String] = []
        for n in state.queueUp.map(mapKey) where !up.contains(n) { up.append(n) }
        state.queueUp = up
        var del: [String] = []
        for n in state.queueDel.map(mapKey) where !del.contains(n) { del.append(n) }
        state.queueDel = del
        state.delTs = Dictionary(state.delTs.map { (mapKey($0.key), $0.value) }, uniquingKeysWith: max)
        state.queueRen = state.queueRen.map { QRen(from: mapKey($0.from), to: $0.to) }
        let present = fk.filter(RomLibrary.hasKey).count
        let skipped = RomLibrary.moveRecords(from: from, to: to)
        var leftover = 0
        for (f, t) in skipped {
            if let a = readSyncBytes(f), let b = readSyncBytes(t), Self.sig(a) == Self.sig(b) {
                RomLibrary.deleteKeys([f])
            } else { leftover += 1 }
        }
        if let size = Optional(RomLibrary.shared.romSize(from)), size > 0 { RomLibrary.shared.noteRomSize(to, size) }
        if AppModel.shared.heroGame?.fileName == from { AppModel.shared.heroGame = RomEntry(fileName: to) }
        RomLibrary.shared.pictureGen += 1
        return present - skipped.count
    }

    /// This device's records of a game deleted and loaded again elsewhere go,
    /// bar the save, kept aside. True when a save was kept.
    private func convertStaleGame(_ game: String, lib: DriveLibrary, entry: JSObject?) -> Bool {
        var keptIt = false
        if let bytes = readSyncBytes("save:" + game) {
            let at = max(Self.parseTime(state.rmt["save:" + game]) ?? 0, entry?.number("ts") ?? 0)
            let when = at != 0 ? at : Self.now()
            let t = lib.tomb.first { $0.name == game }
            keptIt = keepOldSave(game, KeptSave(data: bytes, at: when, del: t?.ts ?? Self.now(), kept: when, why: "deleted"))
        }
        let old = RomLibrary.perGameKeys(game).all.filter { $0 != "oldsave:" + game }
        state.queueUp.removeAll { old.contains($0) }
        RomLibrary.deleteKeys(old)
        for k in old { state.sigs[k] = nil; state.rmt[k] = nil }
        RomLibrary.shared.pictureGen += 1
        return keptIt
    }

    // MARK: hand-off (web "Hand-off: the game in memory, played on another device since")

    private func handoffKeys(_ g: String) -> [String] { ["save:" + g, "stateauto:" + g] }

    @MainActor
    private func handoff(remote: Listing, lib: DriveLibrary, live: () throws -> Void, queuedMissing: inout Bool) async throws {
        let s = GameSession.shared
        guard let held = s.game?.fileName, lib.recents.contains(where: { $0.string("name") == held }) else { return }
        var news: [(key: String, f: DriveFile, bytes: Data)] = []
        for key in handoffKeys(held) {
            guard let f = remote.map[key], state.rmt[key] != f.modifiedTime else { continue }
            if f.gen < lib.gen(held) || state.queueDel.contains(key) { continue }
            let bytes = try await client.download(f.id); try live()
            let sig = Self.sig(bytes)
            if let here = readSyncBytes(key), Self.sig(here) == sig {
                state.sigs[key] = sig
                state.rmt[key] = f.modifiedTime
                continue
            }
            news.append((key, f, bytes))
        }
        guard !news.isEmpty, s.game?.fileName == held else { return }
        let running = AppModel.shared.screen == .play && !s.paused
        let sent = !s.sessionMoved && !handoffKeys(held).contains(where: state.queueUp.contains)
        let where_ = Self.deviceWords(news.first { $0.key.hasPrefix("stateauto:") }.flatMap { Self.parseBundle($0.bytes)?.meta.dev })
        if !running && sent {
            takeHandoff(held, news)
            AppModel.shared.toast("“\(Self.display(held))” was played on \(where_) since — Resume picks up there", duration: 6)
            return
        }
        let kept = handoffStash?.game == held
            ? handoffStash!.news.filter { o in !news.contains { $0.key == o.key } } : []
        handoffStash = (held, kept + news)
        for n in news where n.key == "stateauto:" + held { state.rmt[n.key] = n.f.modifiedTime }
        if state.queueUp.contains("stateauto:" + held) { queuedMissing = true }
        let seen = held + "|" + news.map(\.f.modifiedTime).joined(separator: "|")
        if handoffOffered != seen {
            handoffOffered = seen
            AppModel.shared.toast("“\(Self.display(held))” was played on \(where_) since you opened it here",
                                  action: ("Switch", { [weak self] in Task { @MainActor in await self?.switchToHandoff(held) } }),
                                  duration: 12)
        }
    }

    /// Let the copy in memory go (nothing of it written) and land the newer files.
    private func takeHandoff(_ game: String, _ news: [(key: String, f: DriveFile, bytes: Data)]) {
        GameSession.shared.discard()
        for n in news {
            try? writeSyncBytes(n.key, n.bytes)
            state.sigs[n.key] = Self.sig(n.bytes)
            state.rmt[n.key] = n.f.modifiedTime
        }
        RomLibrary.shared.pictureGen += 1
    }

    @MainActor
    private func switchToHandoff(_ game: String) async {
        guard GameSession.shared.game?.fileName == game, let stash = handoffStash, stash.game == game else { return }
        handoffStash = nil
        handoffOffered = ""
        state.queueUp.removeAll { handoffKeys(game).contains($0) }
        saveState()
        let wasPlaying = AppModel.shared.screen == .play
        takeHandoff(game, stash.news)
        for n in stash.news {
            state.sigs[n.key] = nil
            handoffForce.insert(n.key)
            markUpload(n.key)
            remarked.insert(n.key)
        }
        saveState()
        if wasPlaying { AppModel.shared.launch(RomEntry(fileName: game), resume: true) }
        await flushNow()
        await pull(silent: false)
    }

    // MARK: save webhook (its own file, newest ts wins)

    func setSaveHook(_ url: String) {
        guard url != state.saveHook.url else { return }
        state.saveHook = SaveHookRec(url: url, ts: Self.now(), dirty: true)
        saveState()
        if active { Task { @MainActor in await self.pull() } }
    }

    @MainActor
    private func syncSaveHook(_ remote: Listing, live: () throws -> Void) async throws {
        let f = remote.map[Self.saveHookFile]
        if let f, state.rmt[Self.saveHookFile] != f.modifiedTime {
            let bytes = try await client.download(f.id); try live()
            state.rmt[Self.saveHookFile] = f.modifiedTime
            if let o = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
                let ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
                let url = (o["url"] as? String) ?? ""
                if ts > state.saveHook.ts, url.isEmpty || url.hasPrefix("http://") || url.hasPrefix("https://") {
                    state.saveHook = SaveHookRec(url: url, ts: ts, dirty: false)
                    Settings.shared.adoptSyncedWebhook(url)
                }
            }
        }
        guard state.saveHook.dirty else { return }
        let sent = state.saveHook
        let body = JSValue.object(JSObject([("url", .string(sent.url)), ("ts", .number(sent.ts))])).data()
        let mt = try await client.uploadFile(name: Self.saveHookFile, bytes: body, existingID: f?.id)
        try live()
        if let mt { state.rmt[Self.saveHookFile] = mt }
        if state.saveHook.ts == sent.ts { state.saveHook.dirty = false }
    }

    // MARK: Drive-only games

    /// Drive can hand the ROM back: enrolled, Drive listed it (rmt, or a sig
    /// from an upload), and no delete queued.
    func driveHasRom(_ game: String) -> Bool {
        let k = "rom:" + game
        return enrolled && (state.sigs[k] != nil || state.rmt[k] != nil) && !state.queueDel.contains(k)
    }

    /// Bring one game down (web downloadGame). True when it landed.
    @MainActor
    @discardableResult
    func downloadGame(_ game: String) async -> Bool {
        guard linked else { AppModel.shared.toast("Sign in to Google Drive first"); return false }
        guard await ensureSignedIn() else { return false }
        guard downloading[game] == nil else { return false }
        downloading[game] = (0, 0)
        defer { downloading[game] = nil; RomLibrary.shared.pictureGen += 1 }
        let live = guardSession()
        client.live = live
        do {
            let remote = try await listMap()
            let files = remote.map.values.filter { parseDriveFileName($0.name)?.game == game }
            guard !files.isEmpty else { AppModel.shared.toast("That game isn't on Drive anymore"); return false }
            let gen = max(RomLibrary.shared.gen(of: game), files.map(\.gen).max() ?? 0)
            func stale(_ f: DriveFile) -> Bool {
                guard let p = parseDriveFileName(f.name) else { return false }
                return genBound(p.kind) && f.gen < gen
            }
            let total = files.reduce(0) { n, f in stale(f) && parseDriveFileName(f.name)?.kind != "save" ? n : n + f.size }
            var got = 0
            downloading[game] = (0, total)
            let tick: (Int) -> Void = { [weak self] n in got += n; self?.downloading[game] = (got, total) }
            for f in files {
                let p = parseDriveFileName(f.name)!
                if stale(f) {
                    if p.kind == "save" {
                        let at = Self.parseTime(f.modifiedTime) ?? Self.now()
                        let t = state.tomb.first { $0.name == game }
                        keepOldSave(game, KeptSave(data: try await client.download(f.id, onBytes: tick), at: at,
                                                   del: t?.ts ?? Self.now(), kept: at, why: "deleted"))
                    }
                    continue
                }
                let bytes = try await client.download(f.id, onBytes: tick)
                try live()
                try writeSyncBytes(f.name, bytes)
                state.sigs[f.name] = Self.sig(bytes)
                state.rmt[f.name] = f.modifiedTime
            }
            await RomLibrary.shared.bump(game, gen: gen)
            saveState()
            return true
        } catch is DriveSessionEnded {
            return false
        } catch {
            AppModel.shared.toast("Couldn't download: " + error.localizedDescription)
            return false
        }
    }

    /// Add pictures: a Drive-only game's ROM, and its save (kept here by
    /// Remove from this device, or Drive's), into memory; nothing written.
    @MainActor
    func fetchForPicture(_ game: String) async -> (rom: Data, save: Data?)? {
        guard linked, await ensureSignedIn() else { return nil }
        client.live = guardSession()
        do {
            let remote = try await listMap()
            let files = remote.map.values.filter { parseDriveFileName($0.name)?.game == game }
            guard let rf = files.first(where: { parseDriveFileName($0.name)?.kind == "rom" }) else { return nil }
            let rom = try await client.download(rf.id)
            var save = try? Data(contentsOf: RomEntry(fileName: game).saveURL)
            if save?.isEmpty ?? true, let sf = files.first(where: { $0.name == "save:" + game }) {
                save = try await client.download(sf.id)
            }
            return (rom, save)
        } catch {
            return nil
        }
    }

    /// Free the ROM bytes and session; saves stay and go up (web
    /// removeGameFromDevice). Never takes the last copy.
    @MainActor
    @discardableResult
    func removeFromDevice(_ game: String) async -> Bool {
        guard linked else { AppModel.shared.toast("Sign in to Google Drive first"); return false }
        guard await ensureSignedIn() else { return false }
        client.live = guardSession()
        let remote: Listing
        do { remote = try await listMap() } catch {
            AppModel.shared.toast("Couldn't reach Drive — nothing was removed")
            return false
        }
        if remote.map["rom:" + game] == nil {
            markGameUpload(game)
            AppModel.shared.toast("Not backed up yet — kept here and queued for Drive")
            return false
        }
        if GameSession.shared.game?.fileName == game { AppModel.shared.closeGame() }
        let k = RomLibrary.perGameKeys(game)
        RomLibrary.deleteKeys(["rom:" + game, "art:" + game] + k.session)
        Checkpoints.delete(RomEntry(fileName: game))
        try? FileManager.default.removeItem(at: RomEntry(fileName: game).coreURL)
        markGameUpload(game)
        RomLibrary.shared.pictureGen += 1
        AppModel.shared.toast("ROM removed from this device — save kept, still on Drive")
        return true
    }

    // MARK: accounts

    /// A different account signing in parks the previous account's state
    /// and starts clean; one that comes back gets its parked work again
    /// (web adoptDriveAccount + swapAccountGames).
    @MainActor
    private func adoptAccount(_ acct: String?) async {
        guard let acct, state.acct != acct else { return }
        var parked = state.parked
        let prevAcct = state.acct
        var mine = AccountState(queueUp: state.queueUp, queueDel: state.queueDel, queueRen: state.queueRen,
                                tomb: state.tomb, ren: state.ren, sigs: state.sigs, rmt: state.rmt, delTs: state.delTs)
        let restored = parked.removeValue(forKey: acct)
        session += 1
        remarked.removeAll()
        let r = restored ?? AccountState()
        state.queueUp = r.queueUp; state.queueDel = r.queueDel; state.queueRen = r.queueRen
        state.tomb = r.tomb; state.ren = r.ren; state.sigs = r.sigs; state.rmt = r.rmt; state.delTs = r.delTs
        state.acct = acct
        if let prevAcct {
            // A tile with nothing of it here but the picture the last
            // account's Drive brought leaves with that account.
            var gone: [JSObject] = []
            let theirs = r.recents.flatMap { JSValue.parse(Data($0.utf8))?.arrayValue?.compactMap(\.objectValue) } ?? []
            _ = try? await RomLibrary.shared.updateRecent { list in
                var keep: [JSObject] = []
                for e in list {
                    if let n = e.string("name"), !RomLibrary.shared.holdsGame(n) { gone.append(e) } else { keep.append(e) }
                }
                let back = theirs.filter { t in !keep.contains { $0.string("name") == t.string("name") } }
                if gone.isEmpty && back.isEmpty { return nil }
                return stableSorted(keep + back) { ($0.number("ts") ?? 0) > ($1.number("ts") ?? 0) }
            }
            for e in gone {
                guard let n = e.string("name") else { continue }
                RomLibrary.deleteKeys(["frame:" + n])
                mine.sigs["frame:" + n] = nil
                mine.rmt["frame:" + n] = nil
            }
            mine.recents = JSValue.array(gone.map { .object($0) }).stringify()
            parked[prevAcct] = mine
        }
        state.parked = parked
        saveState()
        let waiting = (restored?.queueDel.count ?? 0) + (restored?.queueRen.count ?? 0) + (restored?.tomb.count ?? 0)
        if waiting > 0 { AppModel.shared.toast("Applying changes saved for this account") }
    }

    // MARK: sign-in

    var tokenStale: Bool { state.token == nil || state.tokenExp - Self.now() < 10 * 60 * 1000 }

    private func adoptGrant(_ g: DriveAuth.Grant) {
        state.token = g.accessToken
        state.tokenExp = Self.now() + (g.expiresIn - 60) * 1000
    }

    /// Sign in: the consent sheet, the account, a full sync.
    @MainActor
    func connect() async throws {
        connecting += 1
        defer { connecting -= 1 }
        let grant = try await DriveAuth.codeGrant(hint: state.email)
        guard let info = await DriveAuth.tokenInfo(grant.accessToken) else {
            throw DriveAuth.AuthError.failed("Couldn't confirm which Google account signed in — try again")
        }
        session += 1
        adoptGrant(grant)
        state.refresh = grant.refreshToken
        state.refreshAcct = info.sub
        brokerRetryAt = 0
        state.email = info.email
        await adoptAccount(info.sub)
        session += 1
        state.connected = true
        saveState()
        AppModel.shared.toast("Connected to Google Drive")
        startTriggers()
        await runFullSync()
    }

    /// A Drive session before user-initiated Drive work.
    @MainActor
    func ensureSignedIn() async -> Bool {
        if active && !tokenStale { return true }
        if linked, await refreshSilently(force: true) { return true }
        do { try await connect() } catch {
            AppModel.shared.toast(error.localizedDescription)
            return false
        }
        return active
    }

    /// A new access token from the refresh token, no sheet.
    @MainActor
    func refreshSilently(force: Bool = false) async -> Bool {
        guard let rt = state.refresh, state.refreshAcct == nil || state.acct == nil || state.refreshAcct == state.acct else { return false }
        if !force && Self.now() < brokerRetryAt { return false }
        if let t = refreshInFlight { return await t.value }
        let issued = session
        let t = Task { @MainActor () -> Bool in
            defer { self.refreshInFlight = nil }
            do {
                let g = try await DriveAuth.refresh(rt)
                guard self.state.connected, issued == self.session else { return false }
                self.adoptGrant(g)
                self.saveState()
                return true
            } catch DriveAuth.AuthError.grantGone {
                if self.state.refresh == rt { self.signOut(message: DriveAuth.AuthError.grantGone.localizedDescription) }
                return false
            } catch {
                self.brokerRetryAt = Self.now() + 60_000
                return false
            }
        }
        refreshInFlight = t
        return await t.value
    }

    func signOut(message: String = "Signed out of Google Drive") {
        session += 1
        state.refresh = nil
        state.email = nil
        state.connected = false
        state.token = nil
        state.tokenExp = 0
        saveState()
        debounce?.invalidate(); debounce = nil
        cap?.invalidate(); cap = nil
        setStatus(.idle)
        RomLibrary.shared.pictureGen += 1
        AppModel.shared.toast(message)
    }

    @MainActor
    func signOutEverywhere() async {
        for token in [state.refresh, tokenStale ? nil : state.token].compactMap({ $0 }) {
            if await DriveAuth.revoke(token) {
                signOut(message: "Signed out of Google Drive on every device")
                return
            }
        }
        AppModel.shared.toast("Couldn't reach Google to sign out everywhere — try again")
    }

    /// Sync now: the game in memory as it is now, every local file queued,
    /// then flush and pull.
    @MainActor
    func runFullSync() async {
        if !active { guard await ensureSignedIn() else { return } }
        if GameSession.shared.game != nil {
            GameSession.shared.persistSession()
            dingbat_flush_save()
        }
        for n in localSyncFiles().keys where !state.queueUp.contains(n) { state.queueUp.append(n) }
        saveState()
        await flushNow()
        await pull(silent: false)
    }

    // MARK: triggers

    /// At launch: renew the token if it went stale, then catch up.
    @MainActor
    func resumeOnBoot() async {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let now = path.status == .satisfied
                defer { self.online = now }
                if now && !self.online && self.active {
                    Task { @MainActor in await self.flushNow(); await self.pull() }
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.foreground() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // What the game left goes up before the app is suspended.
            guard let self, self.active, self.pendingCount > 0 else { return }
            var bg: UIBackgroundTaskIdentifier = .invalid
            bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
            Task { @MainActor in
                await self.flushNow()
                UIApplication.shared.endBackgroundTask(bg)
            }
        }
        guard state.connected else { return }
        startTriggers()
        if tokenStale { _ = await refreshSilently(force: true) }
        guard active else { return }
        if let info = await DriveAuth.tokenInfo(state.token ?? "") {
            state.email = info.email
            await adoptAccount(info.sub)
        }
        await pull()
        if pendingCount > 0 { await flushNow() }
    }

    @MainActor
    private func foreground() async {
        guard state.connected else { return }
        if tokenStale { _ = await refreshSilently() }
        guard active else { return }
        await flushNow()
        await pull()
    }

    private func startTriggers() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            guard let self, self.state.connected else { return }
            Task { @MainActor in
                if self.tokenStale { _ = await self.refreshSilently() }
                guard self.active else { return }
                if self.pendingCount > 0 { await self.flushNow() }
                await self.pull()
            }
        }
    }

    // MARK: helpers

    static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// Date.parse of a Drive RFC 3339 stamp, in ms; nil for none.
    static func parseTime(_ s: String?) -> Double? {
        guard let s, !s.isEmpty, let d = iso.date(from: s) ?? isoPlain.date(from: s) else { return nil }
        return (d.timeIntervalSince1970 * 1000).rounded()
    }

    /// FNV-1a + length, as the web's sigOfBytes.
    static func sig(_ d: Data) -> String { RomLibrary.saveSignature(d) ?? "0:0" }

    static func display(_ name: String) -> String { (name as NSString).deletingPathExtension }

    /// Which device took a session: a random id kept here, and its kind.
    static let deviceID: String = {
        let k = "dingbat_device"
        if let id = UserDefaults.standard.string(forKey: k) { return id }
        let id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))
        UserDefaults.standard.set(id, forKey: k)
        return id
    }()
    static var deviceLabel: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    /// "your iPhone", "your other iPad", "another device".
    static func deviceWords(_ dev: String?) -> String {
        guard let dev, !dev.isEmpty else { return "another device" }
        return dev == deviceLabel ? "your other " + dev : "your " + dev
    }
}
