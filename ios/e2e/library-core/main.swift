// The Swift side of ios/e2e/library-core.mjs: runs each case the test wrote
// through LibraryCore.swift and writes back what it made of it.
import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let cases = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("cases.json"))) as! [[String: Any]]
func lib(_ c: [String: Any], _ k: String) -> DriveLibrary { DriveLibrary.parse(Data((c[k] as! String).utf8)) }
func obj(_ c: [String: Any], _ k: String) -> JSObject? {
    (c[k] as? String).flatMap { JSValue.parse(Data($0.utf8))?.objectValue }
}

var out: [Any] = []
for c in cases {
    let r: String?
    switch c["op"] as! String {
    case "merge":
        r = mergeLibrary(lib(c, "a"), lib(c, "b")).js.stringify()
    case "titleOf":
        r = Lib.titleOf(c["s"] as? String)
    case "zipTitle":
        r = Lib.zipTitle(zipName: c["zip"] as! String, romName: c["rom"] as! String,
                         isExport: c["isExport"] as! Bool, exportTitle: c["exportTitle"] as? String)
    case "bumped":
        r = JSValue.object(Lib.bumped(name: c["name"] as! String, ts: (c["ts"] as! NSNumber).doubleValue,
                                      imp: (c["imp"] as? NSNumber)?.doubleValue, gen: (c["gen"] as! NSNumber).intValue,
                                      prev: obj(c, "prev"), fresh: c["fresh"] as! Bool,
                                      title: c["title"] as? String)).stringify()
    case "stored":
        r = obj(c, "o").flatMap(Lib.stored).map { JSValue.object($0).stringify() }
    default:
        r = nil
    }
    out.append(r ?? NSNull())
}
try! JSONSerialization.data(withJSONObject: out).write(to: dir.appendingPathComponent("out.json"))
