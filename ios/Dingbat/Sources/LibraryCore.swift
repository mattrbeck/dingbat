import Foundation

// The library's entries and their merge (web "recent", Drive's "library"
// file and mergeLibrary), Foundation only so ios/e2e/library-core.mjs can
// build it beside the web's own code.

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
        let ok = Lib.validName
        lib.recents = (o["recents"]?.arrayValue ?? []).compactMap { $0.objectValue }
            .filter { ok($0.string("name") ?? "") }
        lib.tomb = (o["tomb"]?.arrayValue ?? []).compactMap { v in
            guard let t = v.objectValue, let n = t.string("name"), ok(n) else { return nil }
            return Tomb(name: n, ts: t.number("ts") ?? 0, gen: Lib.gen(t))
        }
        lib.ren = (o["ren"]?.arrayValue ?? []).compactMap { v in
            guard let r = v.objectValue, let f = r.string("from"), let t = r.string("to"), ok(f), ok(t) else { return nil }
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
func stableSorted<T>(_ a: [T], by less: (T, T) -> Bool) -> [T] {
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
        // The title came with an import, so it goes with the newest import
        // claim: a later import of the bare ROM drops it, and a build that
        // knows no titles (writing the same claim without one) does not.
        let ei = imp(e), pi = imp(prev)
        let title = ei > pi ? Lib.titleOf(e.string("title")) : ei < pi ? prev?.string("title")
            : prev?.string("title") ?? Lib.titleOf(e.string("title"))
        let g = Lib.gen(e)
        let pg = prev.map(Lib.gen) ?? -1
        if prev == nil || g > pg || (g == pg && ts(e) > ts(prev!)) {
            byName[name] = Lib.entry(name: name, ts: ts(e), imp: nil, gen: g)
        }
        if im != 0 { byName[name]!["imp"] = .number(im) }
        byName[name]!["title"] = title.map { .string($0) }
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

/// Library entries (web `recent`), built in the web's key order so the
/// shared library file serializes as the web's does.
enum Lib {
    static func gen(_ o: JSObject) -> Int {
        guard let g = o.number("gen"), g > 0, g == g.rounded() else { return 0 }
        return Int(g)
    }

    /// withGen({ name, ts }, gen) with `imp` set after (mergeLibrary's order).
    static func entry(name: String, ts: Double, imp: Double?, gen: Int) -> JSObject {
        var o = JSObject([("name", .string(name)), ("ts", .number(ts))])
        if gen > 0 { o["gen"] = .number(Double(gen)) }
        if let imp, imp != 0 { o["imp"] = .number(imp) }
        return o
    }

    /// withGen(imp ? { name, ts, imp } : { name, ts }, gen) (bumpRecentIndex's
    /// and renameGame's order).
    static func entry(name: String, ts: Double, impFirst imp: Double?, gen: Int) -> JSObject {
        var o = JSObject([("name", .string(name)), ("ts", .number(ts))])
        if let imp, imp != 0 { o["imp"] = .number(imp) }
        if gen > 0 { o["gen"] = .number(Double(gen)) }
        return o
    }

    /// bumpRecentIndex's entry: an import sets the title, or drops it (a
    /// bare ROM); a play keeps the one before.
    static func bumped(name: String, ts: Double, imp: Double?, gen: Int,
                       prev: JSObject?, fresh: Bool, title: String?) -> JSObject {
        var o = entry(name: name, ts: ts, impFirst: imp, gen: gen)
        o["title"] = (fresh ? titleOf(title) : prev?.string("title")).map { .string($0) }
        return o
    }

    /// An entry of recent.json, rebuilt in the web's key order.
    static func stored(_ o: JSObject) -> JSObject? {
        guard let n = o.string("name"), validName(n) else { return nil }
        var e = entry(name: n, ts: o.number("ts") ?? 0, imp: o.number("imp"), gen: gen(o))
        e["title"] = titleOf(o.string("title")).map { .string($0) }
        return e
    }

    /// A game name from outside (Drive's file names and library, a zip, a
    /// picked file) that may key a game: one plain path component, no
    /// longer than a file's name can be.
    static func validName(_ n: String) -> Bool {
        if n.isEmpty || n == "." || n == ".." || n.utf8.count > 255 { return false }
        if n.contains("/") || n.contains("\\") { return false }
        return !n.unicodeScalars.contains(where: isControl)
    }

    static func isControl(_ c: Unicode.Scalar) -> Bool { c.value < 0x20 || (0x7f...0x9f).contains(c.value) }

    /// web titleOf: the name a game imported from a zip is shown under (the
    /// zip's), display only; every record stays under the entry's `name`.
    static let titleMax = 100
    static func titleOf(_ t: String?) -> String? {
        guard let t = t?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let u = t.utf16
        return u.count <= titleMax ? t : String(decoding: Array(u.prefix(titleMax)), as: UTF16.self)
    }

    /// web stripExt: everything before the last dot ("" with none).
    static func stripExt(_ n: String) -> String {
        n.lastIndex(of: ".").map { String(n[..<$0]) } ?? ""
    }

    /// The title an import from the zip `zipName` sets (web handleZipFile):
    /// a dingbat export's is its game's (`exportTitle`), anyone else's the
    /// zip's name; none when that is the ROM's own.
    static func zipTitle(zipName: String, romName: String, isExport: Bool, exportTitle: String?) -> String? {
        let t = isExport ? titleOf(exportTitle) : titleOf(stripExt(zipName))
        let own = stripExt(romName)
        return t == (own.isEmpty ? romName : own) ? nil : t
    }
}
