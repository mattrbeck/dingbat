import Foundation

/// A JSON value with JavaScript object semantics: keys keep insertion order,
/// assigning an existing key keeps its place, removing drops it. Serialized
/// exactly as JSON.stringify would, so a file the web and the app both write
/// (Drive's "library") reads back byte-identical on either side and neither
/// rewrites what the other just wrote.
indirect enum JSValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSValue])
    case object(JSObject)

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    var arrayValue: [JSValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: JSObject? { if case .object(let o) = self { return o }; return nil }

    /// From JSONSerialization output (key order is not kept: nothing that
    /// reads a file re-serializes its objects as read).
    init(any: Any) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSValue(any: $0) })
        case let d as [String: Any]:
            var o = JSObject()
            for k in d.keys.sorted() { o[k] = JSValue(any: d[k]!) }
            self = .object(o)
        default: self = .null
        }
    }

    static func parse(_ data: Data) -> JSValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSValue(any: any)
    }

    /// JSON.stringify.
    func stringify() -> String {
        var out = ""
        write(&out)
        return out
    }

    func data() -> Data { Data(stringify().utf8) }

    private func write(_ out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += JSValue.formatNumber(n)
        case .string(let s): JSValue.quote(s, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() { if i > 0 { out += "," }; v.write(&out) }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, k) in o.keys.enumerated() {
                if i > 0 { out += "," }
                JSValue.quote(k, into: &out)
                out += ":"
                o.values[k]!.write(&out)
            }
            out += "}"
        }
    }

    /// Number.prototype.toString for the values these files hold: integral
    /// millisecond stamps and counters (finite non-integers fall back to the
    /// shortest round-trip form, which matches JS for ordinary values).
    static func formatNumber(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == n.rounded(), abs(n) < 9.007_199_254_740_992e15 {
            return String(Int64(n))
        }
        return "\(n)"
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }
}

/// An insertion-ordered object.
struct JSObject: Equatable {
    private(set) var keys: [String] = []
    fileprivate(set) var values: [String: JSValue] = [:]

    init() {}

    init(_ pairs: [(String, JSValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    subscript(key: String) -> JSValue? {
        get { values[key] }
        set {
            if let v = newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = v
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    func string(_ k: String) -> String? { values[k]?.stringValue }
    func number(_ k: String) -> Double? { values[k]?.numberValue }
}
